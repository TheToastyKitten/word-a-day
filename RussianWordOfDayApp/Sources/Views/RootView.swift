import SwiftUI

struct RootView: View {
    @EnvironmentObject private var router: AppRouter

    var body: some View {
        NavigationStack(path: $router.path) {
            MainView()
                .navigationDestination(for: AppRoute.self) { route in
                    switch route {
                    case .settings:
                        SettingsView()
                    case .alphabet:
                        AlphabetView()
                    case .wordDetail(let id):
                        WordDetailView(wordID: id)
                    }
                }
        }
    }
}

