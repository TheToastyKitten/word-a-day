## Runbook: Fix "Add back" not persisting on Manage Used Words screen

You are an expert iOS engineer. Implement the following changes on top of the
existing SwiftUI app at:
`/Users/zackerymiller/Projects/Russian - Word a Day`

The repo already follows the conventions in
`RUNBOOK_MANAGE_USED_WORDS.md` and `RUNBOOK_UX_POLISH_DARK_MODE_RECENTS.md`.
Do **not** change scope beyond the items below. Do **not** introduce new
dependencies.

### Scope (only these items)

1. **Add-back not persisting**: Tapping "Add back" on words in
   `ManageUsedWordsView` removes them from the list visually, but re-entering
   the screen shows all words back and still flagged as used.
2. **Confirm `markWordUnused` is wired correctly**: Verify the DB delete is
   actually being reached and committed when "Add back" is tapped.

---

## File touchpoints

| Concern | File(s) |
| --- | --- |
| Bug fix — remove bad `topUpRollingBuffer` call | `RussianWordOfDayApp/Sources/Views/ManageUsedWordsView.swift` |

No other files need to change. The `WordStore`, `WordOfDayScheduler`, and all
other views are correct as-is.

---

## Root cause

`ManageUsedWordsView.addBack(_:)` currently calls
`scheduler.unuseWord(id:settings:store:)`. That method:

1. Calls `store.markWordUnused(id:)` — synchronously deletes the row from
   `used_words` ✓
2. **Immediately calls `topUpRollingBuffer(...)`** — this picks a random word
   from the "unused" pool and inserts it back into `used_words` so the
   scheduled-push buffer stays at its target depth.

The freed word is now in the "unused" pool (step 1 just removed it), so
`topUpRollingBuffer` can immediately re-pick it as the buffer-fill candidate,
undoing the deletion. When the user taps "Add back" on every word one by one,
each concurrent top-up call re-inserts the words that previous calls just
freed. By the time the view is dismissed and re-entered, `used_words` is
effectively unchanged.

---

## 1) Fix `ManageUsedWordsView` — stop calling `unuseWord`

**Problem**: `scheduler.unuseWord(...)` silently re-marks freed words as used
via `topUpRollingBuffer`, making "Add back" a visual-only operation.

**Implementation in `ManageUsedWordsView.swift`**:

Replace the `addBack(_:)` private method body. The new version calls
`store.markWordUnused(id:)` and cancels the matching iOS notifications
directly, without triggering a buffer top-up. The buffer will top up
organically the next time the app schedules new notifications (app launch /
settings change), which is the correct time — not during a manual "add back".

```swift
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
        // which immediately re-inserts a random unused word (possibly the one
        // just freed) back into used_words.
        let cancelledIDs = store.markWordUnused(id: id)
        if !cancelledIDs.isEmpty {
            UNUserNotificationCenter.current()
                .removePendingNotificationRequests(withIdentifiers: cancelledIDs)
        }
    }
}
```

The `@EnvironmentObject private var scheduler` property on the view becomes
unused. Remove it from the view's property list too:

```swift
// DELETE this line — scheduler is no longer called from this view:
// @EnvironmentObject private var scheduler: WordOfDayScheduler
```

**Acceptance**: After tapping "Add back" on one or more words and navigating
back to Settings, re-entering "Used words" shows those words are gone. They do
not reappear.

---

## 2) Confirm `markWordUnused` actually commits

This is a verification step, not a code change. When the fix from §1 is in
place, confirm with a breakpoint or `print` that `markWordUnused` runs and
that `sqlite3_step` for the `DELETE FROM used_words` statement returns
`SQLITE_DONE`.

The relevant path is:

```
ManageUsedWordsView.addBack(_:)
  └─ store.markWordUnused(id:)          // WordStore.swift ~line 182
       └─ sqlite3_step(deleteUsedStmt)  // DELETE FROM used_words WHERE word_id = ?
```

If you want a quick sanity check in the Simulator without a debugger, add a
temporary `print` after the COMMIT in `markWordUnused`:

```swift
_ = sqlite3_exec(db, "COMMIT;", nil, nil, nil)
print("[WordStore] markWordUnused committed for id=\(wordID), cancelled=\(cancelled)")
return cancelled
```

Remove the `print` before shipping.

---

## Cross-cutting acceptance criteria

Verify in Simulator (light **and** dark):

1. Open Settings → "Manage already used words".
2. Tap "Add back" on several words. Each row animates out.
3. Navigate back to Settings, then re-enter "Manage already used words".
   The words tapped in step 2 are **gone** — they do not reappear.
4. Tap "Add back" on all remaining words until the list is empty.
   The empty-state `ContentUnavailableView` appears.
5. Navigate away and re-enter. The screen still shows the empty state.
6. Settings → "Reset already used words" still works as before (the
   confirmation popover appears and resets the list fully).
7. No regressions: word-of-day notifications still fire normally; notification
   deep-links to Word Detail still work; search, recents, and alphabet screens
   are unaffected.

---

## What you should NOT change

- `project.yml`, `Info.plist`, asset catalog, `words.seed.json`.
- `WordStore.markWordUnused` — it is correct. The bug is only in who calls it.
- `WordOfDayScheduler.unuseWord` — it is also correct for its intended use
  (post-notification buffer maintenance). Do not change it.
- `WordStore` schema and SQL (`used_words`, `scheduled_pushes`,
  `recent_views`, FTS triggers — all unchanged).
- `RootView`, `SettingsView`, `AppRouter`, `MainView`, `WordDetailView`,
  `AlphabetView` — none require edits.
