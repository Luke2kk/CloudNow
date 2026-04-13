import SwiftUI

private enum LoadingPhase: Equatable {
    case finding
    case inQueue(Int?)
    case preparing
    case timedOut
}

struct StreamView: View {
    let game: GameInfo
    var settings: StreamSettings = StreamSettings()
    let onDismiss: () -> Void

    @Environment(AuthManager.self) var authManager
    @State private var streamController = GFNStreamController()
    @State private var showOverlay = false
    @State private var overlayTimer: Timer?
    @State private var loadingPhase: LoadingPhase = .finding
    @State private var createdSession: SessionInfo?
    @State private var sessionToken: String?

    private let cloudMatchClient = CloudMatchClient()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch streamController.state {
            case .idle, .connecting:
                connectingView
            case .streaming:
                streamingView
            case .disconnected(let reason):
                disconnectedView(reason)
            case .failed(let message):
                failedView(message)
            }
        }
        .ignoresSafeArea()
        .task { await startSession() }
        .onDisappear { streamController.disconnect() }
        // Menu button toggles the HUD overlay
        .onExitCommand {
            if streamController.state == .streaming {
                toggleOverlay()
            } else {
                disconnect()
            }
        }
    }

    // MARK: Connecting

    private var connectingView: some View {
        VStack(spacing: 24) {
            if case .timedOut = loadingPhase {
                Image(systemName: "clock.badge.xmark")
                    .font(.system(size: 60))
                    .foregroundStyle(.orange)
            } else {
                ProgressView()
                    .scaleEffect(2)
                    .tint(.white)
            }
            Text("Starting \(game.title)…")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
            Text(loadingLabel)
                .font(.body)
                .foregroundStyle(.secondary)
                .animation(.easeInOut, value: loadingPhase)
            HStack(spacing: 24) {
                if case .timedOut = loadingPhase {
                    Button("Retry") { Task { await startSession() } }
                        .buttonStyle(.bordered)
                        .tint(.blue)
                }
                Button("Cancel") { disconnect() }
                    .buttonStyle(.bordered)
                    .tint(loadingPhase == .timedOut ? .red : .secondary)
            }
        }
    }

    private var loadingLabel: String {
        switch loadingPhase {
        case .finding:
            return "Connecting to a GeForce NOW server…"
        case .inQueue(let pos):
            if let pos { return "In queue · Position \(pos)" }
            return "In queue…"
        case .preparing:
            return "Preparing your game…"
        case .timedOut:
            return "Server took too long to respond."
        }
    }

    // MARK: Streaming

    private var streamingView: some View {
        ZStack {
            VideoSurfaceViewRepresentable(streamController: streamController)
                .ignoresSafeArea()

            if showOverlay {
                statsOverlay
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showOverlay)
    }

    // MARK: Stats Overlay

    private var statsOverlay: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("\(streamController.stats.resolutionWidth)×\(streamController.stats.resolutionHeight) @ \(Int(streamController.stats.fps))fps", systemImage: "tv")
            Label("\(streamController.stats.bitrateKbps / 1000) Mbps", systemImage: "wifi")
            Label("RTT \(Int(streamController.stats.rttMs)) ms", systemImage: "network")
            Label("Loss \(String(format: "%.1f", streamController.stats.packetLossPercent))%", systemImage: "arrow.triangle.2.circlepath")
            if !streamController.stats.gpuType.isEmpty {
                Label(streamController.stats.gpuType, systemImage: "cpu")
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.white)
        .padding(16)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(40)
    }

    // MARK: Disconnected / Failed

    private func disconnectedView(_ reason: String) -> some View {
        statusView(
            icon: "wifi.slash",
            title: "Disconnected",
            message: reason,
            color: .yellow
        )
    }

    private func failedView(_ message: String) -> some View {
        statusView(
            icon: "exclamationmark.triangle",
            title: "Stream Failed",
            message: entitlementMessage(from: message),
            color: .red
        )
    }

    private func entitlementMessage(from raw: String) -> String {
        if raw.uppercased().contains("ENTITLEMENT") || raw.contains("3237093650") {
            return "\(game.title) is not in your GeForce NOW library."
        }
        return raw
    }

    private func statusView(icon: String, title: String, message: String, color: Color) -> some View {
        VStack(spacing: 24) {
            Image(systemName: icon)
                .font(.system(size: 60))
                .foregroundStyle(color)
            Text(title)
                .font(.title.weight(.bold))
                .foregroundStyle(.white)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 24) {
                Button("Retry") { Task { await startSession() } }
                    .buttonStyle(.bordered)
                    .tint(.blue)
                Button("Exit") { disconnect() }
                    .buttonStyle(.bordered)
                    .tint(.red)
            }
        }
        .padding(60)
    }

    // MARK: Actions

    private func startSession() async {
        loadingPhase = .finding
        createdSession = nil
        do {
            let token = try await authManager.resolveToken()
            sessionToken = token
            let provider = authManager.session?.provider
            let streamingBaseUrl = provider?.streamingServiceUrl ?? NVIDIAAuth.defaultStreamingUrl
            let base = streamingBaseUrl.hasSuffix("/") ? String(streamingBaseUrl.dropLast()) : streamingBaseUrl

            guard let appId = game.variants.first?.appId ?? game.variants.first?.id else { return }

            let request = SessionCreateRequest(
                appId: appId,
                internalTitle: game.title,
                token: token,
                zone: "",
                streamingBaseUrl: base,
                settings: settings,
                accountLinked: true
            )

            var sessionInfo = try await cloudMatchClient.createSession(request)
            createdSession = sessionInfo

            // Poll with readyPollStreak confirmation (requires 2 consecutive ready polls)
            // and a 90-second overall timeout to prevent infinite waiting.
            var readyPollStreak = 0
            let startTime = Date()

            while readyPollStreak < 2 {
                guard Date().timeIntervalSince(startTime) < 90 else {
                    loadingPhase = .timedOut
                    return
                }

                // Update loading phase
                if let pos = sessionInfo.queuePosition, pos > 0 {
                    loadingPhase = .inQueue(pos)
                } else {
                    loadingPhase = .preparing
                }

                if sessionInfo.status == 2 || sessionInfo.status == 3 {
                    readyPollStreak += 1
                } else {
                    readyPollStreak = 0
                }

                if readyPollStreak >= 2 { break }

                try await Task.sleep(for: .seconds(2))
                sessionInfo = try await cloudMatchClient.pollSession(
                    sessionId: sessionInfo.sessionId,
                    token: token,
                    base: sessionInfo.streamingBaseUrl,
                    serverIp: sessionInfo.serverIp.isEmpty ? nil : sessionInfo.serverIp,
                    clientId: sessionInfo.clientId,
                    deviceId: sessionInfo.deviceId
                )
                createdSession = sessionInfo
            }

            await streamController.connect(session: sessionInfo)
        } catch {
            // error will propagate to streamController.state via connect()
        }
    }

    private func disconnect() {
        // Tell the server to stop the session so it doesn't linger
        if let session = createdSession, let token = sessionToken {
            Task {
                try? await cloudMatchClient.stopSession(
                    sessionId: session.sessionId,
                    token: token,
                    base: session.streamingBaseUrl
                )
            }
        }
        streamController.disconnect()
        onDismiss()
    }

    private func toggleOverlay() {
        overlayTimer?.invalidate()
        showOverlay.toggle()
        if showOverlay {
            overlayTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { _ in
                withAnimation { showOverlay = false }
            }
        }
    }
}
