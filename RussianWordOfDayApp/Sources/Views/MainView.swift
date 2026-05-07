import SwiftUI

struct MainView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var store: WordStore

    @State private var query: String = ""
    @State private var results: [WordEntry] = []
    @State private var showingRecents: Bool = false
    @State private var showAboutAlert = false
    @State private var enrichmentByID: [String: WordEnrichment] = [:]
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
            .accessibilityLabel("Numbers zero through twenty")

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
    private static let mainSearchResultLimit = 10
    private static let enrichmentPrefetchTopN = 4

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
                // Key off `results` (not `query`) so the prefetch runs after the
                // dropdown contents are refreshed.
                .task(id: results.map(\.id)) {
                    await prefetchEnrichmentForVisibleResults()
                }

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

                                Text(entry.english)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                if let snippet = dropdownSnippet(for: entry) {
                                    Text(snippet)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
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

    /// Short tag for dropdown rows (`Noun` / `Verb` / `Adj` / `Adv`); aligns with POS filter wording.
    private static func dropdownPOSChipLabel(_ pos: String?) -> String? {
        guard let raw = pos?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return nil }
        switch raw {
        case "noun": return "Noun"
        case "verb": return "Verb"
        case "adj", "adjective": return "Adj"
        case "adv", "adverb": return "Adv"
        default: return nil
        }
    }

    private func dropdownSnippet(for entry: WordEntry) -> String? {
        if let enriched = enrichmentByID[entry.id] {
            for def in enriched.definitions {
                let t = def.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { continue }
                if snippetIsPlausibleForEntry(t, entry: entry) {
                    return t
                }
            }
        }
        return meaningSnippet(for: entry)
    }

    private func prefetchEnrichmentForVisibleResults() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Recents dropdown runs with an empty query; still allow enrichment there.
        if !showingRecents, trimmed.count < 2 { return }
        if results.isEmpty { return }

        let ids = Array(results.prefix(Self.enrichmentPrefetchTopN).map(\.id))

        await MainActor.run {
            // Drop enrichment for rows no longer visible.
            enrichmentByID = enrichmentByID.filter { ids.contains($0.key) }
        }

        for id in ids {
            if Task.isCancelled { return }
            if enrichmentByID[id] != nil { continue }

            if let cached = store.getEnrichment(id: id) {
                // If the cached enrichment came from an older provider (e.g. Wiktionary),
                // force a refresh so dropdown snippets stay consistent.
                if cached.source == "yandex_ruen_v4" {
                    await MainActor.run { enrichmentByID[id] = cached }
                    continue
                }
            }

            await store.fetchEnrichmentIfNeeded(id: id)
            if Task.isCancelled { return }

            if let cached = store.getEnrichment(id: id) {
                await MainActor.run { enrichmentByID[id] = cached }
            }
        }
    }

    private func meaningSnippet(for entry: WordEntry) -> String? {
        let headline = entry.english.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if let glosses = entry.glosses_en {
            for line in glosses.split(separator: "\n") {
                let s = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                if s.isEmpty { continue }
                if s.lowercased() == headline { continue }
                if snippetIsPlausibleForEntry(s, entry: entry) {
                    return s
                }
            }
        }
        if let meaning = entry.meaning_en {
            let s = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { return nil }
            if s.lowercased() == headline { return nil }
            if snippetIsPlausibleForEntry(s, entry: entry) {
                return s
            }
        }
        return nil
    }

    /// Drop obvious Kaikki/Yandex homograph garbage (e.g. “belt” on a verb lemma).
    private func snippetIsPlausibleForEntry(_ snippet: String, entry: WordEntry) -> Bool {
        let raw = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return false }

        let pos = entry.pos?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard pos == "verb" else { return true }

        let firstSegment = raw.split(separator: "—", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() } ?? raw.lowercased()

        let beltHomographNoise: Set<String> = [
            "belt", "suspenders", "leading-string", "leading string",
        ]
        if beltHomographNoise.contains(firstSegment) { return false }

        return true
    }
}

private enum POSFilter: CaseIterable, Hashable {
    /// Matches `WordStore` beginner filter (noun / verb / adj / adv only).
    case noun
    case verb
    case adj
    case adv

    var label: String {
        switch self {
        case .noun: return "Noun"
        case .verb: return "Verb"
        case .adj: return "Adj"
        case .adv: return "Adv"
        }
    }

    /// Matches `words.pos` (Kaikki may store `adj`/`adjective`, `adv`/`adverb`).
    var posMatchValues: [String] {
        switch self {
        case .noun: return ["noun"]
        case .verb: return ["verb"]
        case .adj: return ["adj", "adjective"]
        case .adv: return ["adv", "adverb"]
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
