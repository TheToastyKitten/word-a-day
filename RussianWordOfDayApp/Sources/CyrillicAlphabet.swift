import Foundation

/// One Cyrillic letter, sourced from the bundled "Russian Alphabet with Sound
/// and Handwriting" reference PDF.
///
/// - `nameEn`: how an English speaker says the *name* of the letter when
///   reciting the alphabet (PDF column "Name of Letter").
/// - `similarSoundEn`: a short English phrase describing the letter's *sound*
///   inside a word (PDF column "Similar English Sound"). Nil for the two
///   silent signs.
/// - `soundNote`: populated only when the letter has no sound (Ь, Ъ);
///   otherwise nil.
struct CyrillicLetter: Identifiable, Hashable {
    let upper: String
    let lower: String
    let nameEn: String
    let similarSoundEn: String?
    let soundNote: String?

    var id: String { upper }

    /// Single string for UI: prefer the explicit "no sound" annotation,
    /// otherwise the PDF's similar-sound phrase, otherwise nil.
    var soundDescription: String? {
        soundNote ?? similarSoundEn
    }
}

/// Single source of truth for the modern Russian alphabet (33 letters).
/// Values are taken verbatim from the bundled PDF reference.
enum CyrillicAlphabet {
    static let letters: [CyrillicLetter] = [
        CyrillicLetter(upper: "А", lower: "а", nameEn: "a", similarSoundEn: "like ar in far", soundNote: nil),
        CyrillicLetter(upper: "Б", lower: "б", nameEn: "be", similarSoundEn: "like b in box", soundNote: nil),
        CyrillicLetter(upper: "В", lower: "в", nameEn: "ve", similarSoundEn: "like v in voice", soundNote: nil),
        CyrillicLetter(upper: "Г", lower: "г", nameEn: "ge", similarSoundEn: "like g in go", soundNote: nil),
        CyrillicLetter(upper: "Д", lower: "д", nameEn: "de", similarSoundEn: "like d in day", soundNote: nil),
        CyrillicLetter(upper: "Е", lower: "е", nameEn: "ye", similarSoundEn: "like ye in yet or e in exit", soundNote: nil),
        CyrillicLetter(upper: "Ё", lower: "ё", nameEn: "yo", similarSoundEn: "like yo in your", soundNote: nil),
        CyrillicLetter(upper: "Ж", lower: "ж", nameEn: "zhe", similarSoundEn: "like s in pleasure", soundNote: nil),
        CyrillicLetter(upper: "З", lower: "з", nameEn: "ze", similarSoundEn: "like z in zoo", soundNote: nil),
        CyrillicLetter(upper: "И", lower: "и", nameEn: "ee", similarSoundEn: "like ee in meet", soundNote: nil),
        CyrillicLetter(upper: "Й", lower: "й", nameEn: "ee kratkoye (short i)", similarSoundEn: "like y in boy", soundNote: nil),
        CyrillicLetter(upper: "К", lower: "к", nameEn: "ka", similarSoundEn: "like k in key or c in cat", soundNote: nil),
        CyrillicLetter(upper: "Л", lower: "л", nameEn: "el", similarSoundEn: "like l in lamp", soundNote: nil),
        CyrillicLetter(upper: "М", lower: "м", nameEn: "em", similarSoundEn: "like m in man", soundNote: nil),
        CyrillicLetter(upper: "Н", lower: "н", nameEn: "en", similarSoundEn: "like n in note", soundNote: nil),
        CyrillicLetter(upper: "О", lower: "о", nameEn: "o", similarSoundEn: "like o in not", soundNote: nil),
        CyrillicLetter(upper: "П", lower: "п", nameEn: "pe", similarSoundEn: "like p in pet", soundNote: nil),
        CyrillicLetter(upper: "Р", lower: "р", nameEn: "er", similarSoundEn: "like r in rock (but rolled)", soundNote: nil),
        CyrillicLetter(upper: "С", lower: "с", nameEn: "es", similarSoundEn: "like s in sun", soundNote: nil),
        CyrillicLetter(upper: "Т", lower: "т", nameEn: "te", similarSoundEn: "like t in table", soundNote: nil),
        CyrillicLetter(upper: "У", lower: "у", nameEn: "oo", similarSoundEn: "like oo in moon", soundNote: nil),
        CyrillicLetter(upper: "Ф", lower: "ф", nameEn: "ef", similarSoundEn: "like f in food", soundNote: nil),
        CyrillicLetter(upper: "Х", lower: "х", nameEn: "kha", similarSoundEn: "like ch in Scottish loch", soundNote: nil),
        CyrillicLetter(upper: "Ц", lower: "ц", nameEn: "tse", similarSoundEn: "like ts in boots", soundNote: nil),
        CyrillicLetter(upper: "Ч", lower: "ч", nameEn: "che", similarSoundEn: "like ch in chat", soundNote: nil),
        CyrillicLetter(upper: "Ш", lower: "ш", nameEn: "sha", similarSoundEn: "like sh in short", soundNote: nil),
        CyrillicLetter(upper: "Щ", lower: "щ", nameEn: "shcha", similarSoundEn: "like sh_ch in fresh_cheese", soundNote: nil),
        CyrillicLetter(upper: "Ъ", lower: "ъ", nameEn: "tviordiy znak (hard sign)", similarSoundEn: nil, soundNote: "has no sound"),
        CyrillicLetter(upper: "Ы", lower: "ы", nameEn: "ih*", similarSoundEn: "like i in ill", soundNote: nil),
        CyrillicLetter(upper: "Ь", lower: "ь", nameEn: "myagkiy znak (soft sign)", similarSoundEn: nil, soundNote: "has no sound"),
        CyrillicLetter(upper: "Э", lower: "э", nameEn: "e", similarSoundEn: "like e in end", soundNote: nil),
        CyrillicLetter(upper: "Ю", lower: "ю", nameEn: "yoo", similarSoundEn: "like u in use", soundNote: nil),
        CyrillicLetter(upper: "Я", lower: "я", nameEn: "ya", similarSoundEn: "like ya in yard", soundNote: nil),
    ]

    private static let byLower: [Character: CyrillicLetter] = {
        var dict: [Character: CyrillicLetter] = [:]
        for letter in letters {
            if let c = letter.lower.first { dict[c] = letter }
            if let c = letter.upper.first { dict[c] = letter }
        }
        return dict
    }()

    /// Looks up the letter for a given character (case-insensitive).
    /// Returns nil for non-Cyrillic characters (digits, punctuation, etc.).
    static func letter(for character: Character) -> CyrillicLetter? {
        byLower[character]
    }

    /// Returns each Cyrillic letter that appears in `word`, in order.
    /// Duplicates are kept (so "мама" → м, а, м, а). Non-Cyrillic characters
    /// (spaces, punctuation, digits) are skipped.
    static func letters(in word: String) -> [CyrillicLetter] {
        word.compactMap { letter(for: $0) }
    }
}
