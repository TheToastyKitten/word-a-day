import SwiftUI
import UserNotifications

struct ManageUsedWordsView: View {
    @EnvironmentObject private var store: WordStore
    @EnvironmentObject private var settings: AppSettings
    @State private var entries: [UsedWord] = []
    @State private var pendingIDs: Set<String> = []
    @State private var hasLoaded: Bool = false
    @State private var query: String = ""

    private var filteredEntries: [UsedWord] {
        let q = Self.normalizeForSearch(query)
        guard !q.isEmpty else { return entries }
        return entries.filter { entry in
            Self.normalizeForSearch(entry.word.russian).contains(q) ||
            Self.normalizeForSearch(entry.word.english).contains(q)
        }
    }

    /// Mirrors `WordStore.normalizeForIndex` so search behaviour matches the
    /// main dictionary search: case-insensitive, ё→е equivalent.
    private static func normalizeForSearch(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Group {
            if hasLoaded && entries.isEmpty {
                ContentUnavailableView(
                    "No used words yet",
                    systemImage: "tray",
                    description: Text("Words you've already received as a push will show up here. Tap \u{201C}Add back\u{201D} on any row to put it back in the pool.")
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
        .navigationTitle("Used words")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search used words"
        )
        .autocorrectionDisabled(true)
        .textInputAutocapitalization(.never)
        .task {
            // Promote any pushes that fired since the last top-up before
            // reading the list. Handles the case where the app was already
            // in the foreground when the notification fired (scenePhase
            // never changed, so the scheduler's promoteFiredPushesAndPurge
            // wasn't triggered). No-op if already up to date.
            store.promoteFiredPushesAndPurge()
            entries = store.usedWords(limit: 5_000)
            hasLoaded = true
        }
    }

    private var footerLabel: Text {
        if query.isEmpty {
            return Text("\(entries.count) used word\(entries.count == 1 ? "" : "s")")
        } else {
            return Text("\(filteredEntries.count) of \(entries.count) match\(filteredEntries.count == 1 ? "es" : "")")
        }
    }

    @ViewBuilder
    private func row(for entry: UsedWord) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.word.russian)
                    .font(.headline)
                Text(entry.word.english)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(entry.usedAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            addBackButton(for: entry)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func addBackButton(for entry: UsedWord) -> some View {
        let isPending = pendingIDs.contains(entry.id)
        Button {
            addBack(entry)
        } label: {
            if isPending {
                ProgressView()
                    .controlSize(.small)
                    .frame(minWidth: 64)
            } else {
                Label("Add back", systemImage: "arrow.uturn.backward")
                    .labelStyle(.titleAndIcon)
            }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(isPending)
        .accessibilityLabel("Add \(entry.word.russian) back to push pool")
    }

    private func addBack(_ entry: UsedWord) {
        let id = entry.id
        guard !pendingIDs.contains(id) else { return }
        pendingIDs.insert(id)

        withAnimation { entries.removeAll { $0.id == id } }

        Task {
            defer {
                Task { @MainActor in
                    pendingIDs.remove(id)
                }
            }
            // markWordUnused is synchronous and transactional: it deletes from
            // `used_words` and `scheduled_pushes` in a single BEGIN/COMMIT block,
            // then returns the notification request IDs to cancel.
            // Do NOT call unuseWord here — that method also calls topUpRollingBuffer,
            // which would immediately reserve a random unused word (possibly the one
            // just freed) into scheduled_pushes for the tail slot.
            let cancelledIDs = store.markWordUnused(id: id)
            if !cancelledIDs.isEmpty {
                UNUserNotificationCenter.current()
                    .removePendingNotificationRequests(withIdentifiers: cancelledIDs)
            }
        }
    }
}
