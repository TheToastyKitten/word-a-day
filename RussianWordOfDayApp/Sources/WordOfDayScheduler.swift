import Foundation
import UserNotifications

/// Maintains a rolling buffer of upcoming non-repeating local notifications.
///
/// Each push gets its own one-shot `UNNotificationRequest` with a unique word
/// chosen at schedule time. This is what prevents the "the same word fires
/// every day" bug that came from `UNCalendarNotificationTrigger(repeats: true)`.
@MainActor
final class WordOfDayScheduler: ObservableObject {
    /// How many future pushes we keep queued at any given time. The buffer
    /// is measured in *pushes*, not days, so it scales with `pushCountPerDay`:
    /// 1/day → ~60 days, 3/day → ~20 days, 5/day → ~12 days.
    static let bufferTarget = 60

    struct Result {
        /// Pushes added by this run.
        var addedCount: Int
        /// Pushes already in the buffer at the start of the run.
        var preexistingCount: Int
        /// Total future pushes after this run completes.
        var bufferCount: Int
        /// True if we couldn't fill the buffer to the target because the
        /// dictionary's unused-word pool ran out.
        var exhausted: Bool
    }

    /// Adds enough new pushes to reach `bufferTarget`, picking the next
    /// chronological fire time after whatever's already queued (or `now`,
    /// if the buffer is empty). Existing buffer entries are NEVER touched —
    /// repeated calls are cheap when the buffer is already full.
    ///
    /// Call sites:
    /// - app launch (after seeding)
    /// - app entering foreground
    /// - after user changed settings (preceded by `rebuild`)
    @discardableResult
    func topUpRollingBuffer(
        settings: AppSettings,
        store: WordStore,
        now: Date = Date()
    ) async throws -> Result {
        settings.normalizeTimesToPushCount()

        // Promote any fired pushes to used_words and drop those rows so the
        // count math is honest. This is also our deferred-"used" hook: a push
        // that fired since the last call lands in used_words here.
        store.promoteFiredPushesAndPurge(now: now)

        let allowed = try await NotificationManager.shared.requestAuthorizationIfNeeded()
        let preexisting = store.futureScheduledPushCount(now: now)

        guard allowed else {
            return Result(
                addedCount: 0,
                preexistingCount: preexisting,
                bufferCount: preexisting,
                exhausted: false
            )
        }

        let target = Self.bufferTarget
        var current = preexisting
        if current >= target {
            return Result(
                addedCount: 0,
                preexistingCount: preexisting,
                bufferCount: current,
                exhausted: false
            )
        }

        // Start generating fire times AFTER whatever is already queued,
        // so the new entries extend the tail rather than overlap.
        let startAfter = store.latestFutureFireAt(now: now) ?? now
        var fireGen = FireTimeGenerator(
            after: startAfter,
            pushTimesSeconds: settings.pushTimesSeconds,
            calendar: .current
        )

        var added = 0
        var exhausted = false
        while current < target {
            guard let (fireAt, slot) = fireGen.next() else { break }
            let identifier = "\(ScheduledPush.identifierPrefix)\(UUID().uuidString)"
            guard let (_, word) = store.reserveAndPersistPush(
                identifier: identifier,
                fireAt: fireAt,
                slot: slot
            ) else {
                exhausted = true
                break
            }
            do {
                try await NotificationManager.shared.scheduleOneShot(
                    word: word,
                    fireAt: fireAt,
                    identifier: identifier
                )
                added += 1
                current += 1
                await Task.yield()
            } catch {
                // The DB row was already committed (word reserved in scheduled_pushes).
                // Bail rather than diverge from iOS — the next top-up will see
                // the orphan row, promoteFiredPushesAndPurge will clean it once
                // fire_at elapses, and the user keeps their pool integrity.
                throw error
            }
        }

        return Result(
            addedCount: added,
            preexistingCount: preexisting,
            bufferCount: current,
            exhausted: exhausted
        )
    }

    /// Tears down ALL future scheduled pushes (both in the DB and in iOS),
    /// then tops the buffer back up. Use this when the user changes
    /// `pushCountPerDay` or `pushTimesSeconds` — the existing fire times no
    /// longer match the new schedule and need to be rebuilt.
    ///
    /// Words that were only reserved (never fired) are released back into the
    /// pool. Only actually-fired words (promoted to `used_words`) won't repeat.
    @discardableResult
    func rebuildAfterSettingsChange(
        settings: AppSettings,
        store: WordStore,
        now: Date = Date()
    ) async throws -> Result {
        await NotificationManager.shared.removePending(
            withPrefix: ScheduledPush.identifierPrefix
        )
        store.clearScheduledPushes()
        return try await topUpRollingBuffer(settings: settings, store: store, now: now)
    }

    /// Cancels every push request and clears the DB buffer. Used by
    /// "Reset already used words" — the WordStore reset clears `used_words`
    /// and `scheduled_pushes`; this call removes the matching iOS requests.
    func purgeAfterReset() async {
        await NotificationManager.shared.removePending(
            withPrefix: ScheduledPush.identifierPrefix
        )
    }

    /// Brings a single word back into the pool: removes it from `used_words`,
    /// drops any pending pushes referencing it, cancels the matching iOS
    /// notification requests, and tops up the rolling buffer so the freed
    /// slot is back-filled at the tail.
    ///
    /// This is the persistence-side entry point for a future "Used words"
    /// screen with a per-row "re-add to pool" action.
    @discardableResult
    func unuseWord(
        id wordID: String,
        settings: AppSettings,
        store: WordStore,
        now: Date = Date()
    ) async throws -> Result {
        let cancelled = store.markWordUnused(id: wordID)
        if !cancelled.isEmpty {
            UNUserNotificationCenter.current().removePendingNotificationRequests(
                withIdentifiers: cancelled
            )
        }
        return try await topUpRollingBuffer(settings: settings, store: store, now: now)
    }
}

// MARK: - FireTimeGenerator

/// Lazy chronological generator of (fireDate, slotIndex) pairs derived from
/// `pushTimesSeconds` (each entry is seconds-from-midnight, local time).
///
/// Iterates day by day starting on the day of `after`, yielding only the
/// in-day times that fall strictly later than `after`. Skips ahead one day
/// once a day's times are exhausted. Has no upper bound — caller stops it
/// when their target count is reached.
private struct FireTimeGenerator: IteratorProtocol {
    typealias Element = (fireAt: Date, slot: Int)

    private let pushTimesSeconds: [Int]
    private let calendar: Calendar
    private let after: Date

    private var dayCursor: Date
    private var nextSlot: Int = 0

    init(after: Date, pushTimesSeconds: [Int], calendar: Calendar) {
        self.after = after
        self.pushTimesSeconds = pushTimesSeconds.sorted()
        self.calendar = calendar
        self.dayCursor = calendar.startOfDay(for: after)
    }

    mutating func next() -> Element? {
        guard !pushTimesSeconds.isEmpty else { return nil }

        // Hard guardrail: if the user only configured one time and it's
        // 00:00, we'd still advance day-by-day, but if pushTimesSeconds is
        // somehow degenerate we cap iteration to avoid an infinite loop.
        var safety = 365 * 5
        while safety > 0 {
            safety -= 1
            if nextSlot >= pushTimesSeconds.count {
                nextSlot = 0
                guard let nextDay = calendar.date(byAdding: .day, value: 1, to: dayCursor) else {
                    return nil
                }
                dayCursor = nextDay
            }
            let secondsOfDay = pushTimesSeconds[nextSlot]
            let candidate = dayCursor.addingTimeInterval(TimeInterval(secondsOfDay))
            let slot = nextSlot
            nextSlot += 1
            if candidate > after {
                return (candidate, slot)
            }
        }
        return nil
    }
}
