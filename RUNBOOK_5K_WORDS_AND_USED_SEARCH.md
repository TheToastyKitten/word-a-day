## Runbook: 5,000-word seed + Manage Used Words search

You are an expert iOS / SwiftUI engineer (with light Python tooling). Implement
the following changes on top of the existing iOS app at
`Russian - Word a Day/RussianWordOfDayApp`.

The repo already follows the conventions in `RUNBOOK_DEFER_USED_MARK.md`,
`RUNBOOK_MANAGE_USED_WORDS.md`, `RUNBOOK_FIX_ADD_BACK_PERSISTENCE.md`, and
`RUNBOOK_UX_POLISH_DARK_MODE_RECENTS.md`. Do NOT change scope beyond the items
below. Do NOT introduce new app dependencies (the `requests` Python dep is
build-time only, not shipped).

### Scope (only these items)
1. **Pipeline script** (`scripts/build_seed.py`): a Python 3 build-time tool that consumes a Kaikki / Wiktionary Russian dump plus a CC-BY frequency list and emits a 5,000-entry `words.seed.json`.
2. **Regenerated seed**: run the pipeline once, commit the resulting 5,000-entry `RussianWordOfDayApp/Resources/words.seed.json`, and append the corresponding attributions to `DATA_LICENSES.md`.
3. **Search bar on Manage Used Words**: SwiftUI `.searchable` modifier on `ManageUsedWordsView` with an in-memory ё→е/lowercase filter over the already-loaded entries array.

---

## File touchpoints

| Concern | File(s) |
| --- | --- |
| Build-time pipeline that produces the seed | `scripts/build_seed.py` (new) |
| The 5,000-entry data the app loads at runtime | `RussianWordOfDayApp/Resources/words.seed.json` (regenerated) |
| Source attribution required by the upstream licenses | `DATA_LICENSES.md` |
| Search bar UI + in-memory filter | `RussianWordOfDayApp/Sources/Views/ManageUsedWordsView.swift` |

No edits to `WordStore.swift`, `WordOfDayScheduler.swift`, `Notifications.swift`,
`Models.swift`, `RussianWordOfDayApp.swift`, `project.yml`, or `Info.plist`.
Existing FTS5 schema, triggers, and seeding loop are already correct for 5,000
rows — they just need the data.

---

## 1) `scripts/build_seed.py` — pipeline that builds the seed

**Problem**: there is no tooling to produce a 5,000-entry seed today. The
repo's `scripts/README.md` describes the intended pipeline (Kaikki +
frequency list) but no code exists. We need a single-file Python 3 script
that's reproducible, idempotent, and easy for a casual maintainer to re-run
when the upstream data updates.

**Implementation in `scripts/build_seed.py`** (new file):

1. The script takes two required inputs and writes one output. Inputs are
   local file paths so the script never depends on network access at build
   time. The runbook below also lists the URLs the maintainer should download
   from before running.

2. Required upstream files (download manually, do NOT commit to repo):
   - **Kaikki Russian dump** — `https://kaikki.org/dictionary/Russian/kaikki.org-dictionary-Russian.jsonl` (multi-GB NDJSON, one JSON object per line; CC-BY-SA 4.0 via Wiktionary).
   - **Frequency list** — `https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/ru/ru_50k.txt` (plain text, `lemma count` per line, MIT license).

3. Script body. Place at `scripts/build_seed.py`, make executable
   (`chmod +x scripts/build_seed.py`). Stdlib only — no `pip install` step
   required.

```python
#!/usr/bin/env python3
"""
Build RussianWordOfDayApp/Resources/words.seed.json from a Kaikki Russian
dump and a CC-BY frequency list. Run once per upstream data refresh.

Usage:
    python3 scripts/build_seed.py \
        --kaikki <path-to-kaikki-russian.jsonl> \
        --freq   <path-to-ru_50k.txt> \
        [--limit 5000] \
        [--out RussianWordOfDayApp/Resources/words.seed.json]

The script aborts (non-zero exit) if it can't land at least 4,500 entries —
that's the floor below which we'd ship a noticeably-degraded dictionary.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import unicodedata
from pathlib import Path
from typing import Iterator, Optional

CYRILLIC_RE = re.compile(r"^[\u0400-\u04FF\-]+$")
GLOSS_PARENS_RE = re.compile(r"\s*\([^)]*\)")
MAX_GLOSS_LEN = 40
MAX_MEANING_LEN = 140

TRANSLIT_MAP = {
    "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "yo",
    "ж": "zh", "з": "z", "и": "i", "й": "y", "к": "k", "л": "l", "м": "m",
    "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u",
    "ф": "f", "х": "kh", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "shch",
    "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya",
}


def slugify(russian: str, used: set[str]) -> str:
    base = "".join(TRANSLIT_MAP.get(ch, ch) for ch in russian.lower())
    base = re.sub(r"[^a-z0-9]+", "_", base).strip("_") or "word"
    candidate = base
    n = 2
    while candidate in used:
        candidate = f"{base}_{n}"
        n += 1
    used.add(candidate)
    return candidate


def normalize_lemma(s: str) -> str:
    return unicodedata.normalize("NFC", s.strip().lower()).replace("\u0301", "")


def is_clean_lemma(s: str) -> bool:
    if not s or " " in s or "-" in s and len(s) <= 2:
        return False
    return bool(CYRILLIC_RE.match(s))


def read_frequency(path: Path, limit: int) -> list[str]:
    out: list[str] = []
    seen: set[str] = set()
    with path.open(encoding="utf-8") as f:
        for line in f:
            parts = line.split()
            if not parts:
                continue
            lemma = normalize_lemma(parts[0])
            if not is_clean_lemma(lemma) or lemma in seen:
                continue
            seen.add(lemma)
            out.append(lemma)
            if len(out) >= limit * 3:  # over-fetch; many won't have Kaikki entries
                break
    return out


def stream_kaikki(path: Path, wanted: set[str]) -> Iterator[dict]:
    with path.open(encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            word = obj.get("word")
            if not isinstance(word, str):
                continue
            if normalize_lemma(word) in wanted:
                yield obj


def first_gloss(senses: list, max_len: int) -> Optional[str]:
    for sense in senses or []:
        for gloss in sense.get("glosses", []) or []:
            text = GLOSS_PARENS_RE.sub("", gloss).strip()
            text = re.split(r"[;,]", text, maxsplit=1)[0].strip()
            if not text:
                continue
            if len(text) > max_len:
                text = text[: max_len - 1].rstrip() + "…"
            return text
    return None


def first_ipa(sounds: list) -> Optional[str]:
    for s in sounds or []:
        ipa = s.get("ipa")
        if isinstance(ipa, str) and ipa.strip():
            return ipa.strip().strip("/[]")
    return None


def build_entry(rank: int, lemma: str, kaikki: dict, used_ids: set[str]) -> Optional[dict]:
    russian = kaikki.get("word", lemma)
    senses = kaikki.get("senses") or []
    english = first_gloss(senses, MAX_GLOSS_LEN)
    meaning = first_gloss(senses, MAX_MEANING_LEN)
    if not english:
        return None
    return {
        "id": slugify(russian, used_ids),
        "russian": russian,
        "english": english,
        "meaning_en": meaning if meaning and meaning != english else None,
        "phonetic": first_ipa(kaikki.get("sounds")),
        # `_rank` is dropped before write; used only for sort order.
        "_rank": rank,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--kaikki", required=True, type=Path)
    ap.add_argument("--freq", required=True, type=Path)
    ap.add_argument("--limit", type=int, default=5000)
    ap.add_argument(
        "--out",
        type=Path,
        default=Path("RussianWordOfDayApp/Resources/words.seed.json"),
    )
    ap.add_argument("--min-entries", type=int, default=4500)
    args = ap.parse_args()

    if not args.kaikki.exists():
        print(f"kaikki dump not found: {args.kaikki}", file=sys.stderr)
        return 2
    if not args.freq.exists():
        print(f"frequency list not found: {args.freq}", file=sys.stderr)
        return 2

    print(f"Reading frequency list: {args.freq}")
    freq = read_frequency(args.freq, args.limit)
    rank_by_lemma = {lemma: idx for idx, lemma in enumerate(freq)}
    wanted = set(rank_by_lemma)
    print(f"  ↳ {len(wanted)} candidate lemmas (top {args.limit * 3})")

    print(f"Streaming Kaikki dump: {args.kaikki}")
    matches: dict[str, dict] = {}
    for obj in stream_kaikki(args.kaikki, wanted):
        key = normalize_lemma(obj["word"])
        if key not in matches:  # keep first occurrence per lemma
            matches[key] = obj
    print(f"  ↳ matched {len(matches)} of {len(wanted)} lemmas")

    used_ids: set[str] = set()
    entries: list[dict] = []
    for lemma in freq:  # iterate in frequency order
        kaikki = matches.get(lemma)
        if not kaikki:
            continue
        entry = build_entry(rank_by_lemma[lemma], lemma, kaikki, used_ids)
        if entry is not None:
            entries.append(entry)
        if len(entries) >= args.limit:
            break

    if len(entries) < args.min_entries:
        print(
            f"Only {len(entries)} entries built, below floor of {args.min_entries}.",
            file=sys.stderr,
        )
        return 3

    entries.sort(key=lambda e: e["_rank"])
    for e in entries:
        e.pop("_rank", None)

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(
        json.dumps(entries, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"Wrote {len(entries)} entries → {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

4. **Schema contract**: the script's output is a JSON array of objects with
   exactly the keys `id`, `russian`, `english`, `meaning_en`, `phonetic`.
   Any of `meaning_en` / `phonetic` may be `null` or omitted. This matches
   the existing `SeedWordEntry = WordEntry` decoder in
   `RussianWordOfDayApp/Sources/Models.swift`, which already treats those
   two as optional.

**Acceptance**:
- Running
  `python3 scripts/build_seed.py --kaikki <kaikki.jsonl> --freq <ru_50k.txt>`
  on a developer machine writes
  `RussianWordOfDayApp/Resources/words.seed.json`, exits 0, and prints a
  final line of the form `Wrote 5000 entries → …`.
- Re-running the script produces a byte-identical file (the script is
  deterministic given the same inputs — sort order is by frequency rank,
  ID conflicts resolve via numeric suffix in deterministic order).
- The output file is valid JSON (`python3 -c "import json,sys;json.load(open(sys.argv[1]))" RussianWordOfDayApp/Resources/words.seed.json` exits 0) and every entry has at minimum `id`, `russian`, `english`.

---

## 2) Regenerated `words.seed.json` + `DATA_LICENSES.md`

**Problem**: today's `RussianWordOfDayApp/Resources/words.seed.json` ships
~30 entries (211 lines). The whole point of this runbook is to swap it for
a real 5,000-entry dataset, which also triggers attribution requirements
from the upstream licenses.

**Implementation**:

1. Run the pipeline against freshly-downloaded inputs:
   ```
   curl -L -o /tmp/kaikki-ru.jsonl \
     https://kaikki.org/dictionary/Russian/kaikki.org-dictionary-Russian.jsonl
   curl -L -o /tmp/ru_50k.txt \
     https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/ru/ru_50k.txt
   python3 scripts/build_seed.py --kaikki /tmp/kaikki-ru.jsonl --freq /tmp/ru_50k.txt
   ```
2. Commit the regenerated `RussianWordOfDayApp/Resources/words.seed.json`.
   Do NOT commit `/tmp/kaikki-ru.jsonl` or `/tmp/ru_50k.txt` — they're
   build-time inputs.
3. Replace the body of `Russian - Word a Day/DATA_LICENSES.md` with a
   filled-in version. Keep the existing top section, but the "Planned
   sources" subsection becomes "Bundled sources" with concrete attributions:

```markdown
## Offline dictionary data sources

This app bundles an offline Russian→English dictionary dataset derived from
the open-licensed sources below. The dataset is rebuilt by
`scripts/build_seed.py`; see that script for the exact transform.

### Bundled sources (v1, ~5,000 lemmas)

#### Kaikki / Wiktionary (Russian)
- **Website**: https://kaikki.org/dictionary/Russian/
- **Used for**: Russian lemma forms, English glosses/definitions, IPA phonetics.
- **License**: CC-BY-SA 4.0 (via Wiktionary). Attribution: "Includes
  data from Wiktionary contributors, made available via Kaikki.org."
- **Retrieval**: `kaikki.org-dictionary-Russian.jsonl`, retrieved
  <YYYY-MM-DD when you run the pipeline>.

#### Hermit Dave / FrequencyWords (Russian, 50k)
- **Repository**: https://github.com/hermitdave/FrequencyWords
- **Used for**: top-N frequency ranking that drives lemma selection.
- **License**: MIT. Attribution: "Frequency data: Hermit Dave,
  FrequencyWords (MIT)."
- **Retrieval**: `content/2018/ru/ru_50k.txt`, retrieved
  <YYYY-MM-DD when you run the pipeline>.

### Attribution in-app
The app currently does not surface a "Data sources" screen. The
attributions above satisfy the redistribution requirements at the
repository level. A dedicated About screen is tracked as a follow-up and
not in scope for this runbook.
```

The retrieval-date placeholders MUST be filled in to the date the
maintainer actually downloaded the inputs. No `<YYYY-MM-DD>` literals
should remain in the committed file.

**Acceptance**:
- `wc -l RussianWordOfDayApp/Resources/words.seed.json` returns at least
  20,000 lines (≈4 lines per entry × 5,000 entries with `indent=2`).
- A spot-check of three random entries (e.g. `и`, `быть`, `дом`) shows
  they have non-empty `russian`, `english`, and at least one of
  `meaning_en` / `phonetic`.
- `DATA_LICENSES.md` no longer contains the string "TBD" and lists both
  Kaikki and FrequencyWords with retrieval dates.
- The iOS app builds and launches with the new seed: cold-launch the
  simulator, watch the console — `WordStore.ensureSeededIfNeeded()`
  should not log any errors and `isReady` becomes `true`.

---

## 3) Search bar on `ManageUsedWordsView`

**Problem**: with `usedWords(limit: 5_000)` returning potentially thousands
of rows after extended use, the existing `List` is unscannable. The user
can't jump to a specific word without scrolling.

**Implementation in `RussianWordOfDayApp/Sources/Views/ManageUsedWordsView.swift`**:

1. Add a `query` state and a normalization helper. Use the same `lowercased()
   + ё→е` rule the dictionary's FTS path uses, so search behaviour is
   consistent across the app.

```swift
struct ManageUsedWordsView: View {
    @EnvironmentObject private var store: WordStore
    @EnvironmentObject private var settings: AppSettings
    @State private var entries: [UsedWord] = []
    @State private var pendingIDs: Set<String> = []
    @State private var hasLoaded: Bool = false
    @State private var query: String = ""
```

2. Add a computed `filteredEntries`. Empty / whitespace-only query returns
   the full list unchanged so there's zero overhead when the search field
   isn't engaged.

```swift
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
```

3. Rewrite `body` so the searchable modifier is attached and the
   list/empty-states reflect the filter. The `List` keeps the existing
   row + `Add back` behaviour unchanged — only the source array and the
   empty branches are different.

```swift
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
```

4. Leave `row(for:)`, `addBackButton(for:)`, and `addBack(_:)` exactly as
   they are. The `Add back` flow already mutates `entries` (the source
   array), and `filteredEntries` is computed off that, so a removal is
   reflected in the filtered view automatically.

**Acceptance**:
- Open Manage Used Words on a populated DB. A search field is visible at
  the top of the list (drawer style, always present) with placeholder
  "Search used words".
- Type three Cyrillic characters (e.g. `при`). The list filters to rows
  whose Russian or English contains those characters, case-insensitively.
- Type `ежик` while a row exists with russian `ёжик`. The row IS shown
  (ё→е equivalence verified).
- Clear the search field. The full list returns instantly, in the same
  order as before.
- Type a query that matches nothing. The list area shows the system
  `ContentUnavailableView.search(text:)` view, NOT the "No used words yet"
  empty-state.
- Tap `Add back` on a filtered row. The row disappears from both
  `entries` and the filtered list. The search query stays put.
- Footer reads `"N used words"` when query is empty and
  `"M of N matches"` when a query is active.

---

## Cross-cutting acceptance criteria

When done, verify on Simulator (light **and** dark — the new search field
must read in both):

1. **Cold-launch seed time**: install the rebuilt app on a clean
   simulator. Time the duration of `WordStore.ensureSeededIfNeeded()` by
   wrapping the call site in `RussianWordOfDayApp.swift` with a
   `Date()` diff in a temporary `print(...)` (revert before commit).
   The duration MUST be under 3 seconds. If it is greater, the runbook
   is NOT done — escalate to the user with the measured time and stop.
   Recommended follow-up if the budget is exceeded: bundle a prebuilt
   `words.sqlite` instead of seeding at runtime. That follow-up is OUT
   of scope for this runbook.
2. **Main search latency**: with the 5,000-entry seed, type `при` in the
   `MainView` search field. Results appear within one frame (informal —
   no perceptible lag). FTS5 over 5,000 rows is ms-level; if anything
   feels slow, capture an Instruments trace before claiming done.
3. **Manage Used Words scroll perf**: simulate a heavy `used_words`
   table by temporarily inserting 5,000 rows (e.g. via a debug-only
   button in `SettingsView` or a one-shot SQL `INSERT INTO used_words
   SELECT id, strftime('%s','now') FROM words LIMIT 5000;` from the
   simulator's app sandbox). Open Manage Used Words. The list scrolls
   smoothly at 60 fps; tapping into the search field, typing four
   characters, and clearing it again all complete with no visible jank.
   Remove the test rows before committing.
4. **ё→е equivalence**: with at least one used word whose Russian
   contains `ё` (e.g. `всё`), typing `все` matches it.
5. **Empty-state branches**: with `used_words` empty, the existing
   `ContentUnavailableView("No used words yet", …)` is shown. With
   `used_words` populated but the query matching zero rows, the system
   `ContentUnavailableView.search(text:)` is shown.
6. **Light/dark parity**: take simulator screenshots in both
   appearances per the implement-runbook protocol. The search field
   uses the system search-bar styling and looks correct in both.
7. **Schedule still applies cleanly**: tap `Apply notification schedule`
   in Settings with the 5,000-entry seed. The buffer fills 60 pushes;
   `Manage already used words` remains empty (regression check on the
   defer-used-mark behaviour from the prior runbook).

## What you should NOT change

- `RussianWordOfDayApp/Sources/WordStore.swift` — no schema, no new
  query methods. The existing `seedIfNeeded()` already handles 5,000
  rows in a single transaction, and the existing FTS5 setup is
  sufficient for the main search bar.
- `RussianWordOfDayApp/Sources/WordOfDayScheduler.swift`,
  `Notifications.swift`, `AppDelegate.swift`, `AppRouter.swift`,
  `Models.swift`, `RussianWordOfDayApp.swift`, `MainView.swift`,
  `SettingsView.swift`, `WordDetailView.swift`, `AlphabetView.swift`,
  `RootView.swift`, `CyrillicAlphabet.swift`, `AppSettings.swift` —
  unchanged.
- `project.yml`, `Info.plist`, `Assets.xcassets/*` — unchanged.
- Existing seed entries that are still in the new file (e.g. `привет`,
  `спасибо`) are produced by the same pipeline; do NOT hand-merge or
  hand-edit `words.seed.json` after running the script.
- Do NOT commit the raw upstream files (`kaikki.jsonl`, `ru_50k.txt`).
  They go in `/tmp` or any scratch location of the maintainer's choice.
- The `bufferTarget = 60` constant. The defer-used-mark architecture is
  unaffected by the larger word pool.
- The `Add back` row-action behaviour. The search bar must coexist with
  it; do not remove or restyle the button.
