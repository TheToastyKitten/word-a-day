import SwiftUI

extension FlashcardDeck {
    var title: String {
        switch self {
        case .alphabet: return "Alphabet"
        case .numbers: return "Numbers"
        }
    }
}

private struct FlashcardItem: Identifiable, Hashable {
    let id: String
    let prompt: String
    let promptDetail: String?
    let answer: String
    let answerDetail: String?
}

@MainActor
struct FlashcardQuizView: View {
    @EnvironmentObject private var store: WordStore

    let deck: FlashcardDeck
    let direction: QuizDirection

    @State private var cards: [FlashcardItem] = []
    @State private var index = 0
    @State private var isFlipped = false
    @State private var finished = false

    var body: some View {
        Group {
            if cards.isEmpty {
                ContentUnavailableView(
                    "Nothing to practice",
                    systemImage: "rectangle.on.rectangle.angled",
                    description: Text(emptyDescription)
                )
            } else if finished {
                completionView
            } else {
                activeDeckView
            }
        }
        .navigationTitle("Flashcards")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { loadDeck() }
    }

    private var emptyDescription: String {
        switch deck {
        case .alphabet:
            return "Alphabet cards could not be loaded."
        case .numbers:
            return "Number words are still loading. Try again in a moment."
        }
    }

    private var activeDeckView: some View {
        VStack(spacing: 20) {
            Text("\(index + 1) of \(cards.count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)

            flashcard
                .padding(.horizontal, 16)

            controls
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var flashcard: some View {
        let card = cards[index]
        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                isFlipped.toggle()
            }
        } label: {
            ZStack {
                cardFace(
                    main: isFlipped ? card.answer : card.prompt,
                    detail: isFlipped ? card.answerDetail : card.promptDetail
                )
                .rotation3DEffect(.degrees(isFlipped ? 180 : 0), axis: (x: 0, y: 1, z: 0))
                .opacity(isFlipped ? 0 : 1)

                cardFace(
                    main: card.answer,
                    detail: card.answerDetail
                )
                .rotation3DEffect(.degrees(isFlipped ? 0 : -180), axis: (x: 0, y: 1, z: 0))
                .opacity(isFlipped ? 1 : 0)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 280)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFlipped ? "Answer side" : "Prompt side")
        .accessibilityHint("Double tap to flip the card")
        .accessibilityAddTraits(.isButton)
    }

    private func cardFace(main: String, detail: String?) -> some View {
        VStack(spacing: 14) {
            Text(main)
                .font(.system(size: faceMainFontSize, design: deck == .alphabet ? .serif : .default).weight(.bold))
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.5)
                .lineLimit(3)

            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Text("Tap to flip")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }

    private var faceMainFontSize: CGFloat {
        switch deck {
        case .alphabet:
            return 72
        case .numbers:
            return direction == .englishToRussian ? 64 : 48
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button("Previous") { goPrevious() }
                .buttonStyle(.bordered)
                .disabled(index == 0)

            Button(index + 1 >= cards.count ? "Finish" : "Next") {
                goNext()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var completionView: some View {
        ContentUnavailableView {
            Label("Nice work!", systemImage: "checkmark.circle.fill")
        } description: {
            Text("You went through all \(cards.count) \(deck.title.lowercased()) cards.")
        } actions: {
            Button("Practice again") {
                loadDeck()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func goPrevious() {
        guard index > 0 else { return }
        index -= 1
        isFlipped = false
    }

    private func goNext() {
        if index + 1 >= cards.count {
            finished = true
            isFlipped = false
            return
        }
        index += 1
        isFlipped = false
    }

    private func loadDeck() {
        cards = buildCards().shuffled()
        index = 0
        isFlipped = false
        finished = false
    }

    private func buildCards() -> [FlashcardItem] {
        switch deck {
        case .alphabet:
            return CyrillicAlphabet.letters.map { letter in
                FlashcardItem(
                    id: letter.id,
                    prompt: "\(letter.upper)  \(letter.lower)",
                    promptDetail: nil,
                    answer: letter.nameEn,
                    answerDetail: letter.soundDescription
                )
            }
        case .numbers:
            return RussianNumbersReference.rows.compactMap { row in
                guard let word = store.getWord(id: row.wordID) else { return nil }
                let english = word.englishHeadline.trimmingCharacters(in: .whitespacesAndNewlines)
                switch direction {
                case .russianToEnglish:
                    return FlashcardItem(
                        id: row.wordID,
                        prompt: word.russian,
                        promptDetail: nil,
                        answer: "\(row.value)",
                        answerDetail: english.isEmpty ? nil : english
                    )
                case .englishToRussian:
                    return FlashcardItem(
                        id: row.wordID,
                        prompt: "\(row.value)",
                        promptDetail: english.isEmpty ? nil : english,
                        answer: word.russian,
                        answerDetail: nil
                    )
                }
            }
        }
    }
}

/// Top-trailing flashcard quiz entry (direction picker + navigation).
struct FlashcardQuizToolbarButton: View {
    @EnvironmentObject private var router: AppRouter

    let deck: FlashcardDeck

    @State private var showDirectionPicker = false

    var body: some View {
        Button {
            switch deck {
            case .alphabet:
                router.path.append(.flashcardQuiz(deck: deck, direction: .russianToEnglish))
            case .numbers:
                showDirectionPicker = true
            }
        } label: {
            Image(systemName: "rectangle.on.rectangle.angled")
        }
        .accessibilityLabel("Flashcard quiz")
        .accessibilityHint(flashcardAccessibilityHint)
        .alert("Choose flashcard direction", isPresented: $showDirectionPicker) {
            Button(QuizDirection.russianToEnglish.title) {
                router.path.append(.flashcardQuiz(deck: deck, direction: .russianToEnglish))
            }
            Button(QuizDirection.englishToRussian.title) {
                router.path.append(.flashcardQuiz(deck: deck, direction: .englishToRussian))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Russian word first, or digit first?")
        }
    }

    private var flashcardAccessibilityHint: String {
        switch deck {
        case .alphabet:
            return "Practice letters with Russian-to-English flashcards"
        case .numbers:
            return "Practice numbers with flip cards"
        }
    }
}
