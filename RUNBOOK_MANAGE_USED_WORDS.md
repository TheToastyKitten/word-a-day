## Runbook + copy/paste prompt for Claude (Manage already used words screen)

You are an expert iOS engineer. Implement the following changes on top of the
existing SwiftUI app at:
`/Users/zackerymiller/Projects/Russian - Word a Day`

This is a small, self-contained iteration that builds the user-facing
counterpart to the persistence layer that earlier runbooks
(`HANDOFF_PROMPT_CLAUDE_ITERATION_ALPHABET_PDF_USED_WORDS.md`,
`HANDOFF_PROMPT_CLAUDE_POST_UI_ALPHABET_ITERATION.md`) already wired up.
Do **not** introduce new dependencies, new SQLite tables, or new SQL.

### Scope (only this item)
Add a **Manage already used words** screen reachable from Settings, where
each row in `used_words` is listed and can be added back to the push pool
with a single tap.

---

## Background you can rely on

The persistence layer is already complete. Specifically:

- `WordStore.usedWords(limit:offset:) -> [UsedWord]` returns rows joined
  with display fields, newest used first.
- `WordStore.usedWordCount() -> Int` for guard / empty-state checks.
- `WordStore.markWordUnused(id:) -> [String]` removes the row from
  `used_words` and any matching `scheduled_pushes`, returning the
  notification request identifiers the caller must cancel via
  `UNUserNotificationCenter`.
- `WordOfDayScheduler.unuseWord(id:settings:store:)` is the canonical
  end-to-end "add back to pool" operation: it calls
  `markWordUnused`, cancels the matching iOS pending requests, then
  tops up the rolling buffer so the freed slot is back-filled at the
  tail. **Use this method — do not re-implement its pieces.**
- `UsedWord` is `struct UsedWord { let word: WordEntry; let usedAt: Date }`
  in `Models.swift`, with `id` mirroring `word.id`.

The "manual mark-as-used" toggle and the `WordStore.markWordUsed` API
were intentionally removed in the prior iteration; do not reintroduce
them.

---

## File touchpoints (1 new file + 4 small edits)

| Concern | File |
| --- | --- |
| New screen | `RussianWordOfDayApp/Sources/Views/ManageUsedWordsView.swift` |
| Route case | `RussianWordOfDayApp/Sources/Models.swift` |
| Router helper (parity) | `RussianWordOfDayApp/Sources/AppRouter.swift` |
| Navigation destination | `RussianWordOfDayApp/Sources/Views/RootView.swift` |
| Entry point row | `RussianWordOfDayApp/Sources/Views/SettingsView.swift` |

No `project.yml`, asset, or `WordStore` schema changes.

---

## 1) Add the route

In `Models.swift`, extend the existing `AppRoute` enum:

```swift
enum AppRoute: Hashable {
    case wordDetail(id: String)
    case settings
    case alphabet
    case usedWords
}
```

In `AppRouter.swift`, add a helper for parity with the existing
`openSettings()` / `openAlphabet()`:

```swift
func openUsedWords() {
    path.append(.usedWords)
}
```

In `RootView.swift`, extend the existing
`navigationDestination(for: AppRoute.self)` block:

```swift
.navigationDestination(for: AppRoute.self) { route in
    switch route {
    case .settings:
        SettingsView()
    case .alphabet:
        AlphabetView()
    case .wordDetail(let id):
        WordDetailView(wordID: id)
    case .usedWords:
        ManageUsedWordsView()
    }
}
```

---

## 2) Add the entry point in Settings

In `SettingsView.swift`, replace the current `Section("Dictionary")` body
with two rows: the new manage link first, the destructive reset second.
The destructive reset must remain visually last so the existing
`.confirmationDialog` keeps anchoring correctly.

```swift
Section("Dictionary") {
    NavigationLink(value: AppRoute.usedWords) {
        Text("Manage already used words")
    }

    Button(role: .destructive) {
        showResetConfirm = true
    } label: {
        Text("Reset already used words")
    }
}
```

`NavigationLink(value:)` works because `RootView` already declares the
matching `navigationDestination(for: AppRoute.self)`. Do not introduce
a separate `NavigationStack` inside Settings.

---

## 3) Build the new screen

Create `RussianWordOfDayApp/Sources/Views/ManageUsedWordsView.swift`.

Requirements:

- Standard `NavigationStack` back chevron in the top-left is automatic;
  do **not** add a custom back button.
- Title: "Used words", inline display mode.
- List rows show, in order: Russian (headline), English (subheadline,
  secondary), and a short relative date (caption, tertiary). Trailing
  edge: an "Add back" button (`borderedProminent` style) that
  triggers the un-use flow.
- Optimistic UI: tapping "Add back" immediately removes the row from
  the local `entries` list. The async `unuseWord` call runs in the
  background. If it throws (notification permission denied), the DB
  delete already committed inside `markWordUnused` so the in-memory
  state stays correct — surface no error.
- A `pendingIDs: Set<String>` keeps per-row in-flight state so a
  trigger-happy double-tap can't re-fire the same op (and the button
  shows a `ProgressView` while the async work runs). Even with the
  optimistic remove, this is a defensive guard against rapid taps
  before the SwiftUI diff runs.
- Empty state via `ContentUnavailableView`. Reached either on first
  paint with no used words OR after the user has tapped "Add back" on
  the last row.

### Suggested implementation

```swift
import SwiftUI

struct ManageUsedWordsView: View {
    @EnvironmentObject private var store: WordStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var scheduler: WordOfDayScheduler

    @State private var entries: [UsedWord] = []
    @State private var pendingIDs: Set<String> = []
    @State private var hasLoaded: Bool = false

    var body: some View {
        Group {
            if hasLoaded && entries.isEmpty {
                ContentUnavailableView(
                    "No used words yet",
                    systemImage: "tray",
                    description: Text("Words you've already received as a push will show up here. Tap “Add back” on any row to put it back in the pool.")
                )
            } else {
                List {
                    Section {
                        ForEach(entries) { entry in
                            row(for: entry)
                        }
                    } footer: {
                        if !entries.isEmpty {
                            Text("\(entries.count) used word\(entries.count == 1 ? "" : "s")")
                        }
                    }
                }
            }
        }
        .navigationTitle("Used words")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Pull a generous window. The seed dictionary is a few thousand
            // entries at most, so a single fetch is fine; switch to paged
            // loads if the dataset grows past ~5k.
            entries = store.usedWords(limit: 5_000)
            hasLoaded = true
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

        // Optimistic remove: snappy UI, and `markWordUnused` runs
        // synchronously inside `unuseWord` before any async work, so the
        // DB lines up with the visible list almost immediately.
        withAnimation { entries.removeAll { $0.id == id } }

        Task {
            defer {
                Task { @MainActor in
                    pendingIDs.remove(id)
                }
            }
            do {
                _ = try await scheduler.unuseWord(
                    id: id,
                    settings: settings,
                    store: store
                )
            } catch {
                // Notification permission denied or scheduling failed.
                // The DB un-use already committed inside `markWordUnused`,
                // so the row is genuinely back in the pool — keeping it
                // off the list is correct. Swallow silently to match the
                // existing top-up flow (see `RussianWordOfDayApp.swift`
                // `topUpBuffer`).
            }
        }
    }
}
```

Notes for the implementer:

- Do **not** call `store.resetUsedWords()` here — that nukes everything,
  which is what the destructive Reset button on Settings already does.
- Do **not** wrap the `List` in `NavigationStack`; the screen is pushed
  onto the existing stack from `RootView`.
- If `ContentUnavailableView` doesn't compile against the project's
  iOS 17 deployment target (it should), fall back to a simple
  `VStack { Image; Text }`.

---

## 4) Acceptance criteria

Manual QA in Simulator (light **and** dark) once changes are in:

1. Settings → Dictionary section shows two rows in this order:
   - "Manage already used words" (regular text, chevron)
   - "Reset already used words" (red, destructive)
2. Tapping the new row pushes "Used words" with a standard back
   chevron in the top-left.
3. Every row in `used_words` is listed, newest first, with the Russian
   word, English translation, and date used.
4. Tapping "Add back" on any row:
   - Animates the row out of the list immediately.
   - Removes the matching `used_words` entry.
   - Cancels any pending iOS notification for that word (verify by
     opening the system Settings → Notifications for the app, or by
     scheduling, viewing, then re-using a word).
   - Tops up the rolling buffer so the freed slot gets a different
     word at the tail.
5. With no rows left, the screen shows the empty `ContentUnavailableView`.
6. Hitting Settings → Reset already used words still works (the new
   confirmation popover from `RUNBOOK_UX_POLISH_DARK_MODE_RECENTS.md`
   stays compact directly above its source row).
7. No regressions to: search-bar focus + keyboard, recents dropdown,
   dark-mode colors, alphabet icon tinting, phonetic highlight,
   notification deep-link to Word Detail.

---

## What you should NOT change

- `project.yml`, `Info.plist`, asset catalog, `words.seed.json`.
- `WordStore` schema and SQL (`used_words`, `scheduled_pushes`,
  `recent_views`, FTS triggers — all unchanged).
- `WordOfDayScheduler` rolling-buffer algorithm and notification
  deep-link contract.
- `MainView`, `WordDetailView`, `AlphabetView` — none of them need
  edits for this iteration.
- The `markWordUsed` API was intentionally removed in the prior
  iteration. Do not reintroduce it.

After implementing, regenerate the Xcode project if you use
`xcodegen` (no `project.yml` change is expected, but the new Swift
file under `RussianWordOfDayApp/Sources/Views/` should be picked up
automatically by the existing `sources: - path: RussianWordOfDayApp/Sources`
glob). Build for iOS 17 Simulator.
