#!/usr/bin/env python3
"""Backfill forms_json from OpenRussian CSVs into dictionary.sqlite."""
from __future__ import annotations

import argparse
import csv
import sqlite3
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

from build_from_openrussian import DICTIONARY_VERSION, POS_MAP  # noqa: E402
from openrussian_word_forms import (  # noqa: E402
    build_forms_json_for_word,
    load_forms_index,
    load_verbs_meta,
)

DEFAULT_DB = (
    SCRIPT_DIR.parent / "RussianWordADayApp" / "Resources" / "dictionary.sqlite"
)
DEFAULT_CSV = SCRIPT_DIR.parent / "data" / "openrussian"


def load_or_word_id_map(csv_dir: Path) -> dict[tuple[str, str], int]:
    """(ru_norm, pos) -> OpenRussian word_id (lowest rank when duplicates)."""
    from build_seed_db import normalize_for_index  # noqa: E402
    from build_from_openrussian import word_rank  # noqa: E402

    path = csv_dir / "openrussian_public - words.csv"
    best: dict[tuple[str, str], tuple[int, int]] = {}
    with path.open(encoding="utf-8-sig", newline="") as f:
        for row in csv.DictReader(f):
            if row.get("disabled", "1") != "0":
                continue
            bare = (row.get("bare") or "").strip()
            if not bare:
                continue
            typ = (row.get("type") or "").strip().lower()
            pos = POS_MAP.get(typ, typ or "other")
            key = (normalize_for_index(bare), (pos or "other").lower())
            try:
                wid = int((row.get("id") or "").strip().lstrip("\ufeff"))
            except ValueError:
                continue
            rank = word_rank(row)
            prev = best.get(key)
            if prev is None or rank < prev[0]:
                best[key] = (rank, wid)
    return {k: v[1] for k, v in best.items()}


def backfill(db_path: Path, csv_dir: Path) -> None:
    conn = sqlite3.connect(db_path)
    cols = {r[1] for r in conn.execute("PRAGMA table_info(words)")}
    if "forms_json" not in cols:
        conn.execute("ALTER TABLE words ADD COLUMN forms_json TEXT;")

    print("Loading forms index…")
    forms_index = load_forms_index(csv_dir)
    verbs_meta = load_verbs_meta(csv_dir)
    or_map = load_or_word_id_map(csv_dir)

    rows = list(conn.execute("SELECT id, ru, ru_norm, pos FROM words"))
    updated = 0
    with_forms = 0
    for wid_slug, ru, ru_norm, pos in rows:
        pos_l = (pos or "other").strip().lower()
        or_wid = or_map.get((ru_norm or "", pos_l))
        if or_wid is None:
            forms_json = None
        else:
            forms_json = build_forms_json_for_word(
                word_id=or_wid,
                bare=ru or "",
                pos=pos,
                forms_index=forms_index,
                verbs_meta=verbs_meta,
            )
        conn.execute(
            "UPDATE words SET forms_json = ? WHERE id = ?",
            (forms_json, wid_slug),
        )
        updated += 1
        if forms_json:
            with_forms += 1

    conn.execute("DELETE FROM dictionary_version")
    conn.execute(
        "INSERT INTO dictionary_version(value) VALUES (?)",
        (DICTIONARY_VERSION,),
    )
    conn.commit()
    conn.close()
    print(f"Updated {updated:,} rows; {with_forms:,} with forms_json")
    print(f"dictionary_version={DICTIONARY_VERSION}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    parser.add_argument("--csv-dir", type=Path, default=DEFAULT_CSV)
    args = parser.parse_args()
    if not args.db.exists():
        print(f"DB not found: {args.db}", file=sys.stderr)
        return 1
    backfill(args.db, args.csv_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
