#!/usr/bin/env python3
"""
Filter junk rows from dictionary.sqlite and clear legacy usage-note columns.

Usage:
  python3 scripts/clean_usage_notes.py
  python3 scripts/clean_usage_notes.py --db path/to/dictionary.sqlite --dry-run
"""
from __future__ import annotations

import argparse
import contextlib
import re
import sqlite3
import sys
from collections import defaultdict
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
from build_seed_db import (  # noqa: E402
    english_headword_is_scrubbable_morph,
    should_exclude_proper_noun_openrussian,
)

DICTIONARY_VERSION = 40

CYRILLIC_RE = re.compile(r"[а-яА-ЯёЁ]")
MORPH_NOTE_MARKERS = (
    "form of",
    "plural form",
    "diminutive form",
    "colloquial form",
    "feminine form",
    "masculine form",
    "neuter form",
    "related words",
)
PLUS_ONLY_RE = re.compile(r"^\+\s*\w+\s*:\s*.+$", re.I)
_ID_SUFFIX_RE = re.compile(r"-\d+$")


def is_adjective_of_headline(en: str) -> bool:
    return bool(re.match(r"^adjective of\b", (en or "").strip(), re.IGNORECASE))


def is_diminutive_headline(en: str) -> bool:
    return "diminutive" in (en or "").lower()


def is_abbreviation_headline(en: str) -> bool:
    return bool(re.match(r"^abbr\.?\b", (en or "").strip(), re.IGNORECASE))


def is_truncated_english_headline(en: str) -> bool:
    t = (en or "").strip()
    if not t:
        return False
    return t.count("(") > t.count(")")


def english_headword_should_drop(en: str) -> bool:
    """Headlines that are not useful standalone dictionary entries for beginners."""
    t = (en or "").strip()
    if not t:
        return True
    if english_headword_is_scrubbable_morph(t):
        return True
    if is_abbreviation_headline(t):
        return True
    if is_adjective_of_headline(t) or is_diminutive_headline(t):
        return True
    return False


def is_morph_usage_note(note: str) -> bool:
    lower = note.lower()
    return any(marker in lower for marker in MORPH_NOTE_MARKERS)


def is_trivial_case_note(note: str) -> bool:
    t = note.strip()
    if not t:
        return True
    if PLUS_ONLY_RE.match(t):
        return True
    if t.startswith("+") and len(t) < 50 and CYRILLIC_RE.search(t) is None:
        return True
    return False


def looks_like_syllable_guide(note: str) -> bool:
    stripped = "".join(c for c in note if c.isalpha() or c in "- '")
    return bool(stripped) and len(stripped) >= len(note) * 2 // 3 and len(note) <= 48


def should_delete_row(
    ru: str,
    en: str,
    pos: str,
    note: str | None,
    noun_en_headlines: set[str],
    *,
    gloss_lines: list[str] | None = None,
    geo_lemmas: frozenset[str] | None = None,
    is_common: bool = False,
) -> bool:
    if english_headword_should_drop(en):
        return True
    if geo_lemmas is not None and should_exclude_proper_noun_openrussian(
        ru, en, gloss_lines or [], geo_lemmas=geo_lemmas
    ):
        return True
    n = (note or "").strip()
    if n and is_morph_usage_note(n):
        return True
    pos_l = (pos or "").lower()
    en_key = (en or "").strip().lower()
    if pos_l == "verb" and en_key and en_key in noun_en_headlines:
        if is_common:
            return False
        if is_trivial_case_note(n) or looks_like_syllable_guide(n) or not n:
            return True
    return False


def _row_keep_rank(row: sqlite3.Row) -> tuple:
    wid = str(row["id"])
    suffix_penalty = 1 if _ID_SUFFIX_RE.search(wid) else 0
    examples = (row["examples_en"] or "").count("\n") + (
        1 if (row["examples_en"] or "").strip() else 0
    )
    return (-(row["is_common"] or 0), -examples, suffix_penalty, wid)


def restore_missing_words(
    db_path: Path,
    *,
    csv_dir: Path,
    freq_path: Path,
) -> int:
    """Insert freq-list lemmas that are missing after earlier filter passes."""
    from build_from_openrussian import (  # noqa: E402
        GEO_BLOCKLIST,
        build_entry,
        index_by_bare,
        is_clean_lemma,
        load_en_translations,
        load_geo_blocklist,
        load_sentence_examples,
        load_words,
        pick_word_id,
        read_frequency,
    )
    from build_seed_db import normalize_for_index  # noqa: E402

    words = load_words(csv_dir)
    translations = load_en_translations(csv_dir)
    by_bare = index_by_bare(words, translations)
    freq = read_frequency(freq_path)
    common_set = set(freq[:5000])
    geo = load_geo_blocklist(GEO_BLOCKLIST)

    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    existing = {
        (
            (r[0] or "").strip(),
            (r[1] or "").strip().lower(),
            (r[2] or "").strip().lower(),
        )
        for r in conn.execute("SELECT ru_norm, en, pos FROM words")
    }

    selected: list[tuple[str, int]] = []
    seen_wid: set[int] = set()
    for lemma in freq:
        if not is_clean_lemma(lemma) or lemma in geo:
            continue
        wid = pick_word_id(by_bare.get(normalize_for_index(lemma), []), words)
        if wid is None or wid in seen_wid:
            continue
        seen_wid.add(wid)
        selected.append((lemma, wid))

    word_ids = {wid for _, wid in selected}
    sentence_map = load_sentence_examples(csv_dir, word_ids)

    used_ids = {str(r[0]) for r in conn.execute("SELECT id FROM words")}
    to_insert: list[tuple] = []
    for lemma, wid in selected:
        row = words[wid]
        entry = build_entry(
            wid,
            row,
            translations[wid],
            sentence_map.get(wid, []),
            is_common=lemma in common_set,
            used_ids=used_ids,
            geo_lemmas=geo,
        )
        if entry is None:
            continue
        key = (
            (entry[9] or "").strip(),
            (entry[2] or "").strip().lower(),
            (entry[4] or "").strip().lower(),
        )
        if key in existing:
            continue
        to_insert.append(entry)
        existing.add(key)
        used_ids.add(entry[0])

    if not to_insert:
        conn.close()
        print("Restore: no missing lemmas to insert.")
        return 0

    conn.execute("BEGIN IMMEDIATE")
    try:
        conn.executemany(
            "INSERT INTO words(id, ru, en, meaning_en, pos, glosses_en, examples_en, "
            "ai_note_en, phonetic, ru_norm, en_norm, is_common) "
            "VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
            to_insert,
        )
        conn.executemany(
            "INSERT INTO words_fts(id, ru, en) VALUES (?, ?, ?)",
            ((r[0], r[9], r[10]) for r in to_insert),
        )
        conn.execute("COMMIT")
    except BaseException:
        with contextlib.suppress(Exception):
            conn.execute("ROLLBACK")
        raise
    finally:
        conn.close()

    print(f"Restore: inserted {len(to_insert)} missing lemmas.")
    return len(to_insert)


def duplicate_ids_to_drop(rows: list[sqlite3.Row]) -> list[str]:
    """Drop exact duplicates (same ru_norm, en, pos); keep the best row."""
    groups: dict[tuple[str, str, str], list[sqlite3.Row]] = defaultdict(list)
    for row in rows:
        key = (
            (row["ru_norm"] or "").strip(),
            (row["en"] or "").strip().lower(),
            (row["pos"] or "").strip().lower(),
        )
        groups[key].append(row)

    to_delete: list[str] = []
    for grp in groups.values():
        if len(grp) < 2:
            continue
        keep = min(grp, key=_row_keep_rank)
        for row in grp:
            if row["id"] != keep["id"]:
                to_delete.append(str(row["id"]))
    return to_delete


def clean_database(
    db_path: Path,
    *,
    dry_run: bool,
    restore: bool = True,
    csv_dir: Path | None = None,
    freq_path: Path | None = None,
) -> int:
    if restore:
        csv = csv_dir or (SCRIPT_DIR.parent / "data" / "openrussian")
        freq = freq_path or (
            SCRIPT_DIR.parent.parent / "Assets" / "RussianWordADay" / "ru_50k.txt"
        )
        if not freq.exists():
            freq = SCRIPT_DIR.parent / "data" / "ru_50k.txt"
        if (csv / "openrussian_public - words.csv").exists() and freq.exists():
            restore_missing_words(db_path, csv_dir=csv, freq_path=freq)
        else:
            print("Restore: skipped (OpenRussian CSVs or freq list not found).")

    from build_from_openrussian import GEO_BLOCKLIST  # noqa: E402
    from build_seed_db import load_geo_blocklist  # noqa: E402

    geo_lemmas = load_geo_blocklist(GEO_BLOCKLIST)

    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    rows = list(
        conn.execute(
            "SELECT id, ru, en, pos, glosses_en, ai_note_en, phonetic, ru_norm, "
            "examples_en, is_common FROM words ORDER BY id"
        )
    )
    noun_en_headlines = {
        (r["en"] or "").strip().lower()
        for r in rows
        if (r["pos"] or "").lower() == "noun" and (r["en"] or "").strip()
    }

    dup_delete = duplicate_ids_to_drop(rows)
    dup_set = set(dup_delete)

    to_delete: list[str] = list(dup_delete)
    note_clears: list[str] = []

    for r in rows:
        wid = str(r["id"])
        if wid in dup_set:
            continue

        gloss_lines = [
            g.strip()
            for g in (r["glosses_en"] or "").splitlines()
            if g.strip()
        ]

        if should_delete_row(
            (r["ru"] or "").strip(),
            r["en"] or "",
            r["pos"] or "",
            r["ai_note_en"],
            noun_en_headlines,
            gloss_lines=gloss_lines,
            geo_lemmas=geo_lemmas,
            is_common=bool(r["is_common"]),
        ):
            to_delete.append(wid)
            continue

        if (r["ai_note_en"] or "").strip():
            note_clears.append(wid)

    print(f"Duplicate rows to drop: {len(dup_delete)}")
    print(f"Filter rows to drop: {len(to_delete) - len(dup_delete)}")
    print(f"Total rows to delete: {len(to_delete)}")
    print(f"Legacy usage notes to clear: {len(note_clears)}")
    if dry_run:
        for wid in to_delete[:15]:
            r = next(x for x in rows if str(x["id"]) == wid)
            print(f"  delete {r['ru']} ({r['en']}, {r['pos']}) id={wid}")
        if len(to_delete) > 15:
            print(f"  … and {len(to_delete) - 15} more")
        conn.close()
        return 0

    conn.execute("BEGIN IMMEDIATE")
    try:
        chunk = 400
        for i in range(0, len(to_delete), chunk):
            part = to_delete[i : i + chunk]
            ph = ",".join("?" * len(part))
            conn.execute(f"DELETE FROM words_fts WHERE id IN ({ph})", part)
            conn.execute(f"DELETE FROM words WHERE id IN ({ph})", part)

        if note_clears:
            conn.execute("UPDATE words SET ai_note_en = NULL")

        conn.execute("DELETE FROM dictionary_version")
        conn.execute(
            "INSERT INTO dictionary_version(value) VALUES (?)",
            (DICTIONARY_VERSION,),
        )
        conn.execute("COMMIT")
        conn.execute("PRAGMA optimize")
    except BaseException:
        with contextlib.suppress(Exception):
            conn.execute("ROLLBACK")
        raise
    finally:
        conn.close()

    remaining = sqlite3.connect(db_path).execute("SELECT COUNT(*) FROM words").fetchone()[0]
    with_notes = (
        sqlite3.connect(db_path)
        .execute(
            "SELECT COUNT(*) FROM words WHERE ai_note_en IS NOT NULL AND trim(ai_note_en) != ''"
        )
        .fetchone()[0]
    )
    print(
        f"Done. {remaining} words; {with_notes} with legacy usage notes; "
        f"dictionary_version={DICTIONARY_VERSION}"
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Filter dictionary.sqlite rows")
    parser.add_argument(
        "--db",
        type=Path,
        default=SCRIPT_DIR.parent / "RussianWordADayApp/Resources/dictionary.sqlite",
    )
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--no-restore", action="store_true")
    args = parser.parse_args()
    return clean_database(
        args.db,
        dry_run=args.dry_run,
        restore=not args.no_restore,
    )


if __name__ == "__main__":
    raise SystemExit(main())
