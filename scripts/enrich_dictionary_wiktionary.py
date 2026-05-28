#!/usr/bin/env python3
"""
Enrich dictionary.sqlite with Wiktionary-derived fields at build time.

This script is intentionally offline-first:
- It does NOT call Wiktionary at runtime from the app.
- It can optionally use a local Kaikki JSONL dump (Wiktionary-derived) to extract examples.

Usage:
    python3 scripts/enrich_dictionary_wiktionary.py \
        --db RussianWordADayApp/Resources/dictionary.sqlite \
        [--kaikki path/to/kaikki.org-dictionary-Russian.jsonl]
"""

from __future__ import annotations

import argparse
import json
import sqlite3
import sys
import unicodedata
from collections.abc import Iterator
from pathlib import Path


DICTIONARY_VERSION = 21
MAX_EXAMPLES = 6


def normalize_lemma(s: str) -> str:
    return unicodedata.normalize("NFC", s.strip().lower()).replace("\u0301", "")


def ensure_columns(conn: sqlite3.Connection) -> None:
    cols = {row[1] for row in conn.execute("PRAGMA table_info(words)")}
    if "examples_en" not in cols:
        conn.execute("ALTER TABLE words ADD COLUMN examples_en TEXT")
    if "wiktionary_baked" not in cols:
        conn.execute(
            "ALTER TABLE words ADD COLUMN wiktionary_baked INTEGER NOT NULL DEFAULT 1"
        )


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


def extract_example_lines(obj: dict) -> list[str]:
    """
    Best-effort: Kaikki mirrors Wiktionary and example structures vary.
    We accept a few common shapes:
      - {"text": "...", "translation": "..."}
      - {"text": "...", "english": "..."}
      - {"text": "...", "translations": [{"text": "...", "lang": "en"}]}
    """
    out: list[str] = []
    seen: set[str] = set()

    for sense in obj.get("senses") or []:
        examples = sense.get("examples") or sense.get("example") or []
        if not isinstance(examples, list):
            continue
        for ex in examples:
            if not isinstance(ex, dict):
                continue
            ru = (ex.get("text") or "").strip()
            en = (ex.get("translation") or ex.get("english") or "").strip()
            if not en:
                tr = ex.get("translations")
                if isinstance(tr, list):
                    for t in tr:
                        if not isinstance(t, dict):
                            continue
                        if (t.get("lang") or t.get("language")) in ("en", "eng", "English"):
                            cand = (t.get("text") or "").strip()
                            if cand:
                                en = cand
                                break
            if not ru and not en:
                continue
            line = f"{ru} — {en}".strip(" —")
            if not line or line in seen:
                continue
            seen.add(line)
            out.append(line)
            if len(out) >= MAX_EXAMPLES:
                return out
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="Enrich dictionary.sqlite from Wiktionary-derived data")
    ap.add_argument(
        "--db",
        type=Path,
        default=Path("RussianWordADayApp/Resources/dictionary.sqlite"),
    )
    ap.add_argument(
        "--kaikki",
        type=Path,
        default=None,
        help="Optional Kaikki Russian JSONL dump to extract examples from.",
    )
    args = ap.parse_args()

    if not args.db.exists():
        print(f"Database not found: {args.db}", file=sys.stderr)
        return 1

    conn = sqlite3.connect(args.db, isolation_level=None)
    try:
        ensure_columns(conn)

        if args.kaikki is not None:
            if not args.kaikki.exists():
                print(f"Kaikki dump not found: {args.kaikki}", file=sys.stderr)
                return 2

            # Map lemma -> example lines
            examples_by_lemma: dict[str, list[str]] = {}
            for obj in stream_kaikki(args.kaikki):
                word = obj.get("word")
                if not isinstance(word, str) or not word.strip():
                    continue
                lemma = normalize_lemma(word)
                if lemma in examples_by_lemma:
                    continue
                lines = extract_example_lines(obj)
                if lines:
                    examples_by_lemma[lemma] = lines

            rows = conn.execute("SELECT id, ru FROM words").fetchall()
            conn.execute("BEGIN IMMEDIATE")
            updated = 0
            for wid, ru in rows:
                lemma = normalize_lemma(ru)
                lines = examples_by_lemma.get(lemma)
                if not lines:
                    continue
                blob = "\n".join(lines[:MAX_EXAMPLES])
                conn.execute(
                    "UPDATE words SET examples_en = ?, wiktionary_baked = 1 WHERE id = ?",
                    (blob, wid),
                )
                updated += 1

            conn.execute("DELETE FROM dictionary_version")
            conn.execute(
                "INSERT INTO dictionary_version(value) VALUES (?)",
                (DICTIONARY_VERSION,),
            )
            conn.execute("COMMIT")
            print(f"Updated {updated} rows with examples; dictionary_version={DICTIONARY_VERSION}")
        else:
            # Still bump the schema/version so the app can migrate away from legacy yandex columns.
            conn.execute("BEGIN IMMEDIATE")
            conn.execute("UPDATE words SET wiktionary_baked = 1")
            conn.execute("DELETE FROM dictionary_version")
            conn.execute(
                "INSERT INTO dictionary_version(value) VALUES (?)",
                (DICTIONARY_VERSION,),
            )
            conn.execute("COMMIT")
            print(f"Marked all rows wiktionary_baked=1; dictionary_version={DICTIONARY_VERSION}")
    finally:
        conn.close()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

