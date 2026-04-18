import SwiftUI

struct MainTabView: View {
    @Environment(AuthManager.self) var authManager
    @Environment(GamesViewModel.self) var viewModel
    @State private var gameToPlay: GameInfo?
    @State private var sessionToResume: ActiveSessionInfo? = nil

    var body: some View {
        TabView {
            Tab("Home", systemImage: "house.fill") {
                HomeView(onPlay: { game in
                    let session = viewModel.activeSessions.first { session in
                        game.variants.contains { v in
                            guard let appId = v.appId, let sessionAppId = session.appId else { return false }
                            return appId == sessionAppId
                        }
                    }
                    play(game, session: session)
                })
            }
            Tab("Library", systemImage: "books.vertical.fill") {
                LibraryView(games: viewModel.libraryGames, onPlay: { play($0) })
            }
            Tab("Store", systemImage: "bag.fill") {
                StoreView(games: viewModel.mainGames, onPlay: { play($0) })
            }
            Tab("Settings", systemImage: "gearshape.fill") {
                SettingsView()
            }
        }
        .task { await viewModel.load(authManager: authManager) }
        .onChange(of: viewModel.streamSettings) { viewModel.saveSettings() }
        .onChange(of: gameToPlay) { _, new in
            if new == nil {
                Task { await viewModel.refreshActiveSessions(authManager: authManager) }
            }
        }
        .fullScreenCover(item: $gameToPlay) { game in
            StreamView(
                game: game,
                settings: viewModel.streamSettings,
                existingSession: sessionToResume,
                onDismiss: {
                    gameToPlay = nil
                    sessionToResume = nil
                }
            )
            .environment(authManager)
            .environment(viewModel)
        }
    }

    private func play(_ game: GameInfo, session: ActiveSessionInfo? = nil) {
        sessionToResume = session
        gameToPlay = game
    }
}
