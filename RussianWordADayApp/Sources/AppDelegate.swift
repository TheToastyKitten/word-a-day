import Foundation
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Wired up by `RussianWordADayApp` once SwiftUI has constructed the
    /// `AppRouter`. May briefly be nil during cold launch from a notification
    /// tap, so `pendingWordID` exists as a buffer.
    weak var router: AppRouter?

    /// Holds a `word_id` extracted from a notification tap when the router
    /// isn't attached yet. Drained by `RussianWordADayApp.attachRouter`.
    private(set) var pendingWordID: String?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// Show the notification banner even while the app is in the foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        return [.banner, .list, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        guard let wordID = userInfo[NotificationKeys.wordID] as? String else { return }

        await MainActor.run {
            if let router {
                router.openWordDetail(id: wordID)
            } else {
                pendingWordID = wordID
            }
        }
    }

    @MainActor
    func drainPendingWordID(into router: AppRouter) {
        guard let id = pendingWordID else { return }
        pendingWordID = nil
        router.openWordDetail(id: id)
    }
}
