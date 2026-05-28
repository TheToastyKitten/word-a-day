import SwiftUI

struct NumbersView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var store: WordStore

    /// Stable `words.id` values from the bundled dictionary for Russian numerals 0…20.
    private static let rows: [(value: Int, wordID: String)] = [
        (0, "nol"),
        (1, "odin"),
        (2, "dva"),
        (3, "tri"),
        (4, "chetyre"),
        (5, "pyat"),
        (6, "shest"),
        (7, "sem"),
        (8, "vosem"),
        (9, "devyat"),
        (10, "desyat"),
        (11, "odinnadtsat"),
        (12, "dvenadtsat"),
        (13, "trinadtsat"),
        (14, "chetyrnadtsat"),
        (15, "pyatnadtsat"),
        (16, "shestnadtsat"),
        (17, "semnadtsat"),
        (18, "vosemnadtsat"),
        (19, "devyatnadtsat"),
        (20, "dvadtsat"),
    ]

    var body: some View {
        List {
            Section {
                ForEach(Self.rows, id: \.value) { row in
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
    }
}
