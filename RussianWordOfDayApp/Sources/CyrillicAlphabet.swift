import Foundation

/// One "phoneme example": the chunk of an English example word that produces
/// the letter's sound. `phonetic = "ar"`, `example = "far"` → rendered as
/// "like ar in far" with "ar" emphasised inside "far".
///
/// `note` carries any trailing parenthetical that doesn't fit the
/// "like X in Y" template (e.g. "(but rolled)" for Р).
struct PhoneticExample: Hashable {
    let phonetic: String
    let example: String
    let note: String?
}

/// One Cyrillic letter, sourced from the bundled "Russian Alphabet with Sound
/// and Handwriting" reference PDF.
///
/// - `nameEn`: how an English speaker says the *name* of the letter when
///   reciting the alphabet (PDF column "Name of Letter").
/// - `phoneticExamples`: structured phoneme data for the letter's sound inside
///   a word. Empty only for the two silent signs (Ь, Ъ).
/// - `soundNote`: populated only when the letter has no sound (Ь, Ъ);
///   otherwise nil.
struct CyrillicLetter: Identifiable, Hashable {
    let upper: String
    let lower: String
    let nameEn: String
    let phoneticExamples: [PhoneticExample]
    let soundNote: String?

    var id: String { upper }
}

extension CyrillicLetter {
    /// Reproduces the previous flat string ("like ar in far",
    /// "like ye in yet or e in exit") for VoiceOver and any code that
    /// still wants the plain phrase.
    var similarSoundEnPhrase: String? {
        guard !phoneticExamples.isEmpty else { return nil }
        let parts = phoneticExamples.map { ex in
            var s = "like \(ex.phonetic) in \(ex.example)"
            if let note = ex.note { s += " \(note)" }
            return s
        }
        return parts.joined(separator: " or ")
    }

    /// Single string for UI / VoiceOver: prefer the explicit "no sound"
    /// annotation, otherwise derive the phrase from structured data.
    var soundDescription: String? {
        soundNote ?? similarSoundEnPhrase
    }

    /// Returns an `AttributedString` rendering of the full
    /// "like X in Y or A in B" phrase, with the phonetic chunk emphasised
    /// inside both its name (X) and its example word (Y).
    /// Returns nil when the letter has no examples (Ь, Ъ).
    func attributedSoundDescription(
        emphasis: AttributeContainer = AttributeContainer().font(.footnote.weight(.semibold))
    ) -> AttributedString? {
        guard !phoneticExamples.isEmpty else { return nil }

        var out = AttributedString()
        for (idx, ex) in phoneticExamples.enumerated() {
            if idx == 0 {
                out += AttributedString("like ")
            } else {
                out += AttributedString(" or ")
            }

            var chunk = AttributedString(ex.phonetic)
            chunk.mergeAttributes(emphasis)
            out += chunk

            out += AttributedString(" in ")

            out += highlight(chunk: ex.phonetic, in: ex.example, emphasis: emphasis)

            if let note = ex.note {
                out += AttributedString(" \(note)")
            }
        }
        return out
    }

    private func highlight(
        chunk: String,
        in source: String,
        emphasis: AttributeContainer
    ) -> AttributedString {
        var attr = AttributedString(source)
        guard !chunk.isEmpty else { return attr }
        var searchRange = attr.startIndex..<attr.endIndex
        while let range = attr[searchRange].range(of: chunk, options: .caseInsensitive) {
            attr[range].mergeAttributes(emphasis)
            searchRange = range.upperBound..<attr.endIndex
        }
        return attr
    }
}

/// Single source of truth for the modern Russian alphabet (33 letters).
/// Values are taken verbatim from the bundled PDF reference.
enum CyrillicAlphabet {
    static let letters: [CyrillicLetter] = [
        CyrillicLetter(upper: "А", lower: "а", nameEn: "a",
            phoneticExamples: [PhoneticExample(phonetic: "ar", example: "far", note: nil)],
            soundNote: nil),
        CyrillicLetter(upper: "Б", lower: "б", nameEn: "be",
            phoneticExamples: [PhoneticExample(phonetic: "b", example: "box", note: nil)],
            soundNote: nil),
        CyrillicLetter(upper: "В", lower: "в", nameEn: "ve",
            phoneticExamples: [PhoneticExample(phonetic: "v", example: "voice", note: nil)],
            soundNote: nil),
        CyrillicLetter(upper: "Г", lower: "г", nameEn: "ge",
            phoneticExamples: [PhoneticExample(phonetic: "g", example: "go", note: nil)],
            soundNote: nil),
        CyrillicLetter(upper: "Д", lower: "д", nameEn: "de",
            phoneticExamples: [PhoneticExample(phonetic: "d", example: "day", note: nil)],
            soundNote: nil),
        CyrillicLetter(upper: "Е", lower: "е", nameEn: "ye",
            phoneticExamples: [
                PhoneticExample(phonetic: "ye", example: "yet", note: nil),
                PhoneticExample(phonetic: "e",  example: "exit", note: nil),
            ],
            soundNote: nil),
        CyrillicLetter(upper: "Ё", lower: "ё", nameEn: "yo",
            phoneticExamples: [PhoneticExample(phonetic: "yo", example: "your", note: nil)],
            soundNote: nil),
        CyrillicLetter(upper: "Ж", lower: "ж", nameEn: "zhe",
            phoneticExamples: [PhoneticExample(phonetic: "s", example: "pleasure", note: nil)],
            soundNote: nil),
        CyrillicLetter(upper: "З", lower: "з", nameEn: "ze",
            phoneticExamples: [PhoneticExample(phonetic: "z", example: "zoo", note: nil)],
            soundNote: nil),
        CyrillicLetter(upper: "И", lower: "и", nameEn: "ee",
            phoneticExamples: [PhoneticExample(phonetic: "ee", example: "meet", note: nil)],
            soundNote: nil),
        CyrillicLetter(upper: "Й", lower: "й", nameEn: "ee kratkoye (short i)",
            phoneticExamples: [PhoneticExample(phonetic: "y", example: "boy", note: nil)],
            soundNote: nil),
        CyrillicLetter(upper: "К", lower: "к", nameEn: "ka",
            phoneticExamples: [
                PhoneticExample(phonetic: "k", example: "key", note: nil),
                PhoneticExample(phonetic: "c", example: "cat", note: nil),
            ],
            soundNote: nil),
        CyrillicLetter(upper: "Л", lower: "л", nameEn: "el",
            phoneticExamples: [PhoneticExample(phonetic: "l", example: "lamp", note: nil)],
            soundNote: nil),
        CyrillicLetter(upper: "М", lower: "м", nameEn: "em",
            phoneticExamples: [PhoneticExample(phonetic: "m", example: "man", note: nil)],
            soundNote: nil),
        CyrillicLetter(upper: "Н", lower: "н", nameEn: "en",
            phoneticExamples: [PhoneticExample(phonetic: "n", example: "note", note: nil)],
            soundNote: nil),
        CyrillicLetter(upper: "О", lower: "о", nameEn: "o",
            phoneticExamples: [PhoneticExample(phonetic: "o", example: "not", note: nil)],
            soundNote: nil),
        CyrillicLetter(upper: "П", lower: "п", nameEn: "pe",
            phoneticExamples: [PhoneticExample(phonetic: "p", example: "pet", note: nil)],
            soundNote: nil),
        CyrillicLetter(upper: "Р", lower: "р", nameEn: "er",
            phoneticExamples: [PhoneticExample(phonetic: "r", example: "rock", note: "(but rolled)")],
            soundNote: nil),
        CyrillicLetter(upper: "С", lower: "с", nameEn: "es",
            phoneticExamples: [PhoneticExample(phonetic: "s", example: "sun", note: nil)],
            soundNote: nil),
        CyrillicLetter(upper: "Т", lower: "т", nameEn: "te",
            phoneticExamples: [PhoneticExample(phonetic: "t", example: "table", note: nil)],
            soundNote: nil),
        CyrillicLetter(upper: "У", lower: "у", nameEn: "oo",
            phoneticExamples: [PhoneticExample(phonetic: "oo", example: "moon", note: nil)],
            soundNote: nil),
        CyrillicLetter(upper: "Ф", lower: "ф", nameEn: "ef",
            phoneticExamples: [PhoneticExample(phonetic: "f", example: "food", note: nil)],
            soundNote: nil),
        CyrillicLetter(upper: "Х", lower: "х", nameEn: "kha",
            phoneticExamples: [PhoneticExample(phonetic: "ch", example: "Scottish loch", note: nil)],
            soundNote: nil),
        CyrillicLetter(upper: "Ц", lower: "ц", nameEn: "tse",
            phoneticExamples: [PhoneticExample(phonetic: "ts", example: "boots", note: nil)],
            soundNote: nil),
        CyrillicLetter(upper: "Ч", lower: "ч", nameEn: "che",
            phoneticExamples: [PhoneticExample(phonetic: "ch", example: "chat", note: nil)],
            soundNote: nil),
        CyrillicLetter(upper: "Ш", lower: "ш", nameEn: "sha",
            phoneticExamples: [PhoneticExample(phonetic: "sh", example: "short", note: nil)],
            soundNote: nil),
        CyrillicLetter(upper: "Щ", lower: "щ", nameEn: "shcha",
            phoneticExamples: [PhoneticExample(phonetic: "sh_ch", example: "fresh_cheese", note: nil)],
            soundNote: nil),
        CyrillicLetter(upper: "Ъ", lower: "ъ", nameEn: "tviordiy znak (hard sign)",
            phoneticExamples: [],
            soundNote: "has no sound"),
        CyrillicLetter(upper: "Ы", lower: "ы", nameEn: "ih*",
            phoneticExamples: [PhoneticExample(phonetic: "i", example: "ill", note: nil)],
            soundNote: nil),
        CyrillicLetter(upper: "Ь", lower: "ь", nameEn: "myagkiy znak (soft sign)",
            phoneticExamples: [],
            soundNote: "has no sound"),
        CyrillicLetter(upper: "Э", lower: "э", nameEn: "e",
            phoneticExamples: [PhoneticExample(phonetic: "e", example: "end", note: nil)],
            soundNote: nil),
        CyrillicLetter(upper: "Ю", lower: "ю", nameEn: "yoo",
            phoneticExamples: [PhoneticExample(phonetic: "u", example: "use", note: nil)],
            soundNote: nil),
        CyrillicLetter(upper: "Я", lower: "я", nameEn: "ya",
            phoneticExamples: [PhoneticExample(phonetic: "ya", example: "yard", note: nil)],
            soundNote: nil),
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
