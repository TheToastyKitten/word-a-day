import Foundation

struct WordEntry: Identifiable, Equatable, Hashable, Codable {
    let id: String
    let russian: String
    let english: String
    let meaning_en: String?
    let phonetic: String?
}

/// One row of the scheduled push buffer: a future, pre-assigned, non-repeating
/// notification with a unique word.
struct ScheduledPush: Identifiable, Hashable {
    /// The matching `UNNotificationRequest.identifier`. Always prefixed with
    /// `push_` so we can safely cancel only ours when settings change.
    let id: String
    let fireAt: Date
    /// Index of this push within its day, 0..<pushCountPerDay at the time of
    /// creation. Informational only — kept for diagnostics, not used to
    /// re-pick words.
    let slot: Int
    let wordID: String
    let createdAt: Date
}

extension ScheduledPush {
    static let identifierPrefix = "push_"
}

/// One entry from `used_words`, joined with its display fields. Designed for
/// a future "Used words" screen that lets the user inspect (and selectively
/// un-use) words that were committed to the rolling buffer.
struct UsedWord: Identifiable, Hashable {
    let word: WordEntry
    let usedAt: Date

    var id: String { word.id }
}

// Seed format (bundled JSON)
typealias SeedWordEntry = WordEntry

enum AppRoute: Hashable {
    case wordDetail(id: String)
    case settings
    case alphabet
    case numbers
    case usedWords
}

