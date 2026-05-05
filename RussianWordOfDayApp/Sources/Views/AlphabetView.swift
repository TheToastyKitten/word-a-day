import SwiftUI

struct AlphabetView: View {
    var body: some View {
        List {
            Section {
                ForEach(CyrillicAlphabet.letters) { letter in
                    LetterRow(letter: letter)
                }
            } header: {
                Text("Russian Alphabet — 33 letters")
                    .textCase(nil)
            } footer: {
                Text("Each row shows the letter's name (how it's pronounced when reciting the alphabet) and a short hint at the sound it makes inside a word.")
                    .font(.footnote)
            }
        }
        .navigationTitle("Alphabet")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LetterRow: View {
    let letter: CyrillicLetter

    var body: some View {
        HStack(spacing: 16) {
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(letter.upper)
                    .font(.system(.title, design: .serif).weight(.semibold))
                Text(letter.lower)
                    .font(.system(.title2, design: .serif))
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 64, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(letter.nameEn)
                    .font(.body)
                    .foregroundStyle(.primary)
                soundLine
                    .font(.footnote)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var soundLine: some View {
        if let note = letter.soundNote {
            Text(note)
                .foregroundStyle(.secondary)
                .italic()
        } else if let sound = letter.similarSoundEn {
            Text(sound)
                .foregroundStyle(.secondary)
        }
    }

    private var accessibilityText: String {
        var parts = ["\(letter.upper) \(letter.lower), pronounced \(letter.nameEn)"]
        if let extra = letter.soundDescription {
            parts.append(extra)
        }
        return parts.joined(separator: ", ")
    }
}
