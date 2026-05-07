import SwiftUI

struct WordDetailView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: WordStore
    @StateObject private var pronunciationSpeaker = RussianHeadwordSpeaker()

    /// Maximum numbered lines under **Meaning** (Yandex definitions or offline glosses).
    private static let meaningLineDisplayLimit = 3

    let wordID: String
    @State private var enrichment: WordEnrichment?

    var body: some View {
        let word = store.getWord(id: wordID)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let word {
                    headerSection(word: word)
                    meaningSection(word: word)
                    examplesSection()
                    usageNoteSection(word: word)
                    if let phon = word.phonetic, !phon.isEmpty {
                        pronunciationSection(phon: phon, russianLemma: word.russian)
                    } else {
                        pronunciationListenOnlySection(russianLemma: word.russian)
                    }
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
        .task(id: wordID) {
            if store.getWord(id: wordID) != nil {
                store.recordRecentView(id: wordID)
            }
            enrichment = store.getEnrichment(id: wordID)
            await store.fetchEnrichmentIfNeeded(id: wordID)
            enrichment = store.getEnrichment(id: wordID)
        }
        .onChange(of: wordID) { _, _ in
            pronunciationSpeaker.stopImmediately()
        }
        .onDisappear {
            pronunciationSpeaker.stopImmediately()
        }
    }

    private func headerSection(word: WordEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(word.russian)
                .font(.system(size: 44, weight: .bold, design: .serif))
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(word.english)
                    .font(.title3)
                    .foregroundStyle(.secondary)
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

    private func meaningSection(word: WordEntry) -> some View {
        let headline = word.english.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let enriched = enrichment?.definitions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { $0.lowercased() != headline } ?? []

        let glossLines: [String] = word.glosses_en?
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { $0.lowercased() != headline } ?? []

        return VStack(alignment: .leading, spacing: 8) {
            Text("Meaning")
                .font(.headline)

            if !enriched.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(enriched.prefix(Self.meaningLineDisplayLimit).enumerated()), id: \.offset) { idx, line in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(idx + 1).")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.secondary)
                            meaningLine(line)
                        }
                    }
                }
            } else if !glossLines.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(glossLines.prefix(Self.meaningLineDisplayLimit).enumerated()), id: \.offset) { idx, line in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(idx + 1).")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.secondary)
                            meaningLine(line)
                        }
                    }
                }
            } else if let meaning = word.meaning_en, !meaning.isEmpty {
                let trimmed = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, trimmed.lowercased() != headline {
                    meaningLine(trimmed)
                }
                // else: meaning duplicates headline; omit to avoid repetition
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private func examplesSection() -> some View {
        let ex = enrichment?.examples
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        if !ex.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Examples")
                    .font(.headline)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(ex.prefix(6).enumerated()), id: \.offset) { idx, line in
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
        case "conj": return "conjunction"
        case "prep": return "preposition"
        case "num": return "number"
        default: return p
        }
    }

    private func usageNoteSection(word: WordEntry) -> some View {
        let note = word.ai_note_en?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Group {
            if !note.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Usage note")
                        .font(.headline)
                    Text(note)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            }
        }
    }

    private func pronunciationSection(phon: String, russianLemma: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pronunciation")
                .font(.headline)
            Text(phon)
                .font(.body)
                .foregroundStyle(.secondary)
            listenControlRow(russianLemma: russianLemma)
        }
    }

    /// Shown when there is no phonetic string so users can still hear the headword.
    private func pronunciationListenOnlySection(russianLemma: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pronunciation")
                .font(.headline)
            listenControlRow(russianLemma: russianLemma)
        }
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
