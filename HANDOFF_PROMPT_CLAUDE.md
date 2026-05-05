## Copy/paste prompt for Claude (implementation)

You are an expert iOS engineer. Implement a SwiftUI iOS app in the folder:
`/Users/zackerymiller/Projects/Russian - Word a Day`

The repo currently contains:
- `RussianWordOfDayApp/Sources/` (Swift sources to be added to an Xcode iOS App target)
- `RussianWordOfDayApp/Resources/words.seed.json` (bundled seed data)
- `DATA_LICENSES.md`, `scripts/README.md`, `README.md`

### App concept
App name: **Russian – Word of the Day**.

Offline-first: the app ships with a local Russian dictionary dataset (open-licensed) with ~5,000 common words in production. For now, a small seed JSON is provided.

### Requirements (must-have)

#### Data model per word
- `id` (stable string)
- `russian` (Cyrillic)
- `english` (translation/gloss)
- `meaning_en` (short English definition; optional)
- `phonetic` (IPA or transliteration; optional)

#### Persistence + search (decision locked)
- Use **SQLite + FTS5** for fast prefix search across RU and EN.
- Treat **`ё` and `е` as equivalent for search** (normalize to `е` for indexing/query), but keep canonical spelling for display.
- Guarantee daily words are **non-repeating until reset** using a local `used_words` table.

#### Screens / UX
1. **Main screen**
   - White background
   - Centered search bar
   - Cog wheel (top-right) opens Settings
   - Search supports Russian or English input
   - Matches appear in a dropdown under the search bar
   - Selecting a match opens Word Detail
2. **Word Detail screen**
   - Shows Russian word, English translation, English meaning, phonetic
   - Back button routes to Main (NavigationStack)
3. **Settings screen**
   - Options:
     - enable more than one push per day (implemented as `push_count_per_day` with range 1..5)
     - change daily push timing (one time per push)
     - reset already used words
   - Back button routes to Main

#### Notifications (decision locked)
- Use local notifications via `UNUserNotificationCenter`.
- Each scheduled notification includes `word_id` in `userInfo`.
- Notification title/body includes Russian + English.
- Tapping the notification opens the app to the correct Word Detail screen for that `word_id`.
- If the user sets multiple pushes/day, schedule N daily notifications at the configured times, each assigned a **unique** word for that day.
- If dictionary is exhausted: do **not** auto-reset; prompt user to reset.

### Existing implementation notes
There is already an initial implementation of:
- `AppDelegate` that handles notification tap and calls `router.openWordDetail(id:)`
- `NotificationManager` that schedules notifications with `userInfo["word_id"]`
- `WordStore` that creates SQLite tables (`words`, `words_fts`, `used_words`), seeds from bundled `words.seed.json`, provides search and random-unused selection.
- SwiftUI views: `MainView`, `SettingsView`, `WordDetailView` plus `RootView`.

### What you should do
1. Create an Xcode iOS App project (SwiftUI) named `RussianWordOfDay` inside `/Users/zackerymiller/Projects/Russian - Word a Day`.
2. Add all Swift files under `RussianWordOfDayApp/Sources/**` to the app target.
3. Add `RussianWordOfDayApp/Resources/words.seed.json` to the target’s Copy Bundle Resources.
4. Ensure the app builds and runs on Simulator with the current implementation.
5. Fix any issues you find in the SQLite schema/FTS trigger/backfill so search works correctly and seeding is idempotent.
6. Verify notification scheduling works and tap deep-link routes to the correct Word Detail.

### Acceptance criteria
- App launches to main white screen with search bar centered and gear top-right.
- Typing in search shows dropdown; selecting opens detail screen.
- Settings allows adjusting pushes/day and times; applying schedule requests permission and schedules notifications.
- Notifications contain `word_id`; tapping notification opens correct Word Detail.
- Daily words never repeat until user taps “Reset already used words”.
- Search is case-insensitive and treats `ё` == `е`.

