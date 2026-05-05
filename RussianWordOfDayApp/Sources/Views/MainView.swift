import SwiftUI

struct MainView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var store: WordStore

    @State private var query: String = ""
    @State private var results: [WordEntry] = []

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color.white.ignoresSafeArea()

                VStack(spacing: 0) {
                    topBar
                        .padding(.horizontal, 16)
                        .padding(.top, 8)

                    // Push the search section down to roughly the top third.
                    Spacer()
                        .frame(height: max(0, geo.size.height * 0.18))

                    searchSection
                        .padding(.horizontal, 16)

                    Spacer()
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var topBar: some View {
        HStack(spacing: 2) {
            Spacer()

            Button {
                router.openAlphabet()
            } label: {
                Image("alphabet_icon")
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    // The PNG has internal whitespace, so its visible glyph
                    // reads smaller than an SF Symbol at the same frame.
                    // Bump the frame up to compensate.
                    .frame(width: Self.alphabetIconSize, height: Self.alphabetIconSize)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Alphabet")

            Button {
                router.openSettings()
            } label: {
                Image(systemName: "gearshape.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: Self.gearIconSize, height: Self.gearIconSize)
                    .foregroundStyle(.black)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
    }

    /// SF Symbol frame for the gear: edge-to-edge glyph.
    private static let gearIconSize: CGFloat = 26
    /// Alphabet PNG frame: larger than `gearIconSize` so the glyphs (which
    /// sit inside transparent margin in the source image) read at the same
    /// visual size as the gear.
    private static let alphabetIconSize: CGFloat = 38

    private var searchSection: some View {
        VStack(spacing: 8) {
            TextField("Search (Russian or English)", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color(.systemGray6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color(.systemGray4), lineWidth: 1)
                )
                .frame(maxWidth: 460)
                .onChange(of: query) { _, newValue in
                    results = store.search(query: newValue, limit: 15)
                }

            if !results.isEmpty {
                resultsDropdown
            }
        }
    }

    private var resultsDropdown: some View {
        VStack(spacing: 0) {
            ForEach(results) { entry in
                Button {
                    router.path.append(.wordDetail(id: entry.id))
                    query = ""
                    results = []
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.russian)
                                .font(.headline)
                                .foregroundStyle(.black)
                            Text(entry.english)
                                .font(.subheadline)
                                .foregroundStyle(.gray)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color(.systemGray3))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if entry.id != results.last?.id {
                    Divider()
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color(.systemGray4), lineWidth: 1)
                )
        )
        .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 2)
        .frame(maxWidth: 460)
        .frame(maxHeight: 320)
    }
}
