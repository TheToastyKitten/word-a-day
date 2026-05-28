import SwiftUI

struct FavoritesView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var store: WordStore
    /// Snapshot loaded when this screen is opened; rows stay until the user leaves.
    @State private var entries: [FavoriteWord] = []
    /// Live favourite state while on this screen (star fill); persisted via `WordStore`.
    @State private var starredIDs: Set<String> = []
    @State private var hasLoaded = false
    @State private var query = ""

    private var filteredEntries: [FavoriteWord] {
        let q = Self.normalizeForSearch(query)
        guard !q.isEmpty else { return entries }
        return entries.filter { entry in
            Self.normalizeForSearch(entry.word.russian).contains(q) ||
                Self.normalizeForSearch(entry.word.english).contains(q)
        }
    }

    private static func normalizeForSearch(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Group {
            if hasLoaded && entries.isEmpty {
                ContentUnavailableView(
                    "No favourites yet",
                    systemImage: "star",
                    description: Text("Open a word and tap the star on its detail page to save it here.")
                )
            } else if hasLoaded && filteredEntries.isEmpty && !query.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List {
                    Section {
                        ForEach(filteredEntries) { entry in
                            row(for: entry)
                        }
                    } footer: {
                        if !entries.isEmpty {
                            footerLabel
                        }
                    }
                }
            }
        }
        .navigationTitle("Favourites")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search favourites"
        )
        .autocorrectionDisabled(true)
        .textInputAutocapitalization(.never)
        .onAppear { reload() }
        .onChange(of: store.isReady) { _, ready in
            if ready { reload() }
        }
    }

    private var footerLabel: Text {
        if query.isEmpty {
            return Text("\(entries.count) favourited word\(entries.count == 1 ? "" : "s")")
        } else {
            return Text("\(filteredEntries.count) of \(entries.count) match\(filteredEntries.count == 1 ? "es" : "")")
        }
    }

    @ViewBuilder
    private func row(for entry: FavoriteWord) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.word.russian)
                    .font(.headline)
                Text(entry.word.englishHeadline)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                router.path.append(.wordDetail(id: entry.id))
            }

            Button {
                toggleStar(for: entry)
            } label: {
                Image(systemName: starredIDs.contains(entry.id) ? "star.fill" : "star")
                    .symbolRenderingMode(.monochrome)
                    .font(.body.weight(.regular))
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                starredIDs.contains(entry.id)
                    ? "Remove \(entry.word.russian) from favourites"
                    : "Add \(entry.word.russian) to favourites"
            )
        }
        .padding(.vertical, 2)
    }

    private func toggleStar(for entry: FavoriteWord) {
        let nowStarred = store.toggleFavorite(id: entry.id)
        if nowStarred {
            starredIDs.insert(entry.id)
        } else {
            starredIDs.remove(entry.id)
        }
    }

    private func reload() {
        entries = store.favoriteWords(limit: 5_000)
        starredIDs = Set(entries.map(\.id))
        hasLoaded = true
    }
}
