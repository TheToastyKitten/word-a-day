#!/usr/bin/env python3
"""Split comma-separated synonyms in en/glosses_en/meaning_en for an existing bundle."""

from __future__ import annotations

import argparse
import sqlite3
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from build_from_openrussian import split_translation_glosses  # noqa: E402
from build_seed_db import normalize_for_index  # noqa: E402

PROJECT_ROOT = SCRIPT_DIR.parent
DEFAULT_DB = PROJECT_ROOT / "RussianWordADayApp" / "Resources" / "dictionary.sqlite"
MAX_GLOSS_LEN = 60
MAX_MEANING_LEN = 200


def expand_gloss_lines(en: str, glosses_en: str | None, meaning_en: str | None) -> list[str]:
    lines: list[str] = []
    seen: set[str] = set()

    def add_from(text: str) -> None:
        for clause in split_translation_glosses(text.replace("\n", ";")):
            if clause not in seen:
                seen.add(clause)
                lines.append(clause)

    add_from(en)
    if glosses_en:
        for line in glosses_en.split("\n"):
            add_from(line)
    if meaning_en:
        add_from(meaning_en)
    return lines


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", type=Path, default=DEFAULT_DB)
    args = parser.parse_args()

    conn = sqlite3.connect(args.db)
    updated = 0
    for word_id, ru, en, glosses_en, meaning_en, en_norm in conn.execute(
        "SELECT id, ru, en, glosses_en, meaning_en, en_norm FROM words"
    ):
        lines = expand_gloss_lines(en or "", glosses_en, meaning_en)
        if not lines:
            continue
        headline = lines[0]
        if len(headline) > MAX_GLOSS_LEN:
            headline = headline[: MAX_GLOSS_LEN - 1].rstrip() + "…"
        extra = lines[1:]
        meaning = "; ".join(extra[:4]) if extra else None
        if meaning and len(meaning) > MAX_MEANING_LEN:
            meaning = meaning[: MAX_MEANING_LEN - 1].rstrip() + "…"
        glosses_blob = "\n".join(lines[:5])
        new_en_norm = normalize_for_index(headline)
        if (
            headline == en
            and glosses_blob == (glosses_en or "")
            and (meaning or "") == (meaning_en or "")
            and new_en_norm == en_norm
        ):
            continue
        conn.execute(
            "UPDATE words SET en = ?, glosses_en = ?, meaning_en = ?, en_norm = ? WHERE id = ?",
            (headline, glosses_blob, meaning, new_en_norm, word_id),
        )
        conn.execute("UPDATE words_fts SET en = ? WHERE id = ?", (new_en_norm, word_id))
        updated += 1
    conn.commit()
    conn.close()
    print(f"Updated gloss headlines for {updated:,} words.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
