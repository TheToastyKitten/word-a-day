## Copy/paste prompt for Claude (UI polish + Alphabet)

You are an expert iOS engineer. Implement the following changes in the existing SwiftUI app at:
`/Users/zackerymiller/Projects/Russian - Word a Day`

Do **not** change the scope; focus on UI polish, Alphabet section, and two bugs.

### Goals
1. Make the app look more appealing (small layout tweaks).
2. Add a new **Alphabet** section (Cyrillic letters + English letter-name pronunciations).
3. Fix dropdown row tap target.
4. Fix used-words scheduling so **rescheduling doesn’t consume words**, and searching/viewing words never affects the notification pool.
5. Add/attach an app icon design and an Alphabet button icon.
6. Ensure pushed words do not repeat (new word each push).
7. Shorten the home-screen app name to **“Word a Day”**.

### App icon
- Desired icon: **white background**, centered **black** Russian text: `да!` (bold, modern sans-serif).
- Create a 1024×1024 PNG and place it at:
  - `RussianWordOfDayApp/Resources/Assets.xcassets/AppIcon.appiconset/appicon_da_1024.png`
- Ensure `Assets.xcassets` is included in the Xcode target and AppIcon is selected.

### Alphabet button icon
- Provided PNG path:
  - `/Users/zackerymiller/Projects/alphabet_cyrillic_icon_135961.png`
- Copy it into:
  - `RussianWordOfDayApp/Resources/Assets.xcassets/alphabet_icon.imageset/alphabet_cyrillic_icon_135961.png`
- Use `Image("alphabet_icon")` in SwiftUI.

### UI changes
#### Main screen
- In `RussianWordOfDayApp/Sources/Views/MainView.swift`:
  - Move the search bar from center to around the **top third** of the screen.
  - Add an **Alphabet** button **next to the cogwheel** (adjacent in the top bar) that routes to an Alphabet screen.

### Bug fix 1: dropdown tap area
- In `MainView`, search results dropdown rows must be tappable across the **entire row**.
- Ensure the `Button` label uses:
  - `.frame(maxWidth: .infinity, alignment: .leading)`
  - `.contentShape(Rectangle())`

### Bug fix 2: used-words pool behavior (important)
#### Intended behavior
- Opening word detail via search must **not** mark a word as used for notifications.
- Words should be removed from the pool **only when assigned to a notification slot**, not when browsed.
- Pressing “Apply notification schedule” multiple times must **not** burn new words each time.

#### Notification behavior requirement (key)
- A repeating daily notification trigger cannot change its content day-to-day. Therefore, to deliver a new word each push, the app must schedule **non-repeating** local notifications ahead of time.
- Implement a rolling buffer of **60 scheduled pushes** (not “60 days”):
  - If the user has 1 push/day, that covers ~60 days.
  - If they have 3 pushes/day, that covers ~20 days.
  - If they have 5 pushes/day, that covers ~12 days.
- Each scheduled push must have a **unique** `word_id` (no repeats) by selecting only from words not in `used_words`.
- The scheduler should “top up” automatically:
  - On app launch and when returning to foreground, check how many future notification requests exist that belong to this app’s word schedule.
  - If fewer than 60 remain, schedule more until the buffer is restored.
  - Scheduling must respect the user’s configured times (pushes/day) and assign pushes in chronological order.
  - Deep-link behavior must remain: each notification includes `userInfo["word_id"]` and tapping opens that word’s detail.

#### Current issue
`WordOfDayScheduler` historically called `store.nextUnusedRandomWord()` on every schedule apply, which marks a word used, causing reschedules to consume words.

#### Required fix (stable slot→word assignment)
- Add a stable assignment table `scheduled_words(slot INTEGER PRIMARY KEY, word_id TEXT NOT NULL, assigned_at INTEGER NOT NULL)` in SQLite.
- When applying schedule for each slot idx:
  - If `scheduled_words` already has a `word_id` for that slot, reuse it.
  - Otherwise pick a new unused word and mark it used **once**, then persist to `scheduled_words`.
- When the user resets used words, clear **both** `used_words` and `scheduled_words`.

#### App name (home screen)
- Change the displayed app name to **Word a Day** by setting:
  - `CFBundleDisplayName = "Word a Day"` in `RussianWordOfDayApp/Resources/Info.plist` (or via XcodeGen `project.yml` `info.properties`).

### Alphabet section
#### Data
- Create a single source of truth with all 33 letters:
  - `CyrillicLetter { upper, lower, nameEn, soundHintEnWord?, soundNote? }`
  - NameEn uses English letter-name pronunciation (examples):
    - А=ah, Б=beh, В=veh, … (include all letters, including Ё, Й, Ъ, Ы, Ь)
  - Also add an **English example word** next to each letter that mimics the sound (hardcoded list), e.g.:
    - Б → “bed”, В → “vodka”, Ц → “cats”
  - Letters that have no sound (Ь, Ъ) should show an annotation like **“no sound”** instead of an example word.

#### Screens
- Add a new route `.alphabet` and `AlphabetView` that lists all letters (upper+lower) and `nameEn`.
- Word detail screen enhancement:
  - Under the word’s main info, add a **Letters** section listing each Cyrillic letter used in the word and its `nameEn`.
  - Reuse the same Alphabet mapping.

### Files / touchpoints
- Routes: `RussianWordOfDayApp/Sources/Models.swift`, `RussianWordOfDayApp/Sources/Views/RootView.swift`
- Main screen: `RussianWordOfDayApp/Sources/Views/MainView.swift`
- Alphabet mapping: `RussianWordOfDayApp/Sources/CyrillicAlphabet.swift`
- Alphabet screen: `RussianWordOfDayApp/Sources/Views/AlphabetView.swift`
- Used-words + scheduling: `RussianWordOfDayApp/Sources/WordStore.swift`, `RussianWordOfDayApp/Sources/WordOfDayScheduler.swift`, `RussianWordOfDayApp/Sources/Views/SettingsView.swift`

### Acceptance criteria
- Search bar is visually around the top third.
- Alphabet button appears left of gear and opens Alphabet screen.
- Alphabet button appears adjacent to the gear (same top-right control cluster).
- Dropdown rows are fully tappable.
- Searching and opening word detail never affects used-words pool.
- Applying schedule multiple times doesn’t consume more words.
- Alphabet page lists all 33 letters with English letter-name pronunciations.
- Alphabet page also shows a sound-hint English example word for letters with sound; Ь/Ъ show “no sound”.
- Word detail shows Letters section for that word.
- App icon is updated to `да!`.
- Push notifications do not repeat words: each scheduled push uses a different unused word.
- The scheduler maintains a rolling buffer of **60 upcoming pushes**, supporting multiple pushes/day.
- The home screen app name is **Word a Day** (not truncated).

