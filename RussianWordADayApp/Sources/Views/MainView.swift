import SwiftUI

struct MainView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var store: WordStore

    @State private var query: String = ""
    @State private var results: [WordEntry] = []
    @State private var showingRecents: Bool = false
    @State private var showAboutAlert = false
    @State private var selectedPOS: Set<POSFilter> = []

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

                if !store.isReady {
                    Color(uiColor: .systemBackground)
                        .ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Loading dictionary…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: router.path) { _, _ in
            refreshDropdown()
        }
        .alert("About this app", isPresented: $showAboutAlert) {
            Button("Whatever 🙄", role: .cancel) {}
        } message: {
            Text(
                "This app is a Russian–English dictionary. You can turn on multiple "
                    + "\"daily word\" push notifications and quiz yourself on words you've "
                    + "already received — all from Settings."
            )
        }
    }

    // MARK: - Top bar icons (offsets + layout)

    /// Per-icon nudge in points. Edit x/y here; all five definitions are in `topBar` below.
    private enum TopBarIconOffset {
        static let infoX: CGFloat = 0
        static let infoY: CGFloat = 2
        static let favouritesX: CGFloat = -2
        static let favouritesY: CGFloat = 0
        static let numbersX: CGFloat = 0
        static let numbersY: CGFloat = 0
        static let alphabetX: CGFloat = 4
        static let alphabetY: CGFloat = 0
        static let settingsX: CGFloat = 0
        static let settingsY: CGFloat = 0
    }

    private static let topBarIconBox: CGFloat = 38
    private static let topBarSymbolSize: CGFloat = 22
    private static let topBarIconSpacing: CGFloat = 2

    private var topBar: some View {
        HStack(alignment: .center, spacing: Self.topBarIconSpacing) {
            // —— 1. Info ——
            topBarIconButton(accessibilityLabel: "About this app", action: { showAboutAlert = true }) {
                Image(systemName: "info.circle")
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: Self.topBarSymbolSize, weight: .regular))
                    .offset(x: TopBarIconOffset.infoX, y: TopBarIconOffset.infoY)
            }

            // —— 2. Favourites ——
            topBarIconButton(accessibilityLabel: "Favourites", action: { router.openFavorites() }) {
                Image(systemName: "star.fill")
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: Self.topBarSymbolSize, weight: .regular))
                    .offset(x: TopBarIconOffset.favouritesX, y: TopBarIconOffset.favouritesY)
            }

            Spacer()

            // —— 3. Numbers ——
            topBarIconButton(accessibilityLabel: "Numbers zero through twenty", action: { router.openNumbers() }) {
                NumbersNavIcon()
                    .offset(x: TopBarIconOffset.numbersX, y: TopBarIconOffset.numbersY)
            }

            // —— 4. Alphabet ——
            topBarIconButton(accessibilityLabel: "Alphabet", action: { router.openAlphabet() }) {
                Image("alphabet_icon")
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .frame(width: Self.topBarIconBox, height: Self.topBarIconBox)
                    .offset(x: TopBarIconOffset.alphabetX, y: TopBarIconOffset.alphabetY)
            }

            // —— 5. Settings ——
            topBarIconButton(accessibilityLabel: "Settings", action: { router.openSettings() }) {
                Image(systemName: "gearshape.fill")
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: Self.topBarSymbolSize, weight: .regular))
                    .offset(x: TopBarIconOffset.settingsX, y: TopBarIconOffset.settingsY)
            }
        }
        .frame(height: Self.topBarIconBox)
    }

    private func topBarIconButton<Label: View>(
        accessibilityLabel: String,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            label()
                .foregroundStyle(.primary)
                .frame(width: Self.topBarIconBox, height: Self.topBarIconBox)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
    private static let mainSearchResultLimit = 10

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
            posFilterChips

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
        let posFilters = Array(Set(selectedPOS.flatMap(\.posMatchValues))).sorted()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            if searchFieldFocused {
                results = store.recentViews(limit: Self.mainSearchResultLimit, posFilters: posFilters)
                showingRecents = !results.isEmpty
            } else {
                // Preserve the last-shown dropdown state when navigating away
                // (e.g. opening a word from recents) so Back restores it.
                if !showingRecents {
                    results = []
                }
            }
        } else {
            results = store.search(query: trimmed, limit: Self.mainSearchResultLimit, posFilters: posFilters)
            showingRecents = false
        }
    }

    private var posFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(POSFilter.allCases, id: \.self) { filter in
                    posChip(filter)
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(maxWidth: 460)
        .frame(height: 34)
    }

    private func posChip(_ filter: POSFilter) -> some View {
        let selected = selectedPOS.contains(filter)
        return Button {
            if selected {
                selectedPOS.remove(filter)
            } else {
                selectedPOS.insert(filter)
            }
            refreshDropdown()
        } label: {
            Text(filter.label)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background {
                    Capsule(style: .continuous)
                        .fill(selected ? Color.accentColor.opacity(0.18) : Color(uiColor: .secondarySystemFill))
                }
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(selected ? Color.accentColor.opacity(0.42) : Color.clear, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(selected ? "\(filter.label), selected" : "\(filter.label), not selected")
    }

    private var resultsDropdown: some View {
        ScrollView {
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
                        searchFieldFocused = false
                        router.path.append(.wordDetail(id: entry.id))
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                dropdownLemmaHeadline(entry: entry)

                                Text(entry.englishHeadline)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
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

                Color.clear.frame(height: 72)
                    .allowsHitTesting(false)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollIndicators(.hidden)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(uiColor: .systemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color(.systemGray4), lineWidth: 1)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Color.black.opacity(0.04), radius: 6, x: 0, y: 2)
        .frame(maxWidth: 460)
        .frame(maxHeight: 320)
    }

    /// Russian lemma + POS chip (styled like unselected POS filter pills).
    @ViewBuilder
    private func dropdownLemmaHeadline(entry: WordEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.russian)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let posLabel = Self.dropdownPOSChipLabel(entry.pos) {
                Text(posLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background {
                        Capsule(style: .continuous)
                            .fill(Color(uiColor: .secondarySystemFill))
                    }
                    .fixedSize()
            }
            Spacer(minLength: 0)
        }
    }

    /// Short tag for dropdown rows; aligns with POS filter chip wording.
    private static func dropdownPOSChipLabel(_ pos: String?) -> String? {
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

}

private enum POSFilter: CaseIterable, Hashable {
    case noun
    case verb
    case adj
    case adv
    case pron
    case prep
    case conj
    case particle
    case interjection

    var label: String {
        switch self {
        case .noun: return "Noun"
        case .verb: return "Verb"
        case .adj: return "Adj"
        case .adv: return "Adv"
        case .pron: return "Pron"
        case .prep: return "Prep"
        case .conj: return "Conj"
        case .particle: return "Part."
        case .interjection: return "Intj"
        }
    }

    /// Matches `words.pos` (Kaikki may use short or long POS tags).
    var posMatchValues: [String] {
        switch self {
        case .noun: return ["noun"]
        case .verb: return ["verb"]
        case .adj: return ["adj", "adjective"]
        case .adv: return ["adv", "adverb"]
        case .pron: return ["pron", "pronoun"]
        case .prep: return ["prep", "preposition"]
        case .conj: return ["conj", "conjunction"]
        case .particle: return ["particle"]
        case .interjection: return ["interjection", "intj"]
        }
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
