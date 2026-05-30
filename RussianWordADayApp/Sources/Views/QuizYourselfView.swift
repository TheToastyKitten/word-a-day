import SwiftUI

/// One question: prompt word + four shuffled choices (exactly one correct).
private struct SelfQuizQuestion: Identifiable {
    let id: String
    let word: WordEntry
    let choices: [String]
}

@MainActor
struct QuizYourselfView: View {
    @EnvironmentObject private var store: WordStore

    let source: QuizSource
    let direction: QuizDirection

    private enum Phase {
        case loading
        case active
        case results
    }

    @State private var phase: Phase = .loading
    @State private var questions: [SelfQuizQuestion] = []
    /// Selected answer string per question index (display form).
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
                        emptyStateTitle,
                        systemImage: emptyStateSymbol,
                        description: Text(emptyStateDescription)
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
        .navigationTitle(direction.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: quizTaskID) { startQuiz() }
    }

    private var quizTaskID: String {
        switch source {
        case .pushed: return "pushed-\(direction.rawValue)"
        case .favorites: return "favorites-\(direction.rawValue)"
        }
    }

    private var emptyStateTitle: String {
        switch source {
        case .pushed: return "No pushed words yet"
        case .favorites: return "No favourited words yet"
        }
    }

    private var emptyStateSymbol: String {
        switch source {
        case .pushed: return "tray"
        case .favorites: return "star"
        }
    }

    private var emptyStateDescription: String {
        switch source {
        case .pushed:
            return "Words you have already received as push notifications appear here. Come back after you have a few saved."
        case .favorites:
            return "Star words on their detail page to save them here, then quiz yourself on them."
        }
    }

    private var quizForm: some View {
        List {
            ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                Section {
                    promptBlock(for: question.word)
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
                                   answersMatch(picked, choice) {
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
                    promptBlock(for: question.word, compact: true)

                    resultBlock(
                        label: "Your answer",
                        text: selections[index],
                        highlightWrong: !isCorrect(at: index)
                    )
                    resultBlock(
                        label: "Correct answer",
                        text: correctAnswer(for: question),
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

    @ViewBuilder
    private func promptBlock(for word: WordEntry, compact: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(promptText(for: word))
                    .font(compact ? .title3.weight(.bold) : .title2.weight(.bold))
                if let chip = posChip(word.pos) {
                    Text(chip)
                        .font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, compact ? 6 : 8)
                        .padding(.vertical, compact ? 3 : 4)
                        .background(Capsule().fill(Color(uiColor: .secondarySystemFill)))
                }
            }
            if direction == .russianToEnglish {
                pronunciationLine(for: word)
            }
        }
    }

    private func promptText(for word: WordEntry) -> String {
        switch direction {
        case .russianToEnglish:
            return word.russian
        case .englishToRussian:
            return word.englishHeadline
        }
    }

    private func correctAnswer(for question: SelfQuizQuestion) -> String {
        switch direction {
        case .russianToEnglish:
            return question.word.englishHeadline.trimmingCharacters(in: .whitespacesAndNewlines)
        case .englishToRussian:
            return question.word.russian.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let chosen = selections[index]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let truth = correctAnswer(for: questions[index])
        return !chosen.isEmpty && answersMatch(chosen, truth)
    }

    private func answersMatch(_ a: String, _ b: String) -> Bool {
        switch direction {
        case .russianToEnglish:
            return Self.normalizeEnglishKey(a) == Self.normalizeEnglishKey(b)
        case .englishToRussian:
            return Self.normalizeRussianKey(a) == Self.normalizeRussianKey(b)
        }
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
        case "other": return "Other"
        default: return nil
        }
    }

    @ViewBuilder
    private func pronunciationLine(for word: WordEntry) -> some View {
        let phon = word.phonetic?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !phon.isEmpty {
            Text(phon)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func startQuiz() {
        phase = .loading
        selections = [:]
        store.promoteFiredPushesAndPurge()

        let pool: [WordEntry] = switch source {
        case .pushed:
            store.randomUsedWordsForQuiz(limit: 10)
        case .favorites:
            store.randomFavoriteWordsForQuiz(limit: 10)
        }
        guard !pool.isEmpty else {
            questions = []
            phase = .active
            return
        }

        questions = switch direction {
        case .russianToEnglish:
            buildRussianToEnglishQuestions(from: pool)
        case .englishToRussian:
            buildEnglishToRussianQuestions(from: pool)
        }
        phase = .active
    }

    private func buildRussianToEnglishQuestions(from pool: [WordEntry]) -> [SelfQuizQuestion] {
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
            let wrong = collectWrongChoices(
                correctKey: cn,
                correctNorms: correctNorms,
                pool: pool,
                excludingWordID: w.id,
                pickDisplay: { $0.englishHeadline.trimmingCharacters(in: .whitespacesAndNewlines) },
                pickKey: { Self.normalizeEnglishKey($0) },
                distractorSource: &distractorSource,
                sourceIndex: &sourceIndex,
                refill: refillDistractors,
                refillMore: {
                    store.randomEnglishQuizDistractorCandidates(
                        excludingNormalized: $0,
                        maxToScan: 800,
                        maxCollected: 40
                    )
                }
            )

            var choices = wrong.prefix(3).map { $0 } + [correct]
            choices.shuffle()
            built.append(SelfQuizQuestion(id: w.id, word: w, choices: choices))
        }

        return built
    }

    private func buildEnglishToRussianQuestions(from pool: [WordEntry]) -> [SelfQuizQuestion] {
        let correctNorms = Set(pool.map { Self.normalizeRussianKey($0.russian) })
        var distractorSource: [String] = []
        var sourceIndex = 0

        func refillDistractors(extraExclude: Set<String>) {
            let merged = correctNorms.union(extraExclude)
            let batch = store.randomRussianQuizDistractorCandidates(
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
            let correct = w.russian.trimmingCharacters(in: .whitespacesAndNewlines)
            let cn = Self.normalizeRussianKey(correct)
            let wrong = collectWrongChoices(
                correctKey: cn,
                correctNorms: correctNorms,
                pool: pool,
                excludingWordID: w.id,
                pickDisplay: { $0.russian.trimmingCharacters(in: .whitespacesAndNewlines) },
                pickKey: { Self.normalizeRussianKey($0) },
                distractorSource: &distractorSource,
                sourceIndex: &sourceIndex,
                refill: refillDistractors,
                refillMore: {
                    store.randomRussianQuizDistractorCandidates(
                        excludingNormalized: $0,
                        maxToScan: 800,
                        maxCollected: 40
                    )
                }
            )

            var choices = wrong.prefix(3).map { $0 } + [correct]
            choices.shuffle()
            built.append(SelfQuizQuestion(id: w.id, word: w, choices: choices))
        }

        return built
    }

    private func collectWrongChoices(
        correctKey: String,
        correctNorms: Set<String>,
        pool: [WordEntry],
        excludingWordID: String,
        pickDisplay: (WordEntry) -> String,
        pickKey: (String) -> String,
        distractorSource: inout [String],
        sourceIndex: inout Int,
        refill: (Set<String>) -> Void,
        refillMore: (Set<String>) -> [String]
    ) -> [String] {
        var wrong: [String] = []

        while wrong.count < 3 {
            if sourceIndex >= distractorSource.count {
                refill(Set(wrong.map { pickKey($0) }))
            }
            guard sourceIndex < distractorSource.count else { break }
            let cand = distractorSource[sourceIndex]
            sourceIndex += 1
            let n = pickKey(cand)
            if n == correctKey { continue }
            if wrong.contains(where: { pickKey($0) == n }) { continue }
            wrong.append(cand)
        }

        if wrong.count < 3 {
            for other in pool where other.id != excludingWordID {
                let cand = pickDisplay(other)
                guard !cand.isEmpty else { continue }
                let n = pickKey(cand)
                if n == correctKey { continue }
                if wrong.contains(where: { pickKey($0) == n }) { continue }
                wrong.append(cand)
                if wrong.count == 3 { break }
            }
        }

        while wrong.count < 3 {
            let more = refillMore(
                correctNorms
                    .union([correctKey])
                    .union(Set(wrong.map { pickKey($0) }))
            )
            var progressed = false
            for cand in more {
                let n = pickKey(cand)
                if n == correctKey { continue }
                if wrong.contains(where: { pickKey($0) == n }) { continue }
                wrong.append(cand)
                progressed = true
                if wrong.count == 3 { break }
            }
            if !progressed { break }
        }

        return wrong
    }

    private static func normalizeEnglishKey(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeRussianKey(_ s: String) -> String {
        normalizeEnglishKey(s)
    }
}
