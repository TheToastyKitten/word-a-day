## Runbook: Defer "used" mark until a push actually fires

You are an expert iOS / SwiftUI engineer. Implement the following changes on top
of the existing iOS app at `Russian - Word a Day/RussianWordOfDayApp`.

The repo already follows the conventions in `RUNBOOK_MANAGE_USED_WORDS.md`,
`RUNBOOK_FIX_ADD_BACK_PERSISTENCE.md`, and `RUNBOOK_UX_POLISH_DARK_MODE_RECENTS.md`.
Do NOT change scope beyond the items below. Do NOT introduce new dependencies.

### Scope (only these items)
1. **Reservation-vs-usage split**: words sitting in the rolling buffer are reservations, not "used". They are excluded from random selection but are not flagged in `used_words` until their `fire_at` has elapsed.
2. **Fire-time promotion**: when a scheduled push's `fire_at` passes, the word is moved from `scheduled_pushes` into `used_words` (with `used_at = fire_at`) before the row is purged.
3. **Settings rebuild releases reservations**: tearing down the buffer on `Apply notification schedule` no longer leaves orphaned `used_words` rows behind, because reserved words were never written there in the first place.
4. **Upgrade migration**: existing installs that already have buffered-but-unfired words sitting in `used_words` (from the old eager-mark behaviour) get those rows cleared on first launch with the new build.

---

## File touchpoints

| Concern | File(s) |
| --- | --- |
| Random pick must exclude both `used_words` and `scheduled_pushes` | `RussianWordOfDayApp/Sources/WordStore.swift` |
| Reserve-only insert (no eager `used_words` write) | `RussianWordOfDayApp/Sources/WordStore.swift` |
| Promote fired pushes to `used_words` before purge | `RussianWordOfDayApp/Sources/WordStore.swift` |
| `remainingUnusedCount` matches the new pool definition | `RussianWordOfDayApp/Sources/WordStore.swift` |
| One-time migration in `createSchemaIfNeeded` | `RussianWordOfDayApp/Sources/WordStore.swift` |
| Updated comments on `clearScheduledPushes` | `RussianWordOfDayApp/Sources/WordStore.swift` |
| Scheduler calls promote+purge on every top-up | `RussianWordOfDayApp/Sources/WordOfDayScheduler.swift` |

No new files. No new dependencies. No schema-breaking changes — the migration
is a single `DELETE` against existing tables. New code paths reuse the
`scheduled_pushes` and `used_words` tables created in
`createSchemaIfNeeded`.

---

## 1) Reservation-vs-usage split in `pickRandomUnusedLocked`

**Problem**: `pickRandomUnusedLocked` only excludes `used_words`. Today that
works because `reserveAndPersistPush` writes both tables in the same
transaction, so a reserved word is also in `used_words`. After this runbook
the reservation no longer touches `used_words`, so the pick must additionally
exclude any word currently referenced by `scheduled_pushes`. Without this
change two future buffer slots could pick the same word.

**Implementation in `RussianWordOfDayApp/Sources/WordStore.swift`**:

1. Replace the body of `pickRandomUnusedLocked` so the SQL excludes both
   tables. Keep the function `private` and locked-transaction-only.

```swift
private func pickRandomUnusedLocked() -> WordEntry? {
    guard let db else { return nil }
    let sql = """
    SELECT w.id, w.ru, w.en, w.meaning_en, w.phonetic
    FROM words w
    LEFT JOIN used_words u       ON u.word_id = w.id
    LEFT JOIN scheduled_pushes s ON s.word_id = w.id
    WHERE u.word_id IS NULL
      AND s.word_id IS NULL
    ORDER BY RANDOM()
    LIMIT 1;
    """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
    return rowToWord(stmt)
}
```

**Acceptance**: With an empty `used_words` and 30 entries already in
`scheduled_pushes`, calling `pickRandomUnusedLocked` 100 times in a row never
returns a word whose id is in `scheduled_pushes`.

---

## 2) `reserveAndPersistPush` no longer marks the word used

**Problem**: today `reserveAndPersistPush` inserts into both `used_words` and
`scheduled_pushes` inside the same transaction. That's the root cause the user
reported: tapping `Apply notification schedule` flags 60 words as used even
though only one of them might fire that evening.

**Implementation in `RussianWordOfDayApp/Sources/WordStore.swift`**:

1. Drop the `insertUsedWordLocked` call. The reservation is now expressed
   purely by the `scheduled_pushes` row (which is what
   `pickRandomUnusedLocked` joins against in step 1).
2. Update the doc comment so the next reader understands the model.

```swift
/// Picks a random unused word AND inserts a `scheduled_pushes` row in a
/// single transaction. Returns the newly-built `ScheduledPush` plus the
/// `WordEntry`, or nil if the dictionary is exhausted.
///
/// The word is NOT inserted into `used_words` here — the row in
/// `scheduled_pushes` already excludes it from `pickRandomUnusedLocked`.
/// The promotion to `used_words` happens in
/// `promoteFiredPushesAndPurge(now:)` once `fire_at` has elapsed.
func reserveAndPersistPush(
    identifier: String,
    fireAt: Date,
    slot: Int
) -> (ScheduledPush, WordEntry)? {
    guard let db else { return nil }

    _ = sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)

    guard let word = pickRandomUnusedLocked() else {
        _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
        return nil
    }

    let now = Date()
    guard insertScheduledPushLocked(
        identifier: identifier,
        fireAt: fireAt,
        slot: slot,
        wordID: word.id,
        createdAt: now
    ) else {
        _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
        return nil
    }

    _ = sqlite3_exec(db, "COMMIT;", nil, nil, nil)
    let push = ScheduledPush(
        id: identifier,
        fireAt: fireAt,
        slot: slot,
        wordID: word.id,
        createdAt: now
    )
    return (push, word)
}
```

**Acceptance**: After tapping `Apply notification schedule` on a fresh
install, `SELECT COUNT(*) FROM used_words` returns `0`, and
`SELECT COUNT(*) FROM scheduled_pushes` returns `60`.

---

## 3) Promote fired pushes to `used_words` before purge

**Problem**: under the new model, a row in `scheduled_pushes` whose `fire_at`
has elapsed represents a word the user actually saw. We need to copy that word
into `used_words` before deleting the row, otherwise the buffer would silently
release every fired word back into the pool and the same word could come
around again next month.

**Implementation in `RussianWordOfDayApp/Sources/WordStore.swift`**:

1. Replace `purgePastScheduledPushes` with `promoteFiredPushesAndPurge` that
   does the promote + delete in a single transaction. Keep an internal
   `INSERT OR IGNORE` so a row that's already in `used_words` (e.g. user hit
   the toggle in Word Detail before the push fired) doesn't break.
2. The `used_at` column gets the row's `fire_at`, not `Date()`, so the Used
   Words list shows the actual delivery date rather than "the next time the
   app launched".

```swift
/// Promotes any `scheduled_pushes` rows whose `fire_at` has elapsed into
/// `used_words` (preserving `fire_at` as the `used_at` timestamp), then
/// deletes those rows. Idempotent and cheap — call it on every top-up,
/// foreground, and cold launch.
///
/// Replaces the older `purgePastScheduledPushes`, which deleted past rows
/// without preserving the "this word was delivered" signal. Callers that
/// only care about cleanup can keep using this method; the promote step is
/// a no-op when there's nothing past `now`.
func promoteFiredPushesAndPurge(now: Date = Date()) {
    guard let db else { return }
    let nowSec = Int64(now.timeIntervalSince1970)

    _ = sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)

    let promoteSQL = """
    INSERT OR IGNORE INTO used_words(word_id, used_at)
    SELECT word_id, fire_at FROM scheduled_pushes WHERE fire_at <= ?;
    """
    var promoteStmt: OpaquePointer?
    if sqlite3_prepare_v2(db, promoteSQL, -1, &promoteStmt, nil) == SQLITE_OK {
        sqlite3_bind_int64(promoteStmt, 1, nowSec)
        _ = sqlite3_step(promoteStmt)
    }
    sqlite3_finalize(promoteStmt)

    let deleteSQL = "DELETE FROM scheduled_pushes WHERE fire_at <= ?;"
    var deleteStmt: OpaquePointer?
    if sqlite3_prepare_v2(db, deleteSQL, -1, &deleteStmt, nil) == SQLITE_OK {
        sqlite3_bind_int64(deleteStmt, 1, nowSec)
        _ = sqlite3_step(deleteStmt)
    }
    sqlite3_finalize(deleteStmt)

    _ = sqlite3_exec(db, "COMMIT;", nil, nil, nil)
}
```

3. Delete the existing `purgePastScheduledPushes(now:)` method. It has exactly
   one caller (`WordOfDayScheduler.topUpRollingBuffer`) which step 6 below
   redirects to the new method.

**Acceptance**:
- Manually insert a `scheduled_pushes` row with `fire_at = now - 60`. Call
  `promoteFiredPushesAndPurge`. The row should be gone from
  `scheduled_pushes` and present in `used_words` with `used_at = fire_at`.
- A `scheduled_pushes` row with `fire_at = now + 3600` is left untouched by
  the same call.

---

## 4) `remainingUnusedCount` matches the new pool definition

**Problem**: the Settings screen shows a "X words remaining" count via
`remainingUnusedCount`. Under the new model, reservations also count as
taken, so this query must subtract `scheduled_pushes` too — otherwise the
displayed number would briefly drop by one each time a push fires and
"recover" by 60 each time the user hits `Apply`.

**Implementation in `RussianWordOfDayApp/Sources/WordStore.swift`**:

1. Mirror the join change from step 1.

```swift
func remainingUnusedCount() -> Int {
    guard let db else { return 0 }
    let sql = """
    SELECT COUNT(*)
    FROM words w
    LEFT JOIN used_words u       ON u.word_id = w.id
    LEFT JOIN scheduled_pushes s ON s.word_id = w.id
    WHERE u.word_id IS NULL
      AND s.word_id IS NULL;
    """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
    return Int(sqlite3_column_int(stmt, 0))
}
```

**Acceptance**: With a dictionary of 1000 words, an empty `used_words`, and
60 entries in `scheduled_pushes`, `remainingUnusedCount()` returns `940`.

---

## 5) One-time upgrade migration

**Problem**: an existing user who had `Apply` running under the old build has
60 words in `used_words` whose only crime was being buffered. After upgrading
to this build those rows would persist (and pollute Manage Used Words and
shrink the pool) unless we clean them up explicitly.

**Implementation in `RussianWordOfDayApp/Sources/WordStore.swift`**:

1. At the end of `createSchemaIfNeeded()` (after the FTS backfill block,
   before the closing brace), add a one-shot cleanup. The query is naturally
   idempotent — on a fresh install both tables are empty so it's a no-op.
   On a subsequent launch the previous run already cleaned the rows so the
   intersection is empty.

```swift
// One-time cleanup for upgrades from the eager-mark scheduler:
// any row in used_words whose word is currently sitting in
// scheduled_pushes was reserved-but-not-fired under the old behaviour.
// Free those rows so the new defer-until-fire model is honoured.
// On fresh installs and subsequent launches this is a no-op.
try exec("""
DELETE FROM used_words
WHERE word_id IN (SELECT word_id FROM scheduled_pushes);
""")
```

**Acceptance**:
- Fresh install: query is harmless, both tables empty.
- Upgrade simulation: pre-populate `used_words` with 60 ids that also exist
  in `scheduled_pushes`. After app launch, those 60 rows are gone from
  `used_words`. Any other `used_words` rows (representing actually-fired or
  manually-toggled words) are untouched.

---

## 6) Scheduler calls the new promote+purge on every top-up

**Problem**: `WordOfDayScheduler.topUpRollingBuffer` currently calls
`store.purgePastScheduledPushes(now:)`. After step 3 that method no longer
exists, so the call site needs updating. This is also where deferred-
"used" promotion gets wired into the lifecycle the rest of the app already
relies on (app launch / scenePhase active / settings apply all funnel
through `topUpRollingBuffer`).

**Implementation in `RussianWordOfDayApp/Sources/WordOfDayScheduler.swift`**:

1. Replace the `purgePastScheduledPushes` call near the top of
   `topUpRollingBuffer` with the new promote+purge. The doc-comment on the
   line above already explains "Drop expired rows so the count math is
   honest" — extend it to mention the promotion.

```swift
// Promote any fired pushes to used_words and drop those rows so the
// count math is honest. This is also our deferred-"used" hook: a push
// that fired since the last call lands in used_words here.
store.promoteFiredPushesAndPurge(now: now)
```

2. No other scheduler entry points need changes. `rebuildAfterSettingsChange`
   still funnels through `topUpRollingBuffer`, `purgeAfterReset` still only
   clears iOS pending requests (DB reset is `WordStore.resetUsedWords` and is
   already a full wipe), and `unuseWord` still funnels through
   `topUpRollingBuffer` after `markWordUnused`.

**Acceptance**: Set the system clock 5 minutes past the first scheduled
push's `fire_at`. Foreground the app. The push's word now appears in
`Manage already used words`; the row is gone from `scheduled_pushes`; the
buffer count drops by one and the next top-up tail-extends by one new word.

---

## 7) Comment cleanup on `clearScheduledPushes`

**Problem**: the existing doc comment explicitly says "spec is explicit that
words committed to the buffer remain 'used' even after a settings-change
rebuild". After this runbook that statement is the OPPOSITE of the truth and
will mislead the next reader.

**Implementation in `RussianWordOfDayApp/Sources/WordStore.swift`**:

1. Replace the doc comment above `clearScheduledPushes`. The body of the
   method does not change.

```swift
/// Empties the `scheduled_pushes` buffer. Does NOT touch `used_words` —
/// reserved words were never written there to begin with, so dropping the
/// reservations is enough to release them back into the pool. Caller is
/// responsible for cancelling the matching `UN` requests.
func clearScheduledPushes() {
    guard let db else { return }
    _ = sqlite3_exec(db, "DELETE FROM scheduled_pushes;", nil, nil, nil)
}
```

**Acceptance**: Reading the comment on a cold review accurately describes
the new behaviour. (`git blame` on the line should show this runbook's
commit as the most recent author.)

---

## Cross-cutting acceptance criteria

When done, verify on Simulator (light **and** dark — UI surfaces are unchanged
but Manage Used Words layout should still render correctly in both):

1. **Fresh install → Apply**: launch on a clean simulator, open Settings,
   tap `Apply notification schedule`. Open `Manage already used words`. The
   list shows the empty-state view ("No used words yet"). Previously this
   list would show 60 rows.
2. **Apply twice in a row**: change push count from 1 to 3, tap `Apply`,
   then change back to 1 and tap `Apply` again. After both applies,
   `used_words` is still empty.
3. **Push fires → promotion**: schedule a push 60 seconds out, background the
   app, wait for the banner, tap it (or open the app). The fired word now
   appears in `Manage already used words` and only that one word.
4. **Add back still works**: from step 3, tap `Add back` on the fired word.
   It disappears from the list. The next call into `topUpRollingBuffer` (or
   `unuseWord`'s internal call) may re-pick it for a future slot.
5. **Reset still works**: tap `Reset already used words`. Both `used_words`
   and `scheduled_pushes` are wiped. `Manage already used words` is empty;
   the buffer top-up on next launch / foreground rebuilds 60 fresh
   reservations.
6. **Upgrade migration**: simulate an upgrade by pre-seeding the DB with
   rows in both `used_words` and `scheduled_pushes` whose `word_id` overlap.
   Launch the app. The overlap rows are gone from `used_words`; non-overlap
   rows are preserved.
7. **Pool count honest**: open Settings (or any surface that calls
   `remainingUnusedCount`). The displayed count equals
   `total - used - reserved`, never `total - used`.

## What you should NOT change

- `RussianWordOfDayApp/Sources/Models.swift` — `ScheduledPush`, `UsedWord`,
  and `WordEntry` shapes are unchanged.
- `RussianWordOfDayApp/Sources/Notifications.swift` — `scheduleOneShot` and
  the `UNNotificationServiceExtension` situation stay exactly as-is. Local
  notifications cannot be mutated at delivery time, and we are not adding a
  service extension.
- `RussianWordOfDayApp/Sources/AppDelegate.swift` — the deep-link handling
  for notification taps is orthogonal to the buffer model.
- `RussianWordOfDayApp/Sources/Views/ManageUsedWordsView.swift` — the
  `markWordUnused` call already does the right thing under the new model
  (it deletes from `used_words` and any matching `scheduled_pushes` rows,
  which is now redundant for fired words but still cheap and correct).
- `RussianWordOfDayApp/Sources/Views/SettingsView.swift` — `applySchedule`
  and `resetUsedWords` keep their current control flow.
- `project.yml`, `Info.plist`, `words.seed.json` — untouched.
- Existing schema (`words`, `used_words`, `scheduled_pushes`,
  `scheduled_words`, `recent_views`) is additive only. No `ALTER TABLE`,
  no new columns, no new tables.
- The 60-push `bufferTarget` constant. Tuning it is out of scope.
