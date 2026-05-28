import SwiftUI

struct RootView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var store: WordStore

    var body: some View {
        if store.isReady {
            NavigationStack(path: $router.path) {
                MainView()
                    .navigationDestination(for: AppRoute.self) { route in
                        switch route {
                        case .settings:
                            SettingsView()
                        case .legal:
                            LegalView()
                        case .alphabet:
                            AlphabetView()
                        case .numbers:
                            NumbersView()
                        case .wordDetail(let id):
                            WordDetailView(wordID: id)
                        case .usedWords:
                            ManageUsedWordsView()
                        case .favorites:
                            FavoritesView()
                        case .quiz:
                            QuizYourselfView()
                        }
                    }
            }
        } else {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()
                .overlay {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading dictionary…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
        }
    }
}

