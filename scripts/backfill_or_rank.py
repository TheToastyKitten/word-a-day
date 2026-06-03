#!/usr/bin/env python3
"""
Backfill `or_rank` from OpenRussian CSV into an existing dictionary.sqlite.

Also migrates legacy `is_common` → `or_rank` column layout when needed.
"""
from __future__ import annotations

import argparse
import csv
import sqlite3
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

from build_from_openrussian import DICTIONARY_VERSION, word_rank  # noqa: E402
from build_seed_db import PUSH_POOL_MAX_OR_RANK, normalize_for_index  # noqa: E402

DEFAULT_CSV = SCRIPT_DIR.parent / "data" / "openrussian" / "openrussian_public - words.csv"
DEFAULT_DB = (
    SCRIPT_DIR.parent / "RussianWordADayApp" / "Resources" / "dictionary.sqlite"
)


def load_rank_by_bare(csv_path: Path) -> dict[str, int]:
    """Normalized bare lemma → best (lowest) OpenRussian rank."""
    out: dict[str, int] = {}
    with csv_path.open(encoding="utf-8") as f:
        for row in csv.DictReader(f):
            bare = (row.get("bare") or "").strip()
            if not bare:
                continue
            key = normalize_for_index(bare)
            rank = word_rank(row)
            if rank >= 999_999:
                continue
            prev = out.get(key)
            if prev is None or rank < prev:
                out[key] = rank
    return out


def ensure_or_rank_column(conn: sqlite3.Connection) -> None:
    cols = {r[1] for r in conn.execute("PRAGMA table_info(words)")}
    if "or_rank" in cols:
        return
    conn.execute("ALTER TABLE words ADD COLUMN or_rank INTEGER;")
    conn.execute("DROP INDEX IF EXISTS idx_words_is_common;")
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_words_or_rank_push ON words(or_rank) "
        f"WHERE or_rank IS NOT NULL AND or_rank <= {PUSH_POOL_MAX_OR_RANK};"
    )


def backfill(db_path: Path, csv_path: Path) -> None:
    rank_by_bare = load_rank_by_bare(csv_path)
    conn = sqlite3.connect(db_path)
    try:
        ensure_or_rank_column(conn)
        rows = list(conn.execute("SELECT id, ru_norm FROM words"))
        updated = 0
        missing = 0
        for wid, ru_norm in rows:
            norm = (ru_norm or "").strip()
            rank = rank_by_bare.get(norm)
            if rank is None:
                missing += 1
                conn.execute("UPDATE words SET or_rank = NULL WHERE id = ?", (wid,))
            else:
                conn.execute(
                    "UPDATE words SET or_rank = ? WHERE id = ?",
                    (rank, wid),
                )
                updated += 1
        push_pool = conn.execute(
            "SELECT COUNT(*) FROM words WHERE or_rank IS NOT NULL AND or_rank <= ?",
            (PUSH_POOL_MAX_OR_RANK,),
        ).fetchone()[0]
        conn.execute("DELETE FROM dictionary_version")
        conn.execute(
            "INSERT INTO dictionary_version(value) VALUES (?)",
            (DICTIONARY_VERSION,),
        )
        conn.commit()
        print(f"Updated or_rank for {updated:,} rows ({missing:,} without CSV rank).")
        print(f"Push pool (rank ≤ {PUSH_POOL_MAX_OR_RANK}): {push_pool:,}")
        print(f"dictionary_version={DICTIONARY_VERSION}")
    finally:
        conn.close()


def main() -> int:
    parser = argparse.ArgumentParser(description="Backfill OpenRussian or_rank")
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    parser.add_argument("--csv", type=Path, default=DEFAULT_CSV)
    args = parser.parse_args()
    if not args.csv.exists():
        print(f"OpenRussian CSV not found: {args.csv}", file=sys.stderr)
        return 1
    if not args.db.exists():
        print(f"Database not found: {args.db}", file=sys.stderr)
        return 1
    backfill(args.db, args.csv)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
