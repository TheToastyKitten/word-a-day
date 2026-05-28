import SwiftUI

/// One question: Russian headword + four shuffled English choices (exactly one matches the headline gloss).
private struct SelfQuizQuestion: Identifiable {
    let id: String
    let word: WordEntry
    let choices: [String]

    var correctEnglish: String {
        word.englishHeadline.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
struct QuizYourselfView: View {
    @EnvironmentObject private var store: WordStore

    private enum Phase {
        case loading
        case active
        case results
    }

    @State private var phase: Phase = .loading
    @State private var questions: [SelfQuizQuestion] = []
    /// Selected English string per question index (display form).
    @State private var selections: [Int: String] = [:]

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView("Loading quiz…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .active:
                if questions.isEmpty {
                    ContentUnavailableView(
                        "No used words yet",
                        systemImage: "tray",
                        description: Text(
                            "Words you have already received as notifications appear here. Come back after you have a few saved."
                        )
                    )
                } else {
                    quizForm
                }
            case .results:
                if questions.isEmpty {
                    ContentUnavailableView("No quiz", systemImage: "questionmark")
                } else {
                    resultsView
                }
            }
        }
        .navigationTitle("Quiz Yourself")
        .navigationBarTitleDisplayMode(.inline)
        .task { startQuiz() }
    }

    private var quizForm: some View {
        List {
            ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(question.word.russian)
                                .font(.title2.weight(.bold))
                            if let chip = posChip(question.word.pos) {
                                Text(chip)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(Color(uiColor: .secondarySystemFill)))
                            }
                        }
                        pronunciationLine(for: question.word)
                    }
                    .listRowSeparator(.hidden, edges: .top)

                    ForEach(question.choices.indices, id: \.self) { choiceIndex in
                        let choice = question.choices[choiceIndex]
                        Button {
                            selections[index] = choice
                        } label: {
                            HStack(alignment: .center) {
                                Text(choice)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                Spacer()
                                if let picked = selections[index],
                                   Self.normalizeEnglishKey(picked) == Self.normalizeEnglishKey(choice) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Question \(index + 1) of \(questions.count)")
                }
            }

            Section {
                Button {
                    phase = .results
                } label: {
                    Text("See results")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!allQuestionsAnswered)
            }
        }
    }

    private var resultsView: some View {
        List {
            Section {
                let correctCount = questions.indices.filter { isCorrect(at: $0) }.count
                Text("You got \(correctCount) of \(questions.count) correct.")
                    .font(.headline)
                Button("Try again") {
                    startQuiz()
                }
                .buttonStyle(.borderedProminent)
            }

            ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(question.word.russian)
                                .font(.title3.weight(.bold))
                            if let chip = posChip(question.word.pos) {
                                Text(chip)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(Color(uiColor: .secondarySystemFill)))
                            }
                        }
                        pronunciationLine(for: question.word)
                    }

                    resultBlock(
                        label: "Your answer",
                        text: selections[index],
                        highlightWrong: !isCorrect(at: index)
                    )
                    resultBlock(
                        label: "Correct answer",
                        text: question.correctEnglish,
                        highlightWrong: false
                    )
                } header: {
                    HStack {
                        Text("Question \(index + 1)")
                        Spacer()
                        Image(systemName: isCorrect(at: index) ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(isCorrect(at: index) ? .green : .red)
                    }
                }
            }
        }
    }

    private func resultBlock(label: String, text: String?, highlightWrong: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            let bodyText = text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? text! : "—"
            Text(bodyText)
                .font(.body)
                .foregroundStyle(highlightWrong ? Color.red : .primary)
        }
        .padding(.vertical, 2)
    }

    private var allQuestionsAnswered: Bool {
        guard !questions.isEmpty else { return false }
        for i in questions.indices {
            let s = selections[i]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if s.isEmpty { return false }
        }
        return true
    }

    private func isCorrect(at index: Int) -> Bool {
        guard index < questions.count else { return false }
        let chosen = selections[index].map { Self.normalizeEnglishKey($0) } ?? ""
        let truth = Self.normalizeEnglishKey(questions[index].correctEnglish)
        return !chosen.isEmpty && chosen == truth
    }

    private func posChip(_ pos: String?) -> String? {
        guard let raw = pos?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return nil }
        switch raw {
        case "noun": return "Noun"
        case "verb": return "Verb"
        case "adj", "adjective": return "Adj"
        case "adv", "adverb": return "Adv"
        case "pron", "pronoun": return "Pron"
        case "prep", "preposition": return "Prep"
        case "conj", "conjunction": return "Conj"
        case "particle": return "Part."
        case "interjection", "intj": return "Intj"
        default: return nil
        }
    }

    @ViewBuilder
    private func pronunciationLine(for word: WordEntry) -> some View {
        // Word detail shows IPA/translit in `phonetic` and the friendly syllable
        // guide (e.g. "SLOO-zhbah") in **Usage note** (`ai_note_en`). Quiz users
        // expect the same gray line they associate with “how to say it”.
        let phon = word.phonetic?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let note = word.ai_note_en?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let noteDistinct = !note.isEmpty
            && note.caseInsensitiveCompare(phon) != .orderedSame

        if !phon.isEmpty {
            Text(phon)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        if noteDistinct {
            Text(note)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func startQuiz() {
        phase = .loading
        selections = [:]
        store.promoteFiredPushesAndPurge()

        let pool = store.randomUsedWordsForQuiz(limit: 10)
        guard !pool.isEmpty else {
            questions = []
            phase = .active
            return
        }

        let correctNorms = Set(pool.map { Self.normalizeEnglishKey($0.englishHeadline) })
        var distractorSource: [String] = []
        var sourceIndex = 0

        func refillDistractors(extraExclude: Set<String>) {
            let merged = correctNorms.union(extraExclude)
            let batch = store.randomEnglishQuizDistractorCandidates(
                excludingNormalized: merged,
                maxToScan: 600,
                maxCollected: 100
            )
            distractorSource.append(contentsOf: batch)
        }

        refillDistractors(extraExclude: [])

        var built: [SelfQuizQuestion] = []
        built.reserveCapacity(pool.count)

        for w in pool {
            let correct = w.englishHeadline.trimmingCharacters(in: .whitespacesAndNewlines)
            let cn = Self.normalizeEnglishKey(correct)
            var wrong: [String] = []

            while wrong.count < 3 {
                if sourceIndex >= distractorSource.count {
                    refillDistractors(extraExclude: Set(wrong.map { Self.normalizeEnglishKey($0) }))
                }
                guard sourceIndex < distractorSource.count else { break }
                let cand = distractorSource[sourceIndex]
                sourceIndex += 1
                let n = Self.normalizeEnglishKey(cand)
                if n == cn { continue }
                if wrong.contains(where: { Self.normalizeEnglishKey($0) == n }) { continue }
                wrong.append(cand)
            }

            if wrong.count < 3 {
                for other in pool where other.id != w.id {
                    let cand = other.englishHeadline.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !cand.isEmpty else { continue }
                    let n = Self.normalizeEnglishKey(cand)
                    if n == cn { continue }
                    if wrong.contains(where: { Self.normalizeEnglishKey($0) == n }) { continue }
                    wrong.append(cand)
                    if wrong.count == 3 { break }
                }
            }

            while wrong.count < 3 {
                let more = store.randomEnglishQuizDistractorCandidates(
                    excludingNormalized: correctNorms
                        .union([cn])
                        .union(Set(wrong.map { Self.normalizeEnglishKey($0) })),
                    maxToScan: 800,
                    maxCollected: 40
                )
                var progressed = false
                for cand in more {
                    let n = Self.normalizeEnglishKey(cand)
                    if n == cn { continue }
                    if wrong.contains(where: { Self.normalizeEnglishKey($0) == n }) { continue }
                    wrong.append(cand)
                    progressed = true
                    if wrong.count == 3 { break }
                }
                if !progressed { break }
            }

            var choices = wrong.prefix(3).map { $0 } + [correct]
            choices.shuffle()
            built.append(SelfQuizQuestion(id: w.id, word: w, choices: choices))
        }

        questions = built
        phase = .active
    }

    private static func normalizeEnglishKey(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
