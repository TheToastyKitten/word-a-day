import SwiftUI

@main
struct RussianWordOfDayApp: App {
    @StateObject private var router = AppRouter()
    @StateObject private var settings = AppSettings()
    @StateObject private var store = WordStore()
    @StateObject private var scheduler = WordOfDayScheduler()

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(router)
                .environmentObject(settings)
                .environmentObject(store)
                .environmentObject(scheduler)
                .task {
                    appDelegate.router = router
                    appDelegate.drainPendingWordID(into: router)
                    await store.ensureSeededIfNeeded()
                    await topUpBuffer()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        Task { await topUpBuffer() }
                    }
                }
        }
    }

    /// Best-effort top-up. Failures here are silent because there's no UI
    /// surface to show them on app launch / foreground; the user would only
    /// notice if Settings → Apply also fails, where we DO show an alert.
    private func topUpBuffer() async {
        guard store.isReady else { return }
        do {
            try await scheduler.topUpRollingBuffer(settings: settings, store: store)
        } catch {
            // Swallow: most likely cause is the user denying notifications.
        }
    }
}
