#!/usr/bin/env python3
"""Refresh words.phonetic in an existing bundle from OpenRussian accented forms."""

from __future__ import annotations

import argparse
import csv
import sqlite3
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from build_from_openrussian import learner_phonetic, normalize_for_index  # noqa: E402

PROJECT_ROOT = SCRIPT_DIR.parent
DEFAULT_CSV = PROJECT_ROOT / "data" / "openrussian" / "openrussian_public - words.csv"
DEFAULT_DB = PROJECT_ROOT / "RussianWordADayApp" / "Resources" / "dictionary.sqlite"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    parser.add_argument("--csv", type=Path, default=DEFAULT_CSV)
    args = parser.parse_args()

    by_bare: dict[str, tuple[str, str]] = {}
    with args.csv.open(encoding="utf-8-sig", newline="") as f:
        for row in csv.DictReader(f):
            bare = (row.get("bare") or "").strip()
            if bare:
                by_bare[normalize_for_index(bare)] = (bare, (row.get("accented") or "").strip())

    conn = sqlite3.connect(args.db)
    updated = 0
    for word_id, ru in conn.execute("SELECT id, ru FROM words"):
        got = by_bare.get(normalize_for_index(ru))
        if not got:
            continue
        bare, accented = got
        ph = learner_phonetic(accented, bare)
        if not ph:
            continue
        conn.execute("UPDATE words SET phonetic = ? WHERE id = ?", (ph, word_id))
        updated += 1
    conn.commit()
    conn.close()
    print(f"Updated phonetic for {updated:,} words.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
