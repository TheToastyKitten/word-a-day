import Foundation

struct WordEntry: Identifiable, Equatable, Hashable {
    let id: String
    let russian: String
    let english: String
    let meaning_en: String?
    let pos: String?
    let glosses_en: String?
    let examples_en: String?
    let ai_note_en: String?
    let phonetic: String?
    /// True when lexicon data was fully baked into the bundle at build time (legacy column name).
    let wiktionaryBaked: Bool
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

/// One entry from `used_words`, joined with its display fields.
struct UsedWord: Identifiable, Hashable {
    let word: WordEntry
    let usedAt: Date

    var id: String { word.id }
}

/// One entry from `favorite_words`, joined with its display fields.
struct FavoriteWord: Identifiable, Hashable {
    let word: WordEntry
    let favoritedAt: Date

    var id: String { word.id }
}

enum AppRoute: Hashable {
    case wordDetail(id: String)
    case settings
    case legal
    case alphabet
    case numbers
    case usedWords
    case favorites
    case quiz
}

