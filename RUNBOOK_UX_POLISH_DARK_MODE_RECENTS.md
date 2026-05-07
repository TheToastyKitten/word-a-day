## Runbook + copy/paste prompt for Claude (UX polish: keyboard dismiss, dark mode, reset confirm, phonetic highlight, manual used toggle, recent views)

You are an expert iOS engineer. Implement the following changes on top of the existing SwiftUI app at:
`/Users/zackerymiller/Projects/Russian - Word a Day`

The repo already follows the conventions established in the prior runbooks
(`HANDOFF_PROMPT_CLAUDE.md`, `HANDOFF_PROMPT_CLAUDE_UI_ALPHABET.md`,
`HANDOFF_PROMPT_CLAUDE_POST_UI_ALPHABET_ITERATION.md`,
`HANDOFF_PROMPT_CLAUDE_ITERATION_ALPHABET_PDF_USED_WORDS.md`). Do **not**
change scope beyond the items below. Do **not** introduce new dependencies.

### Scope (only these items)
1. **Search bar keyboard dismissal**: the keyboard currently has no way to close once the search field is focused.
2. **Dark mode on the main screen**: black background, "bright gray" search bar with white letters. Alphabet and Settings already adapt correctly via `Form`/`List` and must remain unchanged.
3. **Reset used words → tap + confirm**: replace the (perceived) hold-to-trigger destructive button with a normal tap that opens a confirmation dialog before resetting.
4. **Alphabet page phonetic highlighting**: in each letter's "Similar English sound" line, highlight the part of the example word that produces the relevant sound.
5. **Manual mark-used toggle on Word Detail**: each word entry gets a boolean toggle to add/remove that word from the push pool by hand.
6. **Recently viewed words on empty search**: focusing the search bar with an empty query shows up to 5 recently viewed words in the dropdown.

---

## File touchpoints (overview)

| Concern | File(s) |
| --- | --- |
| Keyboard dismiss + recent views in dropdown + dark mode colors | `RussianWordOfDayApp/Sources/Views/MainView.swift` |
| Reset confirmation dialog | `RussianWordOfDayApp/Sources/Views/SettingsView.swift` |
| Phonetic highlight data + rendering | `RussianWordOfDayApp/Sources/CyrillicAlphabet.swift`, `RussianWordOfDayApp/Sources/Views/AlphabetView.swift`, `RussianWordOfDayApp/Sources/Views/WordDetailView.swift` |
| Manual used toggle + recent views recording | `RussianWordOfDayApp/Sources/Views/WordDetailView.swift`, `RussianWordOfDayApp/Sources/WordStore.swift` |
| New `recent_views` table + new `markWordUsed`/`recentViews` APIs | `RussianWordOfDayApp/Sources/WordStore.swift` |

No `project.yml` changes, no new resource files, and no schema-breaking
changes to existing tables. New SQLite objects must be additive (`CREATE TABLE
IF NOT EXISTS …` + `CREATE INDEX IF NOT EXISTS …`).

---

## 1) Search bar keyboard dismissal

**Problem**: `MainView` puts a focusable `TextField` near the top of the
screen with no way to dismiss the keyboard short of leaving the view. The
Main screen is not inside a `ScrollView`, so `.scrollDismissesKeyboard` is
not applicable.

**Implementation in `MainView.swift`**:

1. Add focus state:
   ```swift
   @FocusState private var searchFieldFocused: Bool
   ```
2. Bind it to the search `TextField`:
   ```swift
   TextField("Search (Russian or English)", text: $query)
       .focused($searchFieldFocused)
       .submitLabel(.search)
       .onSubmit { searchFieldFocused = false }
       …
   ```
3. Add a keyboard-accessory **Done** button (always reachable while typing).
   Attach the toolbar to the outer `ZStack` (or any view that owns the
   keyboard scope):
   ```swift
   .toolbar {
       ToolbarItemGroup(placement: .keyboard) {
           Spacer()
           Button("Done") { searchFieldFocused = false }
       }
   }
   ```
4. Tap-anywhere-outside fallback: attach a tap gesture to the background
   `Color` so tapping empty page space dismisses the keyboard. Use
   `contentShape(Rectangle())` so the hit target is the full background:
   ```swift
   Color(uiColor: .systemBackground)
       .ignoresSafeArea()
       .contentShape(Rectangle())
       .onTapGesture { searchFieldFocused = false }
   ```
   Make sure this gesture does **not** cover the search field or dropdown
   (place the background as the bottom layer of the `ZStack`, with the
   `VStack` above it; the dropdown's own buttons take precedence over the
   background tap).

**Acceptance**: tapping the Done keyboard button OR tapping anywhere on the
page that is not the search field or a dropdown row hides the keyboard. The
dropdown row tap still navigates to Word Detail (do not regress
`HANDOFF_PROMPT_CLAUDE_UI_ALPHABET.md` Bug fix 1).

---

## 2) Dark mode on the Main screen

**Problem**: `MainView` hardcodes `Color.white` for the background and
dropdown card, `.foregroundStyle(.black)` for several glyphs, and uses
`Color(.systemGray6)` for the search bar fill. In dark mode this leaves the
page white-on-white text or invisible glyphs.

The Alphabet (`AlphabetView`) and Settings (`SettingsView`) screens use
`List`/`Form` and already adapt — **do not change them**.

**Required color audits in `MainView.swift`**:

| Old | New | Rationale |
| --- | --- | --- |
| `Color.white.ignoresSafeArea()` | `Color(uiColor: .systemBackground).ignoresSafeArea()` | white in light, ~black in dark |
| Search field fill `Color(.systemGray6)` | a "bright gray" in dark mode (see below) | spec: search bar visible against black |
| Search field text (currently inherits) | leave unset → `.primary` | white in dark, black in light |
| Search field stroke `Color(.systemGray4)` | leave as-is | already adaptive |
| Dropdown card `Color.white` | `Color(uiColor: .systemBackground)` | adapts |
| Dropdown title `.foregroundStyle(.black)` | `.foregroundStyle(.primary)` | adapts |
| Dropdown subtitle `.foregroundStyle(.gray)` | `.foregroundStyle(.secondary)` | adapts |
| Chevron `Color(.systemGray3)` | leave as-is | already adaptive |
| Gear icon `.foregroundStyle(.black)` | `.foregroundStyle(.primary)` | adapts |
| Alphabet PNG (`.renderingMode(.original)`) | leave as-is | the asset is intentionally rendered as the source PNG |

**"Bright gray" search-bar fill**: introduce a helper inside `MainView.swift`
(or the closest reasonable scope — do **not** add a new file unless other
views also need it):

```swift
/// Light: standard light-gray search-bar fill (matches iOS search style).
/// Dark: a clearly-visible gray against the black `.systemBackground`,
/// not the near-black `systemGray6`/`systemGray5` defaults.
private var searchFieldFill: Color {
    Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? .systemGray2 : .systemGray6
    })
}
```

Use it in the `RoundedRectangle(cornerRadius: 14).fill(searchFieldFill)`
expression. Rationale for `.systemGray2` in dark mode: it sits at roughly
`#636366`, which reads as a clearly visible "bright gray" against
`#000000`/`#1C1C1E` page backgrounds while the standard search-bar
`systemGray6` (≈`#1C1C1E` in dark) is essentially invisible.

If `.systemGray2` reads too bright in QA, fall back to `.systemGray3`. Do
not introduce an asset-catalog color for this; keep the adaptive logic in
code so a future tweak is one diff.

**Acceptance**:
- Light mode: visually identical to the current build.
- Dark mode: page background is black/`systemBackground`-dark; search bar
  pill is clearly a lighter gray than the page; typed letters and dropdown
  text are white; gear icon is white; dropdown card sits on
  `systemBackground` (not white); Alphabet and Settings still look correct.

---

## 3) Reset already used words: tap + confirm

**Problem**: in `SettingsView.swift`, the destructive button currently runs
`resetUsedWords()` on tap. The user reports this as feeling like a "hold
click" (likely because of the destructive role styling) and wants an
explicit confirmation step.

**Implementation in `SettingsView.swift`**:

1. Add state:
   ```swift
   @State private var showResetConfirm = false
   ```
2. Change the button's action to surface the dialog instead of running the
   reset:
   ```swift
   Button(role: .destructive) {
       showResetConfirm = true
   } label: {
       Text("Reset already used words")
   }
   ```
3. Attach a `confirmationDialog` near the other alerts:
   ```swift
   .confirmationDialog(
       "Reset already used words?",
       isPresented: $showResetConfirm,
       titleVisibility: .visible
   ) {
       Button("Reset", role: .destructive) {
           Task { await resetUsedWords() }
       }
       Button("Cancel", role: .cancel) {}
   } message: {
       Text("This brings every word back into the push pool and cancels all pending notifications. You can't undo this.")
   }
   ```
4. Leave `resetUsedWords()` itself unchanged — it already calls
   `store.resetUsedWords()` and `scheduler.purgeAfterReset()`.

**Acceptance**: tapping the destructive row opens an action sheet with a
red "Reset" and a "Cancel". Cancel does nothing. Reset runs the existing
flow and the row visibly returns to its idle state.

---

## 4) Alphabet page: phonetic highlighting in example words

**Problem**: each letter's "Similar English sound" line currently renders
as a flat italic/secondary string (e.g. `like ar in far`). The user wants
the part of the example word that produces the sound to be visually
highlighted, so a learner can immediately see which letters in the example
make the relevant sound.

The current `CyrillicLetter` model stores the human phrase as a single
`similarSoundEn: String?`. To highlight reliably (and avoid fragile string
parsing every render), refactor it into structured data and derive the
human phrase for accessibility.

### 4a. Data model change in `CyrillicAlphabet.swift`

Add:

```swift
/// One "phoneme example": the chunk of an English example word that
/// produces the letter's sound. `phonetic = "ar"`, `example = "far"` →
/// rendered as "like ar in f̲a̲r̲" with "ar" emphasised inside "far".
///
/// `note` carries any trailing parenthetical that doesn't fit the
/// "like X in Y" template (e.g. "(but rolled)" for Р).
struct PhoneticExample: Hashable {
    let phonetic: String
    let example: String
    let note: String?
}
```

Replace the existing `similarSoundEn: String?` field on `CyrillicLetter`
with:

```swift
let phoneticExamples: [PhoneticExample]
```

Keep `soundNote: String?` as-is (used for "has no sound").

Add a computed natural-language phrase that reproduces the previous string
exactly so callers / accessibility text don't regress:

```swift
extension CyrillicLetter {
    /// Reproduces the previous flat string ("like ar in far",
    /// "like ye in yet or e in exit") for VoiceOver and any code that
    /// still wants the plain phrase.
    var similarSoundEnPhrase: String? {
        guard !phoneticExamples.isEmpty else { return nil }
        let parts = phoneticExamples.map { ex in
            var s = "like \(ex.phonetic) in \(ex.example)"
            if let note = ex.note { s += " \(note)" }
            return s
        }
        return parts.joined(separator: " or ")
    }

    var soundDescription: String? {
        soundNote ?? similarSoundEnPhrase
    }
}
```

`soundDescription` is already consumed by `WordDetailView.swift` and
`AlphabetView.swift`'s accessibility path, so keeping its signature
unchanged means those callers compile without further edits except for the
visual rendering changes below.

### 4b. Replace the alphabet table

Use these structured values (same source PDF as
`HANDOFF_PROMPT_CLAUDE_ITERATION_ALPHABET_PDF_USED_WORDS.md` §1, but split
into `phonetic` / `example` / `note`). Letters with multiple "or" branches
get multiple `PhoneticExample` entries, in the same order they appear in
the original phrase:

```swift
static let letters: [CyrillicLetter] = [
    CyrillicLetter(upper: "А", lower: "а", nameEn: "a",
        phoneticExamples: [PhoneticExample(phonetic: "ar", example: "far", note: nil)],
        soundNote: nil),
    CyrillicLetter(upper: "Б", lower: "б", nameEn: "be",
        phoneticExamples: [PhoneticExample(phonetic: "b", example: "box", note: nil)],
        soundNote: nil),
    CyrillicLetter(upper: "В", lower: "в", nameEn: "ve",
        phoneticExamples: [PhoneticExample(phonetic: "v", example: "voice", note: nil)],
        soundNote: nil),
    CyrillicLetter(upper: "Г", lower: "г", nameEn: "ge",
        phoneticExamples: [PhoneticExample(phonetic: "g", example: "go", note: nil)],
        soundNote: nil),
    CyrillicLetter(upper: "Д", lower: "д", nameEn: "de",
        phoneticExamples: [PhoneticExample(phonetic: "d", example: "day", note: nil)],
        soundNote: nil),
    CyrillicLetter(upper: "Е", lower: "е", nameEn: "ye",
        phoneticExamples: [
            PhoneticExample(phonetic: "ye", example: "yet", note: nil),
            PhoneticExample(phonetic: "e",  example: "exit", note: nil),
        ],
        soundNote: nil),
    CyrillicLetter(upper: "Ё", lower: "ё", nameEn: "yo",
        phoneticExamples: [PhoneticExample(phonetic: "yo", example: "your", note: nil)],
        soundNote: nil),
    CyrillicLetter(upper: "Ж", lower: "ж", nameEn: "zhe",
        phoneticExamples: [PhoneticExample(phonetic: "s", example: "pleasure", note: nil)],
        soundNote: nil),
    CyrillicLetter(upper: "З", lower: "з", nameEn: "ze",
        phoneticExamples: [PhoneticExample(phonetic: "z", example: "zoo", note: nil)],
        soundNote: nil),
    CyrillicLetter(upper: "И", lower: "и", nameEn: "ee",
        phoneticExamples: [PhoneticExample(phonetic: "ee", example: "meet", note: nil)],
        soundNote: nil),
    CyrillicLetter(upper: "Й", lower: "й", nameEn: "ee kratkoye (short i)",
        phoneticExamples: [PhoneticExample(phonetic: "y", example: "boy", note: nil)],
        soundNote: nil),
    CyrillicLetter(upper: "К", lower: "к", nameEn: "ka",
        phoneticExamples: [
            PhoneticExample(phonetic: "k", example: "key", note: nil),
            PhoneticExample(phonetic: "c", example: "cat", note: nil),
        ],
        soundNote: nil),
    CyrillicLetter(upper: "Л", lower: "л", nameEn: "el",
        phoneticExamples: [PhoneticExample(phonetic: "l", example: "lamp", note: nil)],
        soundNote: nil),
    CyrillicLetter(upper: "М", lower: "м", nameEn: "em",
        phoneticExamples: [PhoneticExample(phonetic: "m", example: "man", note: nil)],
        soundNote: nil),
    CyrillicLetter(upper: "Н", lower: "н", nameEn: "en",
        phoneticExamples: [PhoneticExample(phonetic: "n", example: "note", note: nil)],
        soundNote: nil),
    CyrillicLetter(upper: "О", lower: "о", nameEn: "o",
        phoneticExamples: [PhoneticExample(phonetic: "o", example: "not", note: nil)],
        soundNote: nil),
    CyrillicLetter(upper: "П", lower: "п", nameEn: "pe",
        phoneticExamples: [PhoneticExample(phonetic: "p", example: "pet", note: nil)],
        soundNote: nil),
    CyrillicLetter(upper: "Р", lower: "р", nameEn: "er",
        phoneticExamples: [PhoneticExample(phonetic: "r", example: "rock", note: "(but rolled)")],
        soundNote: nil),
    CyrillicLetter(upper: "С", lower: "с", nameEn: "es",
        phoneticExamples: [PhoneticExample(phonetic: "s", example: "sun", note: nil)],
        soundNote: nil),
    CyrillicLetter(upper: "Т", lower: "т", nameEn: "te",
        phoneticExamples: [PhoneticExample(phonetic: "t", example: "table", note: nil)],
        soundNote: nil),
    CyrillicLetter(upper: "У", lower: "у", nameEn: "oo",
        phoneticExamples: [PhoneticExample(phonetic: "oo", example: "moon", note: nil)],
        soundNote: nil),
    CyrillicLetter(upper: "Ф", lower: "ф", nameEn: "ef",
        phoneticExamples: [PhoneticExample(phonetic: "f", example: "food", note: nil)],
        soundNote: nil),
    CyrillicLetter(upper: "Х", lower: "х", nameEn: "kha",
        phoneticExamples: [PhoneticExample(phonetic: "ch", example: "Scottish loch", note: nil)],
        soundNote: nil),
    CyrillicLetter(upper: "Ц", lower: "ц", nameEn: "tse",
        phoneticExamples: [PhoneticExample(phonetic: "ts", example: "boots", note: nil)],
        soundNote: nil),
    CyrillicLetter(upper: "Ч", lower: "ч", nameEn: "che",
        phoneticExamples: [PhoneticExample(phonetic: "ch", example: "chat", note: nil)],
        soundNote: nil),
    CyrillicLetter(upper: "Ш", lower: "ш", nameEn: "sha",
        phoneticExamples: [PhoneticExample(phonetic: "sh", example: "short", note: nil)],
        soundNote: nil),
    CyrillicLetter(upper: "Щ", lower: "щ", nameEn: "shcha",
        phoneticExamples: [PhoneticExample(phonetic: "sh_ch", example: "fresh_cheese", note: nil)],
        soundNote: nil),
    CyrillicLetter(upper: "Ъ", lower: "ъ", nameEn: "tviordiy znak (hard sign)",
        phoneticExamples: [],
        soundNote: "has no sound"),
    CyrillicLetter(upper: "Ы", lower: "ы", nameEn: "ih*",
        phoneticExamples: [PhoneticExample(phonetic: "i", example: "ill", note: nil)],
        soundNote: nil),
    CyrillicLetter(upper: "Ь", lower: "ь", nameEn: "myagkiy znak (soft sign)",
        phoneticExamples: [],
        soundNote: "has no sound"),
    CyrillicLetter(upper: "Э", lower: "э", nameEn: "e",
        phoneticExamples: [PhoneticExample(phonetic: "e", example: "end", note: nil)],
        soundNote: nil),
    CyrillicLetter(upper: "Ю", lower: "ю", nameEn: "yoo",
        phoneticExamples: [PhoneticExample(phonetic: "u", example: "use", note: nil)],
        soundNote: nil),
    CyrillicLetter(upper: "Я", lower: "я", nameEn: "ya",
        phoneticExamples: [PhoneticExample(phonetic: "ya", example: "yard", note: nil)],
        soundNote: nil),
]
```

`Щ`'s phonetic chunk uses an underscore as a sub-chunk separator
(matching the PDF's `sh_ch` / `fresh_cheese` notation); render it
literally — do not strip the underscore.

### 4c. Highlight rendering helper

Add to `CyrillicAlphabet.swift` (or directly in `AlphabetView.swift` if you
prefer to keep view formatting in the view layer — either is fine, just
keep one source of truth):

```swift
extension CyrillicLetter {
    /// Returns an `AttributedString` rendering of the full
    /// "like X in Y or A in B" phrase, with the phonetic chunk emphasised
    /// inside both its name (`X`) and its example word (`Y`).
    /// Returns nil when the letter has no examples (Ь, Ъ).
    func attributedSoundDescription(
        emphasis: AttributeContainer = AttributeContainer().font(.footnote.weight(.semibold))
    ) -> AttributedString? {
        guard !phoneticExamples.isEmpty else { return nil }

        var out = AttributedString()
        for (idx, ex) in phoneticExamples.enumerated() {
            if idx == 0 {
                out += AttributedString("like ")
            } else {
                out += AttributedString(" or ")
            }

            // "X" — emphasise the chunk itself.
            var chunk = AttributedString(ex.phonetic)
            chunk.mergeAttributes(emphasis)
            out += chunk

            out += AttributedString(" in ")

            // Example word with the chunk emphasised wherever it appears
            // (case-insensitive). For `loch` / `Scottish loch` etc. this
            // highlights every occurrence.
            out += highlight(chunk: ex.phonetic, in: ex.example, emphasis: emphasis)

            if let note = ex.note {
                out += AttributedString(" \(note)")
            }
        }
        return out
    }

    private func highlight(
        chunk: String,
        in source: String,
        emphasis: AttributeContainer
    ) -> AttributedString {
        var attr = AttributedString(source)
        guard !chunk.isEmpty else { return attr }
        var searchRange = attr.startIndex..<attr.endIndex
        while let range = attr[searchRange].range(of: chunk, options: .caseInsensitive) {
            attr[range].mergeAttributes(emphasis)
            searchRange = range.upperBound..<attr.endIndex
        }
        return attr
    }
}
```

Notes:
- The helper highlights **every** occurrence of the chunk in the example
  word so cases like Х (`ch` in `Scottish loch`) light up both `ch`s, and
  Ч (`ch` in `chat`) lights up its single `ch`. This is intentional and
  pedagogically correct.
- We highlight the chunk in the descriptor (`like ar in …`) too because
  the eye lands on it before the example word; if QA prefers chunk
  emphasis only inside the example word, drop the first `chunk +=`
  block — keep the helper otherwise unchanged.

### 4d. Render in `AlphabetView.swift`

Replace the existing `soundLine` with one that prefers the
`AttributedString`:

```swift
@ViewBuilder
private var soundLine: some View {
    if let note = letter.soundNote {
        Text(note)
            .foregroundStyle(.secondary)
            .italic()
    } else if let attr = letter.attributedSoundDescription() {
        Text(attr)
            .foregroundStyle(.secondary)
    }
}
```

Drop the legacy `letter.similarSoundEn` branch (the field no longer
exists). The accessibility text in `accessibilityText` should keep using
`letter.soundDescription` (which still returns the flat phrase via the new
`similarSoundEnPhrase` computed property).

### 4e. Render in `WordDetailView.swift` letters section

In `lettersSection(for:)`, replace the inner sound-description `Text`
with the same attributed render:

```swift
if let note = letter.soundNote {
    Text(note)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .italic()
} else if let attr = letter.attributedSoundDescription() {
    Text(attr)
        .font(.footnote)
        .foregroundStyle(.secondary)
}
```

The conditional `.italic(letter.soundNote != nil)` simplifies away because
the two branches are now distinct.

**Acceptance**:
- Alphabet rows show e.g. **А а — a — like a̲r̲ in f**ar** (with `ar`
  bolded inside `far`).
- Multi-branch rows like Е (`like ye in yet or e in exit`) render both
  patterns with each chunk bolded inside its example word.
- Ь and Ъ still show plain italic "has no sound".
- Word Detail "Letters" section uses the same emphasis.
- VoiceOver still reads the full natural-language phrase via
  `soundDescription`.

---

## 5) Manual mark-used toggle on Word Detail

**Goal**: every `WordEntry` page shows a single boolean control that lets
the user pull a word out of the push pool, or push it back in, by hand.
This is the user-facing entry point for the "Used words" persistence
machinery already implemented in
`HANDOFF_PROMPT_CLAUDE_ITERATION_ALPHABET_PDF_USED_WORDS.md` §5.

### 5a. New public WordStore method

`WordStore.swift` already has a private `insertUsedWordLocked(...)` and a
public `markWordUnused(id:)`. Add a symmetric public counterpart for the
"manually mark as used" path:

```swift
/// Marks a word used without scheduling any push. This is the manual
/// entry point used by the Word Detail toggle; it does NOT touch
/// `scheduled_pushes`, so any future push that already references this
/// word continues to fire (it was already going to).
///
/// Idempotent: if the word is already in `used_words`, this is a no-op.
@discardableResult
func markWordUsed(id wordID: String, at date: Date = Date()) -> Bool {
    guard let db else { return false }
    let sql = "INSERT OR IGNORE INTO used_words(word_id, used_at) VALUES(?, ?);"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, wordID, -1, SQLITE_TRANSIENT_SWIFT)
    sqlite3_bind_int64(stmt, 2, Int64(date.timeIntervalSince1970))
    return sqlite3_step(stmt) == SQLITE_DONE
}
```

Do not add a buffer top-up here — the buffer already has its target count;
adding a used word out-of-band only narrows the future pool.

### 5b. Toggle UI in `WordDetailView.swift`

Inject the scheduler and settings (already provided by the app entry
point):

```swift
@EnvironmentObject private var settings: AppSettings
@EnvironmentObject private var scheduler: WordOfDayScheduler
```

Track whether the word is currently used:

```swift
@State private var isUsed: Bool = false
@State private var isMutatingUsed: Bool = false
```

Initialise on appear (and on `wordID` change, in case the view is reused):

```swift
.task(id: wordID) {
    isUsed = store.isWordUsed(id: wordID)
}
```

Render the toggle as its own section, between Meaning and Pronunciation
(or after Pronunciation if a word lacks a meaning — pick the most stable
slot; suggested: directly under the header):

```swift
private func usedToggleSection(word: WordEntry) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Toggle(isOn: Binding(
            get: { isUsed },
            set: { newValue in handleToggle(newValue: newValue, word: word) }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Already used")
                    .font(.headline)
                Text(isUsed
                     ? "Excluded from push notifications."
                     : "Eligible for push notifications.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(isMutatingUsed)
    }
    .padding(.top, 4)
}

private func handleToggle(newValue: Bool, word: WordEntry) {
    // Optimistic: flip the UI immediately so the Toggle animates,
    // then persist. Any failure reverts.
    let previous = isUsed
    isUsed = newValue
    isMutatingUsed = true
    Task {
        defer { Task { @MainActor in isMutatingUsed = false } }
        if newValue {
            store.markWordUsed(id: word.id)
        } else {
            do {
                _ = try await scheduler.unuseWord(
                    id: word.id,
                    settings: settings,
                    store: store
                )
            } catch {
                // Most likely cause: notification permission denied.
                // The DB un-use already happened inside `unuseWord`
                // (markWordUnused commits before scheduling), so the UI
                // state is consistent — keep the new value.
                _ = previous
            }
        }
    }
}
```

Wire it into the body's `if let word { … }` block right after `headerSection`.

**Important constraint**: do **not** call `markWordUsed` for words that
the user merely *views* (`HANDOFF_PROMPT_CLAUDE_UI_ALPHABET.md` Bug fix 2:
"Opening word detail via search must not mark a word as used"). The toggle
is the only path to `markWordUsed`; the `recordRecentView` flow added in
§6 below must not write to `used_words`.

**Acceptance**:
- Opening any Word Detail shows a labelled Toggle reflecting the current
  used state.
- Toggling ON immediately moves the word out of the push pool. The next
  call to `topUpRollingBuffer` will not pick it.
- Toggling OFF cancels any pending push for this word, removes it from
  `used_words`, and fires `topUpRollingBuffer` to back-fill the freed
  buffer slot (existing `unuseWord` behaviour — unchanged).
- Toggle state survives navigation away and back.
- Permission-denied unuse still leaves the DB in the new "unused" state
  (and surfaces no error to the user — silent like the existing top-up
  path).

---

## 6) Recently viewed words on empty search

**Goal**: focusing the search bar with no query shows up to 5 recently
viewed words, in most-recent-first order, in the same dropdown that
search results use.

### 6a. New SQLite table + WordStore APIs

In `createSchemaIfNeeded()` in `WordStore.swift`, add (additively, after
the existing `scheduled_pushes` block):

```swift
try exec("""
CREATE TABLE IF NOT EXISTS recent_views(
  word_id   TEXT PRIMARY KEY,
  viewed_at INTEGER NOT NULL,
  FOREIGN KEY(word_id) REFERENCES words(id) ON DELETE CASCADE
);
""")
try exec("CREATE INDEX IF NOT EXISTS idx_recent_views_viewed_at ON recent_views(viewed_at DESC);")
```

Add public methods:

```swift
/// Records (or refreshes) a "user opened this word's detail" event.
/// `INSERT OR REPLACE` keeps a single row per word with the latest
/// timestamp so the recents list is naturally deduplicated.
func recordRecentView(id wordID: String, at date: Date = Date()) {
    guard let db else { return }
    let sql = "INSERT OR REPLACE INTO recent_views(word_id, viewed_at) VALUES(?, ?);"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, wordID, -1, SQLITE_TRANSIENT_SWIFT)
    sqlite3_bind_int64(stmt, 2, Int64(date.timeIntervalSince1970))
    _ = sqlite3_step(stmt)

    // Soft cap: keep at most ~50 rows so the table can't grow unbounded
    // for a long-lived install. The dropdown only ever displays 5.
    _ = sqlite3_exec(db, """
        DELETE FROM recent_views
        WHERE word_id NOT IN (
          SELECT word_id FROM recent_views ORDER BY viewed_at DESC LIMIT 50
        );
        """, nil, nil, nil)
}

/// Returns the most recently viewed words, newest first, joined with
/// their display fields. Words whose underlying row has been deleted
/// (e.g. seed update removed them) are silently skipped via the join.
func recentViews(limit: Int = 5) -> [WordEntry] {
    guard let db else { return [] }
    let sql = """
    SELECT w.id, w.ru, w.en, w.meaning_en, w.phonetic
    FROM recent_views r
    JOIN words w ON w.id = r.word_id
    ORDER BY r.viewed_at DESC
    LIMIT ?;
    """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_int(stmt, 1, Int32(limit))

    var out: [WordEntry] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        out.append(rowToWord(stmt))
    }
    return out
}
```

`recordRecentView` must **not** touch `used_words`, `scheduled_pushes`, or
`scheduled_words` — it's a pure UI breadcrumb.

### 6b. Record a view when Word Detail appears

In `WordDetailView.swift`, alongside the `task(id: wordID)` added in §5b,
record a recent-view entry. Combine into one task to keep one DB hop per
appearance:

```swift
.task(id: wordID) {
    isUsed = store.isWordUsed(id: wordID)
    if store.getWord(id: wordID) != nil {
        store.recordRecentView(id: wordID)
    }
}
```

The `getWord` guard avoids inserting a row for a word that no longer
exists in `words` (foreign-key would fail anyway, but the guard keeps
intent obvious).

This fires for both search-driven navigations and notification-tap
deep-links — both are valid signals of recent interaction.

### 6c. Show recents in the dropdown when focused with empty query

In `MainView.swift`:

1. Add a state for whether the dropdown is currently showing recents
   (purely cosmetic, used for the section header):

   ```swift
   @State private var showingRecents: Bool = false
   ```

2. Refactor the `onChange(of: query)` handler and the
   `onChange(of: searchFieldFocused)` handler into a single helper:

   ```swift
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
           results = store.search(query: trimmed, limit: 15)
           showingRecents = false
       }
   }
   ```

3. Wire the helper:

   ```swift
   TextField("Search (Russian or English)", text: $query)
       .focused($searchFieldFocused)
       …
       .onChange(of: query)              { _, _ in refreshDropdown() }
       .onChange(of: searchFieldFocused) { _, _ in refreshDropdown() }
       .onAppear { refreshDropdown() }
   ```

   Calling `refreshDropdown` on appear is a defensive measure for the
   case where the user returns from Word Detail with the field still
   focused — recents may have changed.

4. Add a tiny header row inside the dropdown when `showingRecents` is
   true so users understand why a list is appearing without typing. Place
   it above the `ForEach`:

   ```swift
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
   ```

5. When the user taps a recent row, the existing handler clears `query`
   and `results`, then pushes Word Detail. That is correct: do **not**
   special-case recents (the same chevron / row shape works fine).

6. The dropdown's existing `if !results.isEmpty` guard already hides the
   dropdown for a focused-but-no-history user.

**Edge cases / non-goals**:
- No "clear recent views" UI in this iteration. The 50-row soft cap and
  the `ON DELETE CASCADE` from `words` are the only bounds.
- No search-history feature — recents are *viewed* words only, not typed
  queries.
- Don't include the currently-displayed Word Detail's own row in the
  recents view: when the user backs out and refocuses the search bar,
  this entry being "most recent" is the desired behaviour.
- If a Word Detail is opened but the user immediately backs out, the
  view still appears in recents (this matches user expectation: "I just
  looked at it").

**Acceptance**:
- Tap the search bar with an empty field → dropdown opens with up to 5
  most-recently-viewed words, newest first, under a "Recently viewed"
  header.
- Type a character → dropdown switches to live search results, header
  disappears.
- Delete back to empty → dropdown switches back to recents (header
  reappears).
- Tap a recent → opens Word Detail; that word is now the top recent on
  the next focus.
- A word never seen still doesn't appear; viewing the same word twice
  doesn't duplicate it.
- Recents survive app relaunch and Settings → Reset already used words
  (resetting "used" must NOT clear recents — they live in a separate
  table).

---

## Cross-cutting acceptance criteria

When the implementation is done, verify by manual QA on Simulator (light
**and** dark):

1. **Keyboard**: focus search → Done in keyboard accessory dismisses; tap
   blank page area dismisses; tap a result row navigates without the
   keyboard hijacking the gesture.
2. **Dark mode (Main only)**: black bg, gray pill search bar with white
   typed letters, white gear, dropdown card matches background. Light
   mode unchanged. Alphabet and Settings unchanged in both modes.
3. **Reset**: Settings → Reset already used words shows a confirmation
   sheet; Cancel is a no-op; Reset clears `used_words`,
   `scheduled_pushes`, and pending iOS notifications.
4. **Phonetic highlight**: Alphabet rows visually emphasise the
   phonetic chunk inside the example word (`ar` in `far`, `ts` in
   `boots`, both `ye`/`e` branches for Е, etc.). Ь / Ъ still show
   "has no sound". Word Detail Letters section matches.
5. **Used toggle**: Word Detail shows a Toggle reflecting `used_words`.
   Flipping ON removes the word from the future pool. Flipping OFF
   cancels any pending push for it and refills the buffer.
6. **Recently viewed**: empty + focused search shows up to 5 recents
   with a header; typing replaces it with live search; navigating to a
   word adds (or refreshes) its slot at the top of the list.

## What you should NOT change
- `project.yml`, `Info.plist`, asset catalog entries.
- The `scheduled_pushes` schema, the `used_words` schema, the
  `WordOfDayScheduler` rolling-buffer algorithm, or the deep-link
  contract from `userInfo["word_id"]`.
- The Alphabet and Settings screens' overall layout (`AlphabetView`,
  `SettingsView` aside from the new confirmation dialog).
- Any seed data in `RussianWordOfDayApp/Resources/words.seed.json`.

After implementing, regenerate the Xcode project if `xcodegen` is your
flow (no `project.yml` change is expected, but it's cheap to confirm) and
build for iOS Simulator (iOS 17 deployment target).
