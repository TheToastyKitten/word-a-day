## Runbook + copy/paste prompt for Claude (Alphabet PDF + used-words + polish)

Claude has already run the prior runbooks. This runbook is a **new iteration** on top of the current codebase at:
`/Users/zackerymiller/Projects/Russian - Word a Day`

### Scope (only these items)
1. **Alphabet data update**: Replace the current “name of letter” and “similar English sound” values with the exact values from:
   - `@/Users/zackerymiller/Downloads/Russian Alphabet with Sound and Handwriting.pdf`
2. **App home-screen display name**: Change to **Word a Day**.
3. **Seed database expansion (for dropdown testing)**: Add ~25 extra words to the bundled seed so that searching by the first few English letters shows multiple dropdown matches.
4. **Top bar icon layout**: Move Alphabet icon closer to the cog icon (halve current gap) and make both icons the **same height**.
5. **Used-words + push selection redesign**: Move away from any “pre-designated list” behavior so that each push randomly selects from the entire pool of unused words at push-scheduling time, and so we can later build a “Used words” page with selective re-add.

---

## 1) Alphabet data update from the PDF

The PDF includes a table with columns: **Name of Letter** and **Similar English Sound**.

Update the alphabet source-of-truth so the app shows:
- **Name of letter** (from the PDF) instead of the current `nameEn`.
- **Similar English sound** (from the PDF) instead of the current “sound hint word” list.
- For signs, show “has no sound” (PDF wording).

### Values (from the PDF)
Use these exact strings (case/spacing can be normalized, but keep the meaning intact):

- А а — Name: `a` — Similar: `like ar in far`
- Б б — Name: `be` — Similar: `like b in box`
- В в — Name: `ve` — Similar: `like v in voice`
- Г г — Name: `ge` — Similar: `like g in go`
- Д д — Name: `de` — Similar: `like d in day`
- Е е — Name: `ye` — Similar: `like ye in yet or e in exit`
- Ё ё — Name: `yo` — Similar: `like yo in your`
- Ж ж — Name: `zhe` — Similar: `like s in pleasure`
- З з — Name: `ze` — Similar: `like z in zoo`
- И и — Name: `ee` — Similar: `like ee in meet`
- Й й — Name: `ee kratkoye (short i)` — Similar: `like y in boy`
- К к — Name: `ka` — Similar: `like k in key or c in cat`
- Л л — Name: `el` — Similar: `like l in lamp`
- М м — Name: `em` — Similar: `like m in man`
- Н н — Name: `en` — Similar: `like n in note`
- О о — Name: `o` — Similar: `like o in not`
- П п — Name: `pe` — Similar: `like p in pet`
- Р р — Name: `er` — Similar: `like r in rock (but rolled)`
- С с — Name: `es` — Similar: `like s in sun`
- Т т — Name: `te` — Similar: `like t in table`
- У у — Name: `oo` — Similar: `like oo in moon`
- Ф ф — Name: `ef` — Similar: `like f in food`
- Х х — Name: `kha` — Similar: `like ch in Scottish loch`
- Ц ц — Name: `tse` — Similar: `like ts in boots`
- Ч ч — Name: `che` — Similar: `like ch in chat`
- Ш ш — Name: `sha` — Similar: `like sh in short`
- Щ щ — Name: `shcha` — Similar: `like sh_ch in fresh_cheese`
- Ъ  — Name: `tviordiy znak (hard sign)` — Similar: `has no sound`
- Ы  — Name: `ih*` — Similar: `like i in ill`
- Ь  — Name: `myagkiy znak (soft sign)` — Similar: `has no sound`
- Э э — Name: `e` — Similar: `like e in end`
- Ю ю — Name: `yoo` — Similar: `like u in use`
- Я я — Name: `ya` — Similar: `like ya in yard`

### UI changes for AlphabetView
- Each row should show:
  - The letter (upper + lower)
  - The **Name of letter**
  - The **Similar English sound** line (or “has no sound”)

### Word detail “Letters” section
- Update the per-word letters/pronunciation section to use the new fields:
  - show Name + Similar sound (or no sound)

---

## 2) Change home-screen display name

Update XcodeGen config:
- In `project.yml`, set:
  - `CFBundleDisplayName: "Word a Day"`

Regenerate the project if needed:
- `xcodegen generate`

---

## 3) Add ~25 extra seed words (dropdown testing)

Goal: while typing the first few letters in **English**, the dropdown should show multiple results (e.g., typing `app` shows `apple`, `apply`, `appointment`, etc.).

Add about 25 more entries to:
- `RussianWordOfDayApp/Resources/words.seed.json`

Suggested English prefix clusters (pick any that feel natural):
- `app...`: `apple`, `apply`, `application`, `appointment`
- `ban...`: `banana`, `bank`, `band`, `banner`
- `car...`: `car`, `card`, `care`, `carry`
- `cat...`: `cat`, `catch`, `cater`, `category`
- `st...`: `star`, `start`, `state`, `station`

Each new entry must include required fields:
- `id`, `russian`, `english`, `meaning_en`, `phonetic`

Russian can be simple/approximate for test data (this is for UI dropdown behavior), but keep it valid Cyrillic.

---

## 4) Top bar icon spacing + size

In `RussianWordOfDayApp/Sources/Views/MainView.swift`:
- Alphabet icon should be closer to the cog icon:
  - halve the current gap between the two buttons (reduce `HStack(spacing:)` and/or per-button padding).
- Ensure both icons have the **same height**:
  - Make the gear icon match the Alphabet icon’s rendered height (or vice-versa).

---

## 5) Used words redesign (Claude to decide details)

Current behavior to avoid:
- Any approach where a “pre-designated list” causes words to be treated as used merely by being scheduled/added to a list in a way that blocks flexible reuse.

Target behavior:
- Each push must select a random word from the **entire pool of unused words** at the moment the push is scheduled.
- The app must track which words have been used so far so we can build a future screen:
  - “Used words” list with timestamps
  - Ability to selectively re-add a word to the pool (mark as unused again)

Important constraint:
- iOS local notifications cannot “pick a random word at fire time” without a server; the word must be chosen before scheduling the `UNNotificationRequest`.
  - Therefore the implementation should schedule one-shot notifications ahead of time, but the persistence model should support a future UI to un-use a word (and to repair the schedule accordingly).

Implementation guidance (non-prescriptive):
- Keep a `used_words` table as the truth of what was used.
- Keep a `scheduled_pushes` table for pending pushes that maps `fire_at -> word_id -> request_id`.
- When a word is “re-added” (un-used), remove it from `used_words` and also cancel any pending pushes that still reference it (or keep them, depending on UX), then top-up the rolling buffer.

---

## Acceptance criteria
- Alphabet page and per-word Letters section show values from the PDF (Name of letter + Similar English sound), including “has no sound” for Ь and Ъ.
- Home screen app name is **Word a Day**.
- Search dropdown can show multiple matches for shared English prefixes thanks to added seed words.
- Alphabet and cog icons are closer together (about half the previous gap) and the same height.
- Push scheduling selects words from unused pool and persists “used words” in a way compatible with a future “Used words” page and selective re-add.

