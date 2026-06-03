import SwiftUI

struct NumbersView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var store: WordStore

    var body: some View {
        List {
            Section {
                ForEach(RussianNumbersReference.rows, id: \.value) { row in
                    if let word = store.getWord(id: row.wordID) {
                        Button {
                            router.path.append(.wordDetail(id: row.wordID))
                        } label: {
                            HStack(spacing: 16) {
                                Text("\(row.value)")
                                    .font(.title2.weight(.semibold))
                                    .monospacedDigit()
                                    .frame(width: 36, alignment: .leading)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(word.russian)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text(word.englishHeadline)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer(minLength: 0)

                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Color(.systemGray3))
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            } header: {
                Text("Russian number words — 0 to 20")
                    .textCase(nil)
            }
        }
        .navigationTitle("Numbers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                FlashcardQuizToolbarButton(deck: .numbers)
            }
        }
    }
}
