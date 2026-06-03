import Foundation

/// OpenRussian-style glosses: one translation CSV row → one meaning line; commas = synonyms on that line.
enum GlossFormatting {
    static func commaClauses(in text: String) -> [String] {
        text.split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Short label for search rows (first synonym on the headline line).
    static func englishHeadline(for english: String) -> String {
        let trimmed = english.trimmingCharacters(in: .whitespacesAndNewlines)
        return commaClauses(in: trimmed).first ?? trimmed
    }

    /// Numbered **Meaning** lines: one per OpenRussian translation row in ``glosses_en``.
    static func allMeaningLines(
        english: String,
        glosses_en: String?,
        meaning_en: String?
    ) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []

        func append(_ raw: String) {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            let key = t.lowercased()
            guard !seen.contains(key) else { return }
            seen.insert(key)
            out.append(t)
        }

        if let glosses = glosses_en {
            for line in glosses.split(separator: "\n") {
                append(String(line))
            }
        }

        if out.isEmpty {
            append(english)
            if let meaning = meaning_en {
                for part in meaning.split(separator: ";") {
                    append(String(part))
                }
            }
        }

        return out
    }
}

extension WordEntry {
    /// Primary gloss under the Russian headword (first synonym on the headline).
    var englishHeadline: String {
        GlossFormatting.englishHeadline(for: english)
    }

    /// OpenRussian-ordered gloss lines for the word detail **Meaning** section.
    var allMeaningLines: [String] {
        GlossFormatting.allMeaningLines(
            english: english,
            glosses_en: glosses_en,
            meaning_en: meaning_en
        )
    }
}
