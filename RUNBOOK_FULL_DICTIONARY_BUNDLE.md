## Runbook: Bundle full ~150k Russian dictionary, scope pushes to common subset

You are an expert iOS / SwiftUI engineer (with light Python tooling). Implement
the following changes on top of the existing iOS app at
`Russian - Word a Day/RussianWordOfDayApp`.

The repo follows the conventions in `RUNBOOK_DEFER_USED_MARK.md`,
`RUNBOOK_MANAGE_USED_WORDS.md`, `RUNBOOK_FIX_ADD_BACK_PERSISTENCE.md`, and
`RUNBOOK_UX_POLISH_DARK_MODE_RECENTS.md`.

**Supersedes** Sections 1 and 2 of `RUNBOOK_5K_WORDS_AND_USED_SEARCH.md`
(the JSON `build_seed.py` pipeline and the JSON `words.seed.json` artifact).
Section 3 of that runbook (`.searchable` on Manage Used Words) is independent
and remains valid; if it isn't yet implemented, do it as part of this runbook
or leave it for a follow-up — but DO NOT undo it if it is already in place.

Do NOT change scope beyond the items below. Do NOT introduce new app
dependencies (the Python tooling is build-time only).

### Scope (only these items)
1. **Pipeline** (`scripts/build_seed_db.py`): a Python 3 build-time tool that consumes a Kaikki Russian dump plus a CC-BY frequency list and emits a fully-populated `dictionary.sqlite` containing every Russian lemma (~150k) with an `is_common` flag set on the top 5,000.
2. **Bundled artifact**: `RussianWordOfDayApp/Resources/dictionary.sqlite` is added to the app bundle. The legacy `words.seed.json` is removed. `project.yml` swaps the resource entry; the runbook explicitly authorizes this `project.yml` edit (workspace rule otherwise forbids it).
3. **WordStore install/migrate**: replace runtime JSON seeding with a "copy bundled DB on fresh install / ATTACH-and-replace dictionary tables on upgrade" flow, gated by a new `dictionary_version` table.
4. **Push-pool isolation**: `pickRandomUnusedLocked` and `remainingUnusedCount` filter on `is_common = 1`. The main search (`WordStore.search`) still reads the full table.
5. **`DATA_LICENSES.md`**: filled in with concrete attributions for Kaikki/Wiktionary (CC-BY-SA 4.0) and Hermit Dave / FrequencyWords (MIT), plus a note that the bundled artifact is `dictionary.sqlite`.

---

## File touchpoints

| Concern | File(s) |
| --- | --- |
| Build-time pipeline | `scripts/build_seed_db.py` (new) |
| Dictionary asset bundled into the app | `RussianWordOfDayApp/Resources/dictionary.sqlite` (new, generated) |
| Legacy JSON seed | `RussianWordOfDayApp/Resources/words.seed.json` (delete) |
| Legacy JSON pipeline if present | `scripts/build_seed.py` (delete only if it exists) |
| Bundle wiring | `project.yml` |
| Install / migrate / push-pool filter | `RussianWordOfDayApp/Sources/WordStore.swift` |
| Source attribution | `DATA_LICENSES.md` |

No edits to `WordOfDayScheduler.swift`, `Notifications.swift`,
`AppDelegate.swift`, `AppRouter.swift`, `Models.swift`, `AppSettings.swift`,
`RussianWordOfDayApp.swift`, `Info.plist`, or any view file.

---

## 1) `scripts/build_seed_db.py` — pipeline that builds the bundled SQLite

**Problem**: there is no tooling to produce a multi-tier dictionary. We need
one Python 3 file that, given a Kaikki Russian NDJSON dump and a CC-BY
frequency list, writes a finished `dictionary.sqlite` with every Russian
lemma indexed, the top 5,000 flagged as common, and FTS5 already populated
so the app does no seeding work at runtime.

**Implementation in `scripts/build_seed_db.py`** (new file):

1. Make the script executable (`chmod +x scripts/build_seed_db.py`). Stdlib
   only — Python's bundled `sqlite3` is sufficient and includes FTS5.

2. Required upstream files (download manually, do NOT commit to the repo):
   - **Kaikki Russian dump** — `https://kaikki.org/dictionary/Russian/kaikki.org-dictionary-Russian.jsonl` (multi-GB NDJSON; CC-BY-SA 4.0 via Wiktionary).
   - **Frequency list** — `https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/ru/ru_50k.txt` (plain text, MIT).

3. Script body — drop in as-is:

```python
#!/usr/bin/env python3
"""
Build RussianWordOfDayApp/Resources/dictionary.sqlite from a Kaikki Russian
dump and a CC-BY frequency list. Bundled with the app and copied into the
user's sandbox on first launch by WordStore.installBundledDictionaryIfMissing().

Usage:
    python3 scripts/build_seed_db.py \
        --kaikki <path-to-kaikki-russian.jsonl> \
        --freq   <path-to-ru_50k.txt> \
        [--common-limit 5000] \
        [--out RussianWordOfDayApp/Resources/dictionary.sqlite]

Aborts non-zero if fewer than 80,000 entries land — that's the floor below
which we'd ship a noticeably-thin dictionary that doesn't justify the
prebuilt-DB cost.
"""
from __future__ import annotations

import argparse
import json
import re
import sqlite3
import sys
import unicodedata
from pathlib import Path
from typing import Iterator, Optional

CYRILLIC_RE = re.compile(r"^[\u0400-\u04FF\-]+$")
GLOSS_PARENS_RE = re.compile(r"\s*\([^)]*\)")
MAX_GLOSS_LEN = 60
MAX_MEANING_LEN = 200
DICTIONARY_VERSION = 2
MIN_ENTRIES = 80_000

TRANSLIT_MAP = {
    "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "yo",
    "ж": "zh", "з": "z", "и": "i", "й": "y", "к": "k", "л": "l", "м": "m",
    "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u",
    "ф": "f", "х": "kh", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "shch",
    "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya",
}

SCHEMA_SQL = """
CREATE TABLE words(
  id         TEXT PRIMARY KEY,
  ru         TEXT NOT NULL,
  en         TEXT NOT NULL,
  meaning_en TEXT,
  phonetic   TEXT,
  ru_norm    TEXT NOT NULL DEFAULT '',
  en_norm    TEXT NOT NULL DEFAULT '',
  is_common  INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_words_is_common ON words(is_common) WHERE is_common = 1;

CREATE VIRTUAL TABLE words_fts USING fts5(
  id UNINDEXED,
  ru,
  en,
  tokenize = 'unicode61'
);

CREATE TABLE dictionary_version(value INTEGER NOT NULL);
"""


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


def normalize_for_index(s: str) -> str:
    return normalize_lemma(s).replace("ё", "е")


def is_clean_lemma(s: str) -> bool:
    if not s or " " in s:
        return False
    return bool(CYRILLIC_RE.match(s))


def read_frequency(path: Path) -> list[str]:
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
    return out


def stream_kaikki(path: Path) -> Iterator[dict]:
    with path.open(encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


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


def build(args: argparse.Namespace) -> int:
    print(f"Reading frequency list: {args.freq}")
    freq = read_frequency(args.freq)
    common_set = set(freq[: args.common_limit])
    print(f"  ↳ {len(freq)} ranked lemmas; top {len(common_set)} flagged common")

    print(f"Streaming Kaikki dump: {args.kaikki}")
    used_ids: set[str] = set()
    rows: list[tuple] = []
    seen_lemmas: set[str] = set()

    for obj in stream_kaikki(args.kaikki):
        word = obj.get("word")
        if not isinstance(word, str):
            continue
        lemma = normalize_lemma(word)
        if not is_clean_lemma(lemma) or lemma in seen_lemmas:
            continue
        senses = obj.get("senses") or []
        english = first_gloss(senses, MAX_GLOSS_LEN)
        if not english:
            continue
        meaning = first_gloss(senses, MAX_MEANING_LEN)
        meaning = meaning if meaning and meaning != english else None
        ipa = first_ipa(obj.get("sounds"))
        seen_lemmas.add(lemma)
        rows.append((
            slugify(word, used_ids),
            word,
            english,
            meaning,
            ipa,
            normalize_for_index(word),
            normalize_for_index(english),
            1 if lemma in common_set else 0,
        ))

    print(f"  ↳ built {len(rows)} entries; "
          f"{sum(1 for r in rows if r[7] == 1)} marked common")

    if len(rows) < MIN_ENTRIES:
        print(
            f"Only {len(rows)} entries built, below floor of {MIN_ENTRIES}.",
            file=sys.stderr,
        )
        return 3

    out_path: Path = args.out
    out_path.parent.mkdir(parents=True, exist_ok=True)
    if out_path.exists():
        out_path.unlink()

    print(f"Writing SQLite: {out_path}")
    conn = sqlite3.connect(out_path)
    try:
        conn.executescript(
            "PRAGMA synchronous=OFF;"
            "PRAGMA journal_mode=MEMORY;"
            "PRAGMA temp_store=MEMORY;"
        )
        conn.executescript(SCHEMA_SQL)
        conn.execute(
            "INSERT INTO dictionary_version(value) VALUES (?)",
            (DICTIONARY_VERSION,),
        )
        conn.execute("BEGIN")
        conn.executemany(
            "INSERT INTO words(id, ru, en, meaning_en, phonetic, "
            "ru_norm, en_norm, is_common) VALUES (?,?,?,?,?,?,?,?)",
            rows,
        )
        conn.executemany(
            "INSERT INTO words_fts(id, ru, en) VALUES (?, ?, ?)",
            ((r[0], r[5], r[6]) for r in rows),
        )
        conn.execute("COMMIT")
        conn.executescript("PRAGMA optimize;")
        conn.execute("VACUUM")
    finally:
        conn.close()

    size_mb = out_path.stat().st_size / (1024 * 1024)
    print(f"Done. {len(rows)} entries, {size_mb:.1f} MB.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--kaikki", required=True, type=Path)
    ap.add_argument("--freq", required=True, type=Path)
    ap.add_argument("--common-limit", type=int, default=5000)
    ap.add_argument(
        "--out",
        type=Path,
        default=Path("RussianWordOfDayApp/Resources/dictionary.sqlite"),
    )
    args = ap.parse_args()

    if not args.kaikki.exists():
        print(f"kaikki dump not found: {args.kaikki}", file=sys.stderr)
        return 2
    if not args.freq.exists():
        print(f"frequency list not found: {args.freq}", file=sys.stderr)
        return 2
    return build(args)


if __name__ == "__main__":
    sys.exit(main())
```

4. Run the pipeline once. Commands documented for the maintainer:

```
curl -L -o /tmp/kaikki-ru.jsonl \
  https://kaikki.org/dictionary/Russian/kaikki.org-dictionary-Russian.jsonl
curl -L -o /tmp/ru_50k.txt \
  https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/ru/ru_50k.txt
python3 scripts/build_seed_db.py \
  --kaikki /tmp/kaikki-ru.jsonl \
  --freq   /tmp/ru_50k.txt
```

Commit the resulting `RussianWordOfDayApp/Resources/dictionary.sqlite`.
Do NOT commit the `/tmp/*` inputs.

**Acceptance**:
- Script exits 0 and prints `Done. N entries, M.M MB.` with `N >= 80_000` and `M.M` between roughly 15 and 60.
- `sqlite3 RussianWordOfDayApp/Resources/dictionary.sqlite "SELECT COUNT(*) FROM words;"` returns the same N.
- `sqlite3 ... "SELECT COUNT(*) FROM words WHERE is_common = 1;"` returns 5000 (or `--common-limit` if changed).
- `sqlite3 ... "SELECT COUNT(*) FROM words_fts WHERE words_fts MATCH 'прив*';"` returns at least 1.
- `sqlite3 ... "SELECT value FROM dictionary_version;"` returns 2.

---

## 2) Schema column on `words` and bundle wiring

**Problem**: the existing `words` table has no concept of "is this a
teaching-quality common lemma vs. an obscure long-tail entry". We need the
column both inside the bundled DB (created by Section 1) and inside
`createSchemaIfNeeded()` so the Swift schema definition matches the bundled
artifact.

**Implementation**:

1. In `RussianWordOfDayApp/Sources/WordStore.swift`, modify the `words`
   `CREATE TABLE IF NOT EXISTS` inside `createSchemaIfNeeded()` to include
   the new column:

```swift
try exec("""
CREATE TABLE IF NOT EXISTS words(
  id         TEXT PRIMARY KEY,
  ru         TEXT NOT NULL,
  en         TEXT NOT NULL,
  meaning_en TEXT,
  phonetic   TEXT,
  ru_norm    TEXT NOT NULL DEFAULT '',
  en_norm    TEXT NOT NULL DEFAULT '',
  is_common  INTEGER NOT NULL DEFAULT 0
);
""")
```

The `IF NOT EXISTS` semantics mean upgrading users keep their existing
table shape until the migration in Section 3 drops and recreates it. This
edit only matters as the source of truth for the schema.

2. In `RussianWordOfDayApp/Sources/WordStore.swift`, replace the constant
   `seedResourceName = "words.seed"` with:

```swift
private let bundledDictionaryName = "dictionary"
private let bundledDictionaryExtension = "sqlite"
```

3. Edit `Russian - Word a Day/project.yml` (this runbook explicitly
   authorizes this normally-locked file):

```yaml
    sources:
      - path: RussianWordOfDayApp/Sources
      - path: RussianWordOfDayApp/Resources/dictionary.sqlite
        buildPhase: resources
      - path: RussianWordOfDayApp/Resources/Assets.xcassets
        buildPhase: resources
```

4. Delete `RussianWordOfDayApp/Resources/words.seed.json` from disk.

5. If `scripts/build_seed.py` exists (from a prior implementation of
   `RUNBOOK_5K_WORDS_AND_USED_SEARCH.md`), delete it — it's superseded by
   `scripts/build_seed_db.py`.

6. Regenerate the Xcode project: `cd "Russian - Word a Day" && xcodegen generate`.

**Acceptance**:
- `RussianWordOfDayApp/Resources/dictionary.sqlite` is present in the
  generated `RussianWordOfDay.xcodeproj` Resources build phase; built
  `.app` bundle contains it (verifiable in DerivedData).
- `RussianWordOfDayApp/Resources/words.seed.json` is gone and not listed
  in `project.yml`.
- A grep for `seedResourceName` in `WordStore.swift` returns no results.

---

## 3) Bundle copy + migration in `WordStore`

**Problem**: today's `ensureSeededIfNeeded()` runs `seedIfNeeded()`, which
parses JSON and runs ~30k SQLite calls inside one transaction. That's
fine for 5k rows but unworkable at 150k. We need to install the bundled
SQLite directly: copy the file on a fresh install (free), or
ATTACH-and-replace the dictionary tables on an existing install (single
transaction, zero per-row Swift work). User-state tables
(`used_words`, `scheduled_pushes`, `recent_views`) must survive the
upgrade.

**Implementation in `RussianWordOfDayApp/Sources/WordStore.swift`**:

1. Replace `ensureSeededIfNeeded()` with the install + migrate + schema
   sequence. The order matters: install copies the bundled file BEFORE
   we open the DB for the first time, so a brand-new install never
   touches an empty DB.

```swift
func ensureSeededIfNeeded() async {
    do {
        try installBundledDictionaryIfMissing()
        try openOrCreateDatabase()
        try migrateBundledDictionaryIfNeeded()
        try createSchemaIfNeeded()
        isReady = true
    } catch {
        isReady = false
    }
}
```

2. Add `installBundledDictionaryIfMissing()`. On a fresh install (no
   `words.sqlite` in App Support) this is a single file copy and the
   migration step in `migrateBundledDictionaryIfNeeded()` becomes a no-op
   (the bundled DB already stamps `dictionary_version = 2`). On a user
   who already has a populated DB, this is a no-op and the migration runs
   instead.

```swift
private func installBundledDictionaryIfMissing() throws {
    let url = try databaseURL()
    let fm = FileManager.default
    if fm.fileExists(atPath: url.path) {
        return
    }
    guard let bundled = Bundle.main.url(
        forResource: bundledDictionaryName,
        withExtension: bundledDictionaryExtension
    ) else {
        // Allowed (dev builds may run without the asset). The migration
        // step will then leave the user with an empty `words` table.
        return
    }
    try fm.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try fm.copyItem(at: bundled, to: url)
}
```

3. Add `migrateBundledDictionaryIfNeeded()`. Reads the user's
   `dictionary_version`; if the table is missing or the value is older
   than what the bundled DB ships with (`2`), runs the swap. Foreign keys
   are turned off for the duration so the `DROP TABLE words` doesn't
   cascade into `used_words` / `scheduled_pushes` / `recent_views`. The
   per-row CASCADE behaviour we DO want — when copying back from the
   bundled DB, rows in `used_words` whose `word_id` no longer exists in
   the new `words` table should disappear — is achieved by re-enabling
   foreign keys and running an explicit cleanup at the end.

```swift
private func migrateBundledDictionaryIfNeeded() throws {
    guard let db else { return }

    let currentVersion = readDictionaryVersion()
    let targetVersion: Int = 2
    if currentVersion >= targetVersion {
        return
    }

    guard let bundled = Bundle.main.url(
        forResource: bundledDictionaryName,
        withExtension: bundledDictionaryExtension
    ) else {
        // No bundled DB available (dev). Leave existing data alone.
        return
    }

    // Foreign keys must be off across the table swap or DROP TABLE words
    // will cascade-delete every row in used_words / scheduled_pushes /
    // recent_views. We turn them back on (and clean up dangling refs)
    // after the swap completes.
    _ = sqlite3_exec(db, "PRAGMA foreign_keys=OFF;", nil, nil, nil)
    defer {
        _ = sqlite3_exec(db, "PRAGMA foreign_keys=ON;", nil, nil, nil)
    }

    let attachSQL = "ATTACH DATABASE ? AS bundled;"
    var attachStmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, attachSQL, -1, &attachStmt, nil) == SQLITE_OK else {
        throw NSError(domain: "WordStore", code: 10, userInfo: [
            NSLocalizedDescriptionKey: "ATTACH prepare failed"
        ])
    }
    sqlite3_bind_text(attachStmt, 1, bundled.path, -1, SQLITE_TRANSIENT_SWIFT)
    let attachRC = sqlite3_step(attachStmt)
    sqlite3_finalize(attachStmt)
    guard attachRC == SQLITE_DONE else {
        throw NSError(domain: "WordStore", code: 11, userInfo: [
            NSLocalizedDescriptionKey: "ATTACH bundled DB failed"
        ])
    }
    defer {
        _ = sqlite3_exec(db, "DETACH DATABASE bundled;", nil, nil, nil)
    }

    try exec("BEGIN IMMEDIATE;")
    try exec("DROP TRIGGER IF EXISTS words_ai;")
    try exec("DROP TRIGGER IF EXISTS words_au;")
    try exec("DROP TRIGGER IF EXISTS words_ad;")
    try exec("DROP TABLE  IF EXISTS words_fts;")
    try exec("DROP TABLE  IF EXISTS words;")
    try exec("""
    CREATE TABLE words(
      id         TEXT PRIMARY KEY,
      ru         TEXT NOT NULL,
      en         TEXT NOT NULL,
      meaning_en TEXT,
      phonetic   TEXT,
      ru_norm    TEXT NOT NULL DEFAULT '',
      en_norm    TEXT NOT NULL DEFAULT '',
      is_common  INTEGER NOT NULL DEFAULT 0
    );
    """)
    try exec("CREATE INDEX IF NOT EXISTS idx_words_is_common ON words(is_common) WHERE is_common = 1;")
    try exec("""
    INSERT INTO words(id, ru, en, meaning_en, phonetic,
                      ru_norm, en_norm, is_common)
    SELECT id, ru, en, meaning_en, phonetic,
           ru_norm, en_norm, is_common
    FROM bundled.words;
    """)
    try exec("""
    CREATE VIRTUAL TABLE words_fts USING fts5(
      id UNINDEXED,
      ru,
      en,
      tokenize = 'unicode61'
    );
    """)
    try exec("""
    INSERT INTO words_fts(id, ru, en)
    SELECT id, ru_norm, en_norm FROM words;
    """)
    try exec("""
    CREATE TABLE IF NOT EXISTS dictionary_version(value INTEGER NOT NULL);
    """)
    try exec("DELETE FROM dictionary_version;")
    try exec("INSERT INTO dictionary_version(value) VALUES (\(targetVersion));")
    try exec("COMMIT;")

    // Foreign keys were off across the swap, so any used_words /
    // scheduled_pushes / recent_views row whose word_id is no longer in
    // the new dictionary is now dangling. Clean those up explicitly so
    // the user doesn't see "ghost" entries on Manage Used Words.
    try exec("""
    DELETE FROM used_words
    WHERE word_id NOT IN (SELECT id FROM words);
    """)
    try exec("""
    DELETE FROM scheduled_pushes
    WHERE word_id NOT IN (SELECT id FROM words);
    """)
    try exec("""
    DELETE FROM recent_views
    WHERE word_id NOT IN (SELECT id FROM words);
    """)
}

private func readDictionaryVersion() -> Int {
    guard let db else { return 0 }
    var stmt: OpaquePointer?
    let sql = "SELECT value FROM dictionary_version LIMIT 1;"
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
    defer { sqlite3_finalize(stmt) }
    if sqlite3_step(stmt) == SQLITE_ROW {
        return Int(sqlite3_column_int(stmt, 0))
    }
    return 0
}
```

4. Delete the entire `seedIfNeeded()` method and the JSON-decoding code.
   It is no longer called from `ensureSeededIfNeeded()` and has no other
   callers.

5. The `dictionary_version` table must also be created in
   `createSchemaIfNeeded()` for fresh installs that bypass the migration
   path (because the bundled file copy already stamped it). Add
   defensively at the start of `createSchemaIfNeeded()`:

```swift
try exec("""
CREATE TABLE IF NOT EXISTS dictionary_version(value INTEGER NOT NULL);
""")
```

**Acceptance**:
- Fresh install: delete the simulator's app sandbox, install the rebuilt
  app, launch. `~/.../Application Support/RussianWordOfDay/words.sqlite`
  exists, `SELECT COUNT(*) FROM words` returns the same N as the bundled
  artifact, `SELECT value FROM dictionary_version` returns 2. The cold
  launch shows no perceptible delay before the main UI appears.
- Upgrade from old build: pre-seed the simulator with an old-style
  `words.sqlite` (35-row JSON-seeded) AND non-empty `used_words` /
  `scheduled_pushes`, then install the new build. After launch:
  `dictionary_version` is 2, `words` row count matches the bundled DB,
  `used_words` rows for words still present in the bundled DB survive,
  rows for words missing from it are gone.

---

## 4) Push pool scoped to `is_common = 1`

**Problem**: with the dictionary jumping from ~5k to ~150k, the rolling
buffer would happily reserve obscure 17th-century legal vocabulary as
"word of the day", which defeats the learning goal. Pushes must keep
drawing from the top frequency-list lemmas only.

**Implementation in `RussianWordOfDayApp/Sources/WordStore.swift`**:

1. Update `pickRandomUnusedLocked` to filter on `is_common`:

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
      AND w.is_common = 1
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

2. Mirror the filter in `remainingUnusedCount()` so the Settings counter
   reflects "remaining teachable pushes" rather than the dictionary size:

```swift
func remainingUnusedCount() -> Int {
    guard let db else { return 0 }
    let sql = """
    SELECT COUNT(*)
    FROM words w
    LEFT JOIN used_words u       ON u.word_id = w.id
    LEFT JOIN scheduled_pushes s ON s.word_id = w.id
    WHERE u.word_id IS NULL
      AND s.word_id IS NULL
      AND w.is_common = 1;
    """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
    return Int(sqlite3_column_int(stmt, 0))
}
```

3. Do NOT add an `is_common` filter to `WordStore.search()`. Search must
   read the full table — that's the whole point of bundling 150k entries.

**Acceptance**:
- After `Apply notification schedule`, dump the simulator sandbox:
  `sqlite3 ~/.../words.sqlite "SELECT w.is_common FROM scheduled_pushes s JOIN words w ON w.id = s.word_id;"`. Every row returns `1`.
- Type a high-rank lemma in the main search bar (e.g. something that
  appears around line 80,000 of `ru_50k.txt`). It returns at least one
  row.
- Settings counter ("X words remaining") shows ~5,000 on a fresh install,
  not ~150,000.

---

## 5) `DATA_LICENSES.md`

**Problem**: today's `DATA_LICENSES.md` says "TBD" for both the
Wiktionary and frequency-list sources. The bundled artifact must carry
proper attribution at the repo level to satisfy CC-BY-SA and MIT.

**Implementation**: replace the body of `Russian - Word a Day/DATA_LICENSES.md` with:

```markdown
## Offline dictionary data sources

This app bundles an offline Russian→English dictionary as
`RussianWordOfDayApp/Resources/dictionary.sqlite`. The artifact is rebuilt
by `scripts/build_seed_db.py`; see that script for the exact transform.

### Bundled sources

#### Kaikki / Wiktionary (Russian)
- **Website**: https://kaikki.org/dictionary/Russian/
- **Used for**: every Russian lemma, English glosses/definitions, IPA
  phonetics.
- **License**: CC-BY-SA 4.0 (via Wiktionary). Attribution: "Includes data
  from Wiktionary contributors, made available via Kaikki.org."
- **Retrieval**: `kaikki.org-dictionary-Russian.jsonl`, retrieved
  <YYYY-MM-DD when you ran the pipeline>.

#### Hermit Dave / FrequencyWords (Russian, 50k)
- **Repository**: https://github.com/hermitdave/FrequencyWords
- **Used for**: top-N frequency ranking that drives the `is_common` flag
  (which is what the daily push picker draws from).
- **License**: MIT. Attribution: "Frequency data: Hermit Dave,
  FrequencyWords (MIT)."
- **Retrieval**: `content/2018/ru/ru_50k.txt`, retrieved
  <YYYY-MM-DD when you ran the pipeline>.

### Attribution in-app
The app currently does not surface a "Data sources" screen. The
attributions above satisfy redistribution requirements at the repository
level. A dedicated About screen is tracked as a follow-up and not in
scope for this runbook.
```

The two `<YYYY-MM-DD>` placeholders MUST be replaced with the actual
download date. No literal `<YYYY-MM-DD>` should remain in the committed
file.

**Acceptance**:
- `grep -i "TBD" DATA_LICENSES.md` returns no matches.
- `grep -i "<YYYY-MM-DD>" DATA_LICENSES.md` returns no matches.
- File names both Kaikki and FrequencyWords with their license names
  (`CC-BY-SA 4.0` and `MIT`).

---

## Cross-cutting acceptance criteria

When done, verify on Simulator (light **and** dark — the new schema
doesn't change UI surfaces but the regression sweep should still cover
both):

1. **Bundle size sanity**: `ls -lh "Russian - Word a Day/RussianWordOfDayApp/Resources/dictionary.sqlite"` is between 15M and 60M. Above 60M, STOP and escalate (recommended follow-up: gzip the bundled file and decompress in `installBundledDictionaryIfMissing` — out of scope for this runbook).
2. **Cold launch**: install on a clean simulator. The duration of `ensureSeededIfNeeded()` is under 500 ms on a debug build (informal — wrap with a `Date()` diff temporarily, revert before commit). The main UI is interactive in well under one second.
3. **Search latency at 150k rows**: type `при` in `MainView`. Results appear within one frame; FTS5 over 150k rows on FTS5 is sub-10ms locally. If any visible jank, capture an Instruments trace and stop.
4. **Push pool isolation**: tap `Apply notification schedule`, then run `sqlite3 ~/Library/Developer/CoreSimulator/Devices/<id>/data/Containers/Data/Application/<id>/Library/Application\ Support/RussianWordOfDay/words.sqlite "SELECT MIN(w.is_common), MAX(w.is_common), COUNT(*) FROM scheduled_pushes s JOIN words w ON w.id = s.word_id;"`. Result must be `1|1|60`.
5. **Search includes uncommon words**: pick a Russian lemma that appears around line 80,000 of `ru_50k.txt` (or any non-common word from `dictionary.sqlite` via `SELECT ru FROM words WHERE is_common = 0 LIMIT 5`). Type its first three characters in the main search; the row appears.
6. **Migration preserves user state**: simulate an existing user. From the simulator sandbox before installing the new build, pre-populate: a small old-style `words.sqlite` plus rows in `used_words` (one whose `word_id` is in the new bundled DB and one whose `word_id` is NOT). Install the new build. Launch. The first row survives in `used_words`; the second is gone. `dictionary_version` is now 2.
7. **Reset still works**: tap `Reset already used words`. `used_words`, `scheduled_pushes`, `scheduled_words` are emptied. `words` is untouched (`SELECT COUNT(*) FROM words` still returns N).
8. **No JSON path remains**: `git grep -n "words.seed\|seedResourceName\|seedIfNeeded"` returns no results inside `RussianWordOfDayApp/Sources/`. `Russian - Word a Day/RussianWordOfDayApp/Resources/words.seed.json` is gone.

## What you should NOT change

- `RussianWordOfDayApp/Sources/WordOfDayScheduler.swift` — the rolling
  buffer logic is unaffected. The defer-used-mark architecture from
  `RUNBOOK_DEFER_USED_MARK.md` continues to work because we only added a
  WHERE clause to `pickRandomUnusedLocked`.
- `RussianWordOfDayApp/Sources/Notifications.swift`,
  `AppDelegate.swift`, `AppRouter.swift`, `Models.swift`,
  `AppSettings.swift`, `RussianWordOfDayApp.swift` — unchanged.
- Any view file (`MainView.swift`, `SettingsView.swift`,
  `ManageUsedWordsView.swift`, `WordDetailView.swift`,
  `AlphabetView.swift`, `RootView.swift`, `CyrillicAlphabet.swift`).
  `WordStore.search` returns the full dictionary, so `MainView` already
  benefits from the larger pool with no UI change.
- `Info.plist`, `Assets.xcassets/*` — unchanged.
- The `bufferTarget = 60` constant. Push semantics are unaffected.
- The `Add back` and `Reset already used words` flows. Both keep working
  because they operate on `used_words` / `scheduled_pushes` only.
- The `.searchable` modifier on `ManageUsedWordsView` — if it's been
  added by a prior implementation of `RUNBOOK_5K_WORDS_AND_USED_SEARCH.md`
  Section 3, leave it in place. If not, that work is independent and may
  be done in a separate pass.
- The raw upstream files (`kaikki.jsonl`, `ru_50k.txt`). Never commit
  them; they are build-time inputs only.
