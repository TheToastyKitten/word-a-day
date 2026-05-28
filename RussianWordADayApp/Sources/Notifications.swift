import Foundation
import UserNotifications

enum NotificationKeys {
    static let wordID = "word_id"
}

@MainActor
final class NotificationManager: NSObject, ObservableObject {
    static let shared = NotificationManager()

    private override init() {}

    func requestAuthorizationIfNeeded() async throws -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        @unknown default:
            return false
        }
    }

    /// Removes only requests whose identifier starts with `prefix`. Used to
    /// scrub the rolling buffer's `push_*` requests on settings change without
    /// disturbing anything else iOS may have queued.
    func removePending(withPrefix prefix: String) async {
        let center = UNUserNotificationCenter.current()
        let requests = await center.pendingNotificationRequests()
        let ids = requests.map(\.identifier).filter { $0.hasPrefix(prefix) }
        if !ids.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    /// Schedules a single non-repeating notification at exactly `fireAt`.
    /// Used by the rolling-buffer scheduler — each push is its own request,
    /// so the content (word) is fixed at schedule time and never repeats.
    func scheduleOneShot(
        word: WordEntry,
        fireAt: Date,
        identifier: String
    ) async throws {
        let content = UNMutableNotificationContent()
        content.title = word.russian
        content.body = word.englishHeadline
        content.sound = .default
        content.userInfo = [NotificationKeys.wordID: word.id]

        // Use calendar components down to the second so iOS fires at the exact
        // wall-clock time the user picked, in their local timezone.
        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: fireAt
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        try await UNUserNotificationCenter.current().add(request)
    }
}
