import SwiftUI

struct WordDetailView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var store: WordStore
    @StateObject private var pronunciationSpeaker = RussianHeadwordSpeaker()

    let wordID: String

    var body: some View {
        let word = store.getWord(id: wordID)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let word {
                    headerSection(word: word)
                    if let meaning = word.meaning_en, !meaning.isEmpty {
                        meaningSection(meaning: meaning)
                    }
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
        }
        .navigationTitle("Word")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: wordID) {
            if store.getWord(id: wordID) != nil {
                store.recordRecentView(id: wordID)
            }
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
            Text(word.english)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private func meaningSection(meaning: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Meaning")
                .font(.headline)
            Text(meaning)
                .font(.body)
        }
        .padding(.top, 4)
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
