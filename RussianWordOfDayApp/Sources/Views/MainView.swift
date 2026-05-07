import SwiftUI

struct MainView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var store: WordStore

    @State private var query: String = ""
    @State private var results: [WordEntry] = []
    @State private var showingRecents: Bool = false
    @State private var showAboutAlert = false

    @FocusState private var searchFieldFocused: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color(uiColor: .systemBackground)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { searchFieldFocused = false }

                VStack(spacing: 0) {
                    topBar
                        .padding(.horizontal, 16)
                        .padding(.top, 8)

                    Spacer()
                        .frame(height: max(0, geo.size.height * 0.18))

                    searchSection
                        .padding(.horizontal, 16)

                    Spacer()
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { searchFieldFocused = false }
            }
        }
        .alert("About this app", isPresented: $showAboutAlert) {
            Button("Whatever 🙄", role: .cancel) {}
        } message: {
            Text(
                "You can enable multiple \"daily word\" push notifications via the settings menu. "
                    + "The app also acts as a Russian-English dictionary."
            )
        }
    }

    private var topBar: some View {
        HStack(spacing: 2) {
            Button {
                showAboutAlert = true
            } label: {
                Image(systemName: "info.circle")
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: Self.infoIconSize, weight: .regular))
                    .foregroundStyle(.primary)
                    .frame(width: Self.infoIconFrame, height: Self.infoIconFrame)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("About this app")

            Spacer()

            Button {
                router.openNumbers()
            } label: {
                NumbersNavIcon()
                    .frame(width: Self.alphabetIconSize, height: Self.alphabetIconSize)
                    .foregroundStyle(.primary)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Numbers zero through ten")

            Button {
                router.openAlphabet()
            } label: {
                Image("alphabet_icon")
                    .resizable()
                    // Template rendering tints the glyph via `foregroundStyle`,
                    // which resolves to black in light mode and white in dark
                    // mode — matching the gear icon next to it.
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: Self.alphabetIconSize, height: Self.alphabetIconSize)
                    .foregroundStyle(.primary)
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
                    .foregroundStyle(.primary)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
        }
    }

    private static let gearIconSize: CGFloat = 26
    private static let alphabetIconSize: CGFloat = 38
    private static let infoIconSize: CGFloat = 22
    private static let infoIconFrame: CGFloat = 26
    private static let mainSearchResultLimit = 5

    /// Light: standard light-gray search-bar fill (matches iOS search style).
    /// Dark: a clearly-visible gray against the black `.systemBackground`,
    /// not the near-black `systemGray6`/`systemGray5` defaults.
    private var searchFieldFill: Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? .systemGray2 : .systemGray6
        })
    }

    private var searchSection: some View {
        VStack(spacing: 8) {
            TextField("Search (Russian or English)", text: $query)
                .focused($searchFieldFocused)
                .submitLabel(.search)
                .onSubmit { searchFieldFocused = false }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(searchFieldFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color(.systemGray4), lineWidth: 1)
                )
                // Without this, taps on the pill area can race the
                // background's tap-to-dismiss gesture (especially when the
                // recents dropdown is showing) and lose focus before the
                // keyboard opens. Forcing focus on tap of the entire pill
                // means the field always wins the hit test.
                .contentShape(Rectangle())
                .onTapGesture { searchFieldFocused = true }
                .frame(maxWidth: 460)
                .onChange(of: query)              { _, _ in refreshDropdown() }
                .onChange(of: searchFieldFocused) { _, _ in refreshDropdown() }
                .onAppear { refreshDropdown() }

            if !results.isEmpty {
                resultsDropdown
            }
        }
    }

    private func refreshDropdown() {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            if searchFieldFocused {
                results = store.recentViews(limit: 5)
                showingRecents = !results.isEmpty
            } else {
                results = []
                showingRecents = false
            }
        } else {
            results = store.search(query: trimmed, limit: Self.mainSearchResultLimit)
            showingRecents = false
        }
    }

    private var resultsDropdown: some View {
        VStack(spacing: 0) {
            if showingRecents {
                HStack {
                    Text("Recently viewed")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 4)
                Divider()
            }

            ForEach(results) { entry in
                Button {
                    router.path.append(.wordDetail(id: entry.id))
                    query = ""
                    results = []
                    showingRecents = false
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.russian)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(entry.english)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
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
                .fill(Color(uiColor: .systemBackground))
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

// MARK: - Numbers navigation icon

/// Pyramid of rounded blocks (1 on top, 2 and 3 below), matching the user's
/// reference artwork. Drawn with strokes + text so `foregroundStyle(.primary)`
/// tracks light (black) and dark (white) automatically — no raster asset.
private struct NumbersNavIcon: View {
    private static let boxSide: CGFloat = 16
    private static let gap: CGFloat = 2
    private static let cornerRadius: CGFloat = 3

    var body: some View {
        VStack(spacing: Self.gap) {
            digitBlock("1")
            HStack(spacing: Self.gap) {
                digitBlock("2")
                digitBlock("3")
            }
        }
    }

    private func digitBlock(_ digit: String) -> some View {
        Text(digit)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .minimumScaleFactor(0.8)
            .frame(width: Self.boxSide, height: Self.boxSide)
            .contentShape(Rectangle())
            .overlay {
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .strokeBorder(lineWidth: 1.35)
            }
    }
}
