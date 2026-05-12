import Foundation
import SwiftUI

@MainActor
final class AppRouter: ObservableObject {
    @Published var path: [AppRoute] = []
    @Published var pendingWordIDFromNotification: String?

    func openWordDetail(id: String) {
        // Ensure the detail is pushed deterministically even if user is deep in nav.
        path = [.wordDetail(id: id)]
    }

    func openSettings() {
        path.append(.settings)
    }

    func openAlphabet() {
        path.append(.alphabet)
    }

    func openNumbers() {
        path.append(.numbers)
    }

    func openUsedWords() {
        path.append(.usedWords)
    }

    func openQuiz() {
        path.append(.quiz)
    }
}

