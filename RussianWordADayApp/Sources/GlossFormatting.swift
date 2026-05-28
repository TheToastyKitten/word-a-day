import Foundation

/// OpenRussian-style glosses: commas separate synonyms; semicolons separate distinct meanings.
enum GlossFormatting {
    static func commaClauses(in text: String) -> [String] {
        text.split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func englishHeadline(for english: String) -> String {
        let trimmed = english.trimmingCharacters(in: .whitespacesAndNewlines)
        return commaClauses(in: trimmed).first ?? trimmed
    }

    /// Synonym / extra-meaning lines for the **Meaning** section (excludes the headline).
    static func additionalMeaningLines(
        english: String,
        glosses_en: String?,
        meaning_en: String?
    ) -> [String] {
        let headlineKey = englishHeadline(for: english).lowercased()
        var seen: Set<String> = []
        var out: [String] = []

        func appendClauses(from raw: String) {
            for clause in commaClauses(in: raw) {
                let key = clause.lowercased()
                guard key != headlineKey, !seen.contains(key) else { continue }
                seen.insert(key)
                out.append(clause)
            }
        }

        if let glosses = glosses_en {
            for line in glosses.split(separator: "\n") {
                appendClauses(from: String(line))
            }
        }

        if let meaning = meaning_en {
            for part in meaning.split(separator: ";") {
                appendClauses(from: String(part))
            }
        }

        // Headline field may still list extra comma-separated synonyms before DB refresh.
        for clause in commaClauses(in: english).dropFirst() {
            let key = clause.lowercased()
            guard key != headlineKey, !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(clause)
        }

        return out
    }

    /// All learner gloss lines for **Meaning** (headline first, then extras).
    static func allMeaningLines(
        english: String,
        glosses_en: String?,
        meaning_en: String?
    ) -> [String] {
        let headline = englishHeadline(for: english)
        let extras = additionalMeaningLines(
            english: english,
            glosses_en: glosses_en,
            meaning_en: meaning_en
        )
        guard !headline.isEmpty else { return extras }
        return [headline] + extras
    }
}

extension WordEntry {
    /// Primary gloss under the Russian headword (first comma-separated synonym).
    var englishHeadline: String {
        GlossFormatting.englishHeadline(for: english)
    }

    /// Primary gloss plus extras, for the word detail **Meaning** section.
    var allMeaningLines: [String] {
        GlossFormatting.allMeaningLines(
            english: english,
            glosses_en: glosses_en,
            meaning_en: meaning_en
        )
    }
}
