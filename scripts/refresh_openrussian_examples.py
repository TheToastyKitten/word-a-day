#!/usr/bin/env python3
"""
Re-apply OpenRussian example ordering on an existing dictionary.sqlite.

Use after improving sentence ranking in build_from_openrussian.py, without a full rebuild.

    python3 scripts/refresh_openrussian_examples.py
    python3 scripts/enrich_dictionary_tatoeba.py --from-dump --resume
"""

from __future__ import annotations

import argparse
import sqlite3
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from build_from_openrussian import (  # noqa: E402
    format_examples,
    gloss_tokens_from_translations,
    load_en_translations,
    load_sentence_examples,
    load_words,
    normalize_for_index,
)

PROJECT_ROOT = SCRIPT_DIR.parent
DEFAULT_CSV = PROJECT_ROOT / "data" / "openrussian"
DEFAULT_DB = PROJECT_ROOT / "RussianWordADayApp" / "Resources" / "dictionary.sqlite"
DICTIONARY_VERSION = 32


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--csv-dir", type=Path, default=DEFAULT_CSV)
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    args = parser.parse_args()

    words = load_words(args.csv_dir)
    translations = load_en_translations(args.csv_dir)

    conn = sqlite3.connect(args.db)
    rows = conn.execute("SELECT id, ru FROM words").fetchall()
    ru_to_id = {normalize_for_index(ru): wid for wid, ru in rows}

    bare_to_wid: dict[str, int] = {}
    for wid, row in words.items():
        if wid in translations:
            bare_to_wid[normalize_for_index(row["bare"])] = wid

    word_ids = {bare_to_wid[n] for n in ru_to_id if n in bare_to_wid}
    sentence_map = load_sentence_examples(args.csv_dir, word_ids)

    updated = cleared = 0
    for word_id, ru in rows:
        norm = normalize_for_index(ru)
        opr_wid = bare_to_wid.get(norm)
        if opr_wid is None:
            continue
        trans_rows = translations.get(opr_wid, [])
        gloss_tokens = gloss_tokens_from_translations(trans_rows)
        examples = format_examples(
            trans_rows,
            sentence_map.get(opr_wid, []),
            gloss_tokens,
        )
        conn.execute(
            "UPDATE words SET examples_en = ? WHERE id = ?",
            (examples, word_id),
        )
        if examples:
            updated += 1
        else:
            cleared += 1

    conn.execute("DELETE FROM dictionary_version")
    conn.execute("INSERT INTO dictionary_version(value) VALUES (?)", (DICTIONARY_VERSION,))
    conn.commit()
    conn.close()
    print(f"OpenRussian examples refreshed: {updated:,} with examples, {cleared:,} empty.")
    print("Next: python3 scripts/enrich_dictionary_tatoeba.py --from-dump --resume")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
