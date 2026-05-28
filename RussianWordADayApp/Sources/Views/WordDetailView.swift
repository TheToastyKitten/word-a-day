import SwiftUI

struct WordDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: WordStore
    @StateObject private var pronunciationSpeaker = RussianHeadwordSpeaker()
    @State private var isFavorite = false

    /// Maximum numbered lines under **Meaning** (offline glosses).
    private static let meaningLineDisplayLimit = 5
    private static let exampleLineDisplayLimit = 6

    /// Nav bar icon nudge (points). Positive y = down.
    private enum NavBarIconOffset {
        static let backX: CGFloat = 0
        static let backY: CGFloat = 0
        static let favouriteX: CGFloat = 0
        static let favouriteY: CGFloat = 0
    }

    private static let navBarButtonSize: CGFloat = 44
    private static let navBarSymbolSize: CGFloat = 20

    let wordID: String

    var body: some View {
        let word = store.getWord(id: wordID)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let word {
                    headerSection(word: word)
                    meaningSection(word: word)
                    pronunciationSection(word: word)
                    examplesSection(word: word)
                    lettersSection(for: word.russian)
                } else {
                    Text("Word not found.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "rwd", url.host == "word" {
                    let id = url.lastPathComponent
                    if !id.isEmpty {
                        router.openWordDetail(id: id)
                        return .handled
                    }
                }
                return .systemAction
            })
        }
        .navigationTitle("Word")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            // —— Back (custom so it shares the same center line as the star) ——
            ToolbarItem(placement: .topBarLeading) {
                navBarIconButton(accessibilityLabel: "Back", action: { dismiss() }) {
                    Image(systemName: "chevron.left")
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: Self.navBarSymbolSize, weight: .semibold))
                        .offset(x: NavBarIconOffset.backX, y: NavBarIconOffset.backY)
                }
            }
            // —— Favourite ——
            ToolbarItem(placement: .topBarTrailing) {
                navBarIconButton(
                    accessibilityLabel: isFavorite ? "Remove from favourites" : "Add to favourites",
                    action: { isFavorite = store.toggleFavorite(id: wordID) }
                ) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .symbolRenderingMode(.monochrome)
                        .font(.system(size: Self.navBarSymbolSize, weight: .regular))
                        .offset(x: NavBarIconOffset.favouriteX, y: NavBarIconOffset.favouriteY)
                }
            }
        }
        .task(id: wordID) {
            if store.getWord(id: wordID) != nil {
                store.recordRecentView(id: wordID)
            }
            isFavorite = store.isFavorite(id: wordID)
        }
        .onChange(of: wordID) { _, _ in
            pronunciationSpeaker.stopImmediately()
        }
        .onDisappear {
            pronunciationSpeaker.stopImmediately()
        }
    }

    private func navBarIconButton<Icon: View>(
        accessibilityLabel: String,
        action: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        Button(action: action) {
            ZStack {
                icon()
            }
            .foregroundStyle(.primary)
            .frame(width: Self.navBarButtonSize, height: Self.navBarButtonSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private func headerSection(word: WordEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(word.russian)
                    .font(.system(size: 44, weight: .bold, design: .serif))
                if let pos = posDisplay(word.pos) {
                    Text(pos)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(Color(.systemGray6))
                        )
                }
            }
        }
    }

    @ViewBuilder
    private func meaningSection(word: WordEntry) -> some View {
        let meaningLines = meaningLines(for: word)

        if meaningLines.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Meaning")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(meaningLines.prefix(Self.meaningLineDisplayLimit).enumerated()), id: \.offset) { idx, line in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(idx + 1).")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.secondary)
                            meaningLine(line)
                        }
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func examplesSection(word: WordEntry) -> some View {
        let examples = parsedExamples(from: word.examples_en)

        if examples.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Examples")
                    .font(.headline)
                VStack(spacing: 10) {
                    ForEach(examples.prefix(Self.exampleLineDisplayLimit)) { example in
                        exampleCard(example)
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    private struct ParsedExample: Identifiable {
        let id: String
        let russian: String
        let english: String
    }

    private func parsedExamples(from raw: String?) -> [ParsedExample] {
        guard let raw else { return [] }
        var seenRu: Set<String> = []
        var seenEn: Set<String> = []
        var out: [ParsedExample] = []
        for line in raw.split(separator: "\n") {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let parsed = splitExampleLine(trimmed) else { continue }
            let ruKey = normalizeExampleRussian(parsed.russian)
            let enKey = normalizeExampleEnglish(parsed.english)
            guard seenRu.insert(ruKey).inserted, seenEn.insert(enKey).inserted else { continue }
            out.append(
                ParsedExample(
                    id: ruKey,
                    russian: parsed.russian,
                    english: parsed.english
                )
            )
        }
        return out
    }

    private func normalizeExampleRussian(_ s: String) -> String {
        var t = s.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .replacingOccurrences(of: "\u{0301}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = t.last, ".!?…".contains(last) {
            t.removeLast()
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizeExampleEnglish(_ s: String) -> String {
        let lowered = s.lowercased()
            .replacingOccurrences(of: "'", with: "'")
            .replacingOccurrences(of: "'", with: "'")
        let noHyphens = lowered
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "–", with: " ")
            .replacingOccurrences(of: "—", with: " ")
        let stripped = noHyphens.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
        return String(String.UnicodeScalarView(stripped))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private func splitExampleLine(_ line: String) -> (russian: String, english: String)? {
        var text = line
        if let tatoebaNote = text.range(of: " (Tatoeba:", options: [.caseInsensitive]) {
            text = String(text[..<tatoebaNote.lowerBound])
        }
        if let tab = text.firstIndex(of: "\t") {
            let russian = String(text[..<tab]).trimmingCharacters(in: .whitespacesAndNewlines)
            let english = String(text[text.index(after: tab)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !russian.isEmpty, !english.isEmpty else { return nil }
            return (russian, english)
        }
        // Use the last separator so internal em dashes in Russian (e.g. «Том — бездомный.»)
        // are not mistaken for the RU/EN boundary.
        for separator in [" — ", " – ", " - "] {
            guard let range = text.range(of: separator, options: .backwards) else { continue }
            let russian = String(text[..<range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let english = String(text[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !russian.isEmpty, !english.isEmpty else { continue }
            return (russian, english)
        }
        return nil
    }

    private func exampleCard(_ example: ParsedExample) -> some View {
        let isSpeaking = pronunciationSpeaker.isSpeaking(text: example.russian)
        let rateScale = Float(settings.pronunciationRateScale)

        return HStack(alignment: .top, spacing: 12) {
            Button {
                pronunciationSpeaker.toggleSpeaking(
                    russianLemma: example.russian,
                    rateScale: rateScale
                )
            } label: {
                Image(systemName: isSpeaking ? "stop.circle.fill" : "play.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .imageScale(.large)
                    .foregroundStyle(.tint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSpeaking ? "Stop example audio" : "Play example in Russian")

            VStack(alignment: .leading, spacing: 4) {
                Text(example.russian)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(example.english)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .disabled(settings.pronunciationRateScale <= 0)
        .opacity(settings.pronunciationRateScale <= 0 ? 0.65 : 1)
    }

    private func meaningLines(for word: WordEntry) -> [String] {
        word.allMeaningLines
    }

    private func meaningLine(_ line: String) -> some View {
        if let linked = linkedRussianLemma(in: line),
           let id = store.findWordID(russianHeadword: linked)
        {
            var attr = AttributedString(line)
            if let range = attr.range(of: linked) {
                attr[range].link = URL(string: "rwd://word/\(id)")
                attr[range].foregroundColor = .init(.link)
            }
            return Text(attr)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }

        return Text(line)
            .font(.body)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func linkedRussianLemma(in definition: String) -> String? {
        // Heuristic for “... of помочь (помо́чь)” definitions.
        // Prefer the lemma after “ of ” (this is the “original word” in the sentence),
        // falling back to the first Cyrillic token inside parentheses.
        if let r = definition.range(of: " of ", options: [.caseInsensitive]) {
            let tail = String(definition[r.upperBound...])
            if let token = firstCyrillicToken(in: tail) { return token }
        }
        if let open = definition.firstIndex(of: "("),
           let close = definition[open...].firstIndex(of: ")"),
           open < close
        {
            let inside = definition[definition.index(after: open)..<close]
            if let token = firstCyrillicToken(in: String(inside)) { return token }
        }
        return nil
    }

    private func firstCyrillicToken(in s: String) -> String? {
        // Pull the first contiguous Cyrillic token; keep ё/Ё and allow stress marks (U+0301).
        let scalars = s.unicodeScalars
        var current: [UnicodeScalar] = []
        func isCyrillicOrStress(_ u: UnicodeScalar) -> Bool {
            if (0x0400...0x04FF).contains(Int(u.value)) { return true }
            if u.value == 0x0301 { return true } // combining acute accent
            return false
        }
        for u in scalars {
            if isCyrillicOrStress(u) {
                current.append(u)
            } else if !current.isEmpty {
                return String(String.UnicodeScalarView(current))
            }
        }
        return current.isEmpty ? nil : String(String.UnicodeScalarView(current))
    }

    private func posDisplay(_ posRaw: String?) -> String? {
        let p = posRaw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let p, !p.isEmpty else { return nil }
        switch p {
        case "noun": return "noun"
        case "verb": return "verb"
        case "adj": return "adjective"
        case "adv": return "adverb"
        case "pron": return "pronoun"
        case "det": return "determiner"
        case "particle": return "particle"
        case "interjection", "intj": return "interjection"
        case "conj": return "conjunction"
        case "prep": return "preposition"
        case "num": return "number"
        default: return p
        }
    }

    private func pronunciationSection(word: WordEntry) -> some View {
        let phonetic = word.phonetic?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let usageNote = word.ai_note_en?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return VStack(alignment: .leading, spacing: 8) {
            Text("Pronunciation")
                .font(.headline)
            if !phonetic.isEmpty {
                Text(phonetic)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !usageNote.isEmpty {
                Text(usageNote)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            listenControlRow(russianLemma: word.russian)
        }
        .padding(.top, 4)
    }

    private func listenControlRow(russianLemma: String) -> some View {
        let isSpeaking = pronunciationSpeaker.isSpeaking
        let summary = pronunciationSpeaker.voiceSummary

        return VStack(alignment: .leading, spacing: 6) {
            Button {
                pronunciationSpeaker.toggleSpeaking(
                    russianLemma: russianLemma,
                    rateScale: Float(settings.pronunciationRateScale)
                )
            } label: {
                Label {
                    Text(isSpeaking ? "Stop" : "Play Russian")
                        .frame(maxWidth: .infinity, alignment: .leading)
                } icon: {
                    Image(systemName: isSpeaking ? "stop.circle.fill" : "play.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .imageScale(.large)
                }
                .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(isSpeaking ? "Stop pronunciation" : "Play Russian pronunciation")
            .accessibilityHint(
                settings.pronunciationRateScale <= 0
                    ? "Pronunciation speed is set to zero in Settings; increase it to hear audio."
                    : (summary.isEmpty ? "Speaks the Russian headword aloud using on-device voices." : summary)
            )
            .accessibilityIdentifier("word-detail-pronunciation-play")
            .disabled(settings.pronunciationRateScale <= 0)

            if !RussianHeadwordSpeaker.hasListedRussianVoice {
                Text(
                    "If you hear the wrong language or silence, download a Russian voice under "
                        + "Settings → Accessibility → Read & Speak (some iOS versions) or Spoken Content, tap Voices → Russian. "
                        + "Or: Settings → Accessibility → VoiceOver → Speech → Voices → Russian."
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func lettersSection(for russian: String) -> some View {
        let letters = CyrillicAlphabet.letters(in: russian)
        return Group {
            if !letters.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Letters")
                        .font(.headline)
                    VStack(spacing: 0) {
                        ForEach(Array(letters.enumerated()), id: \.offset) { idx, letter in
                            HStack(alignment: .top, spacing: 14) {
                                HStack(alignment: .lastTextBaseline, spacing: 4) {
                                    Text(letter.upper)
                                        .font(.system(.title3, design: .serif).weight(.semibold))
                                    Text(letter.lower)
                                        .font(.system(.body, design: .serif))
                                        .foregroundStyle(.secondary)
                                }
                                .frame(width: 56, alignment: .leading)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(letter.nameEn)
                                        .font(.body)
                                    if let note = letter.soundNote {
                                        Text(note)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                            .italic()
                                    } else if let attr = letter.attributedSoundDescription() {
                                        Text(attr)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 12)

                            if idx != letters.count - 1 {
                                Divider()
                                    .padding(.leading, 12)
                            }
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(.systemGray6))
                    )
                }
                .padding(.top, 4)
            }
        }
    }
}
