import Foundation

@MainActor
final class AppSettings: ObservableObject {
    @Published var pushCountPerDay: Int {
        didSet { UserDefaults.standard.set(pushCountPerDay, forKey: Keys.pushCountPerDay) }
    }

    /// Stored as seconds-from-midnight, local time.
    @Published var pushTimesSeconds: [Int] {
        didSet { UserDefaults.standard.set(pushTimesSeconds, forKey: Keys.pushTimesSeconds) }
    }

    /// Playback-style factor **0…1** in **0.05** increments. **1** is normal utterance speed; **0** mutes TTS.
    /// See `RussianHeadwordSpeaker` and `Views/PronunciationSpeedControl.swift`.
    @Published var pronunciationRateScale: Double {
        didSet { UserDefaults.standard.set(pronunciationRateScale, forKey: Keys.pronunciationRateScale) }
    }

    init() {
        let storedCount = UserDefaults.standard.integer(forKey: Keys.pushCountPerDay)
        self.pushCountPerDay = max(1, storedCount == 0 ? 1 : storedCount)

        if let storedTimes = UserDefaults.standard.array(forKey: Keys.pushTimesSeconds) as? [Int], !storedTimes.isEmpty {
            self.pushTimesSeconds = storedTimes.sorted()
        } else {
            // Default: 9:00 AM
            self.pushTimesSeconds = [9 * 3600]
        }

        if let stored = UserDefaults.standard.object(forKey: Keys.pronunciationRateScale) as? Double {
            self.pronunciationRateScale = Self.snapPronunciationRateScale(stored)
        } else {
            self.pronunciationRateScale = 1.0
        }
    }

    func dateComponentsForTimeIndex(_ idx: Int) -> DateComponents {
        let seconds = pushTimesSeconds[safe: idx] ?? (9 * 3600)
        let hour = seconds / 3600
        let minute = (seconds % 3600) / 60
        return DateComponents(hour: hour, minute: minute)
    }

    func setTime(at idx: Int, hour: Int, minute: Int) {
        guard pushTimesSeconds.indices.contains(idx) else { return }
        pushTimesSeconds[idx] = max(0, min(23, hour)) * 3600 + max(0, min(59, minute)) * 60
        pushTimesSeconds.sort()
    }

    func normalizeTimesToPushCount() {
        if pushCountPerDay <= 1 {
            pushTimesSeconds = [pushTimesSeconds.first ?? (9 * 3600)]
            return
        }
        if pushTimesSeconds.count < pushCountPerDay {
            let last = pushTimesSeconds.last ?? (9 * 3600)
            while pushTimesSeconds.count < pushCountPerDay {
                pushTimesSeconds.append(last)
            }
        } else if pushTimesSeconds.count > pushCountPerDay {
            pushTimesSeconds = Array(pushTimesSeconds.prefix(pushCountPerDay))
        }
        pushTimesSeconds.sort()
    }

    static let pronunciationRateStep = 0.05

    /// Rounds into **0…1** on `pronunciationRateStep` (handles legacy stored values).
    static func snapPronunciationRateScale(_ value: Double) -> Double {
        let raw = (value / pronunciationRateStep).rounded() * pronunciationRateStep
        return min(1, max(0, raw))
    }

    private enum Keys {
        static let pushCountPerDay = "push_count_per_day"
        static let pushTimesSeconds = "push_times_seconds"
        static let pronunciationRateScale = "pronunciation_rate_scale"
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}

