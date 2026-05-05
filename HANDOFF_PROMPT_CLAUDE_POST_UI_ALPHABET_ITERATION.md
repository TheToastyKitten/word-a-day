## Runbook + copy/paste prompt for Claude (Post UI_ALPHABET iteration)

Claude has already completed the **UI_ALPHABET** runbook. This runbook is a **new iteration** based on the follow-up changes below and should be implemented on top of the current codebase.

### Scope (only these items)
1. **Alphabet page enhancement**: show an English “sound hint” example word next to each letter’s pronunciation name (e.g. **В → vodka**, **Ц → cats**). Letters without sound should be annotated **“no sound”** (e.g. **Ь**, **Ъ**).
2. **Main page top bar**: move the Alphabet icon so it appears **next to the cogwheel** (same top-right control cluster), not at the far top-left.
3. **Fix repeating push words**: the push notifications are repeating the same word (e.g. “thank you”) and are not removing used words from the pool. Ensure each push uses a **unique** unused word until reset.

---

## Why the push word repeats (important iOS constraint)

If the app uses `UNCalendarNotificationTrigger(... repeats: true)`, the **notification content does not change** each day. That will repeat the same word forever, even if the database marks words used correctly.

**Fix**: schedule **non-repeating** local notifications ahead of time, each with its own chosen unused `word_id`.

---

## Implementation decisions (locked)
- **Rolling buffer**: maintain a rolling queue of **60 upcoming pushes** (not “60 days”). This supports multiple pushes/day:
  - 1/day → ~60 days of coverage
  - 3/day → ~20 days of coverage
  - 5/day → ~12 days of coverage
- **Uniqueness**: each scheduled push must choose a word that is not already present in `used_words` (or equivalent “used” flag/table).
- **Persistence**: store scheduled pushes in SQLite so rescheduling / app restarts don’t reshuffle or repeat unexpectedly.
- **Deep-link**: every notification must include `userInfo["word_id"]` and tapping opens that Word Detail screen.

---

## Step-by-step tasks

### 1) Alphabet sound hints + no-sound labels
- Update the alphabet source-of-truth to include:
  - `soundHintEnWord: String?` (hardcoded English example word)
  - `soundNote: String?` for no-sound letters (set to `"no sound"` for Ь and Ъ)
- Update Alphabet UI row to show:
  - Pronunciation name (existing)
  - Second line: `Sound hint: <word>` OR `no sound`

### 2) Main top bar icon placement
- Update the main top bar layout so Alphabet icon is adjacent to the settings cogwheel.
- Keep the same navigation behavior: Alphabet icon routes to Alphabet screen.

### 3) Rolling non-repeating push scheduler (60 pushes)
Replace any repeating daily triggers with a rolling non-repeating schedule.

#### Data model (SQLite)
Add a table to persist scheduled pushes, e.g.:
- `scheduled_pushes`:
  - `id TEXT PRIMARY KEY` (notification request identifier)
  - `fire_at INTEGER NOT NULL` (unix time)
  - `slot INTEGER NOT NULL` (index within day based on user’s configured times)
  - `word_id TEXT NOT NULL`
  - `created_at INTEGER NOT NULL`

Keep using `used_words(word_id, used_at)` (or equivalent) as the “used flag” for pushes.

#### Scheduling algorithm
- Inputs: `pushCountPerDay`, `pushTimes[]` (times of day), and “now”.
- Compute the next chronological fire times for upcoming pushes.
- Query how many future scheduled pushes exist (fire_at > now) for this app.
- While future count < 60:
  - Pick next fire time (chronological)
  - Select a random unused word (`used_words` does not contain it)
  - Mark it used (insert into `used_words`)
  - Insert into `scheduled_pushes`
  - Schedule a **non-repeating** `UNCalendarNotificationTrigger(dateMatching: ..., repeats: false)`

#### Top-up triggers
Run “top-up to 60 pushes”:
- on app launch
- on app entering foreground
- after user changes notification settings (push count/times)

#### When settings change
- If user changes times or pushes/day:
  - Remove pending scheduled notifications for future pushes that were created by the scheduler (use a request-id prefix like `push_`).
  - Keep `scheduled_pushes` consistent with what is pending.
  - Rebuild the next N pushes to restore the buffer to 60, without reusing words already in `used_words`.

#### Reset behavior
- “Reset used words” should clear:
  - `used_words`
  - `scheduled_pushes`
  - and remove pending notification requests

---

## Acceptance criteria
- Alphabet page shows letter name pronunciation plus:
  - **Sound hint** example word for letters with sound
  - **“no sound”** for Ь and Ъ
- Main page top bar shows Alphabet icon **next to** the cogwheel.
- Push notifications:
  - do not repeat the same word on subsequent pushes
  - maintain a rolling buffer of **60 upcoming pushes**
  - work with multiple pushes/day; each push in a day uses a unique word
  - deep-link correctly to the Word Detail screen using `word_id`

