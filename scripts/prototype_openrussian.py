#!/usr/bin/env python3
"""
Build a throwaway dictionary.sqlite from OpenRussian CSV exports (spike / evaluation).

    python3 scripts/download_openrussian.py
    python3 scripts/prototype_openrussian.py --limit 100
    python3 scripts/compare_openrussian_spike.py

Outputs: data/openrussian/prototype_dictionary.sqlite
"""

from __future__ import annotations

import argparse
import csv
import re
import sqlite3
import unicodedata
from collections import defaultdict
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent
DEFAULT_CSV_DIR = PROJECT_ROOT / "data" / "openrussian"
DEFAULT_OUT = DEFAULT_CSV_DIR / "prototype_dictionary.sqlite"
DEFAULT_CURRENT = PROJECT_ROOT / "RussianWordADayApp" / "Resources" / "dictionary.sqlite"

EXAMPLE_FIELD_SEP = "\t"
MAX_EXAMPLES = 6
COMMON_RANK_MAX = 5000

# Always include for manual review
PINNED_BARE = (
    "ханжа",
    "пожалуйста",
    "говорить",
    "москва",
)

POS_MAP = {
    "noun": "noun",
    "verb": "verb",
    "adjective": "adj",
    "adverb": "adv",
    "pronoun": "pron",
    "preposition": "prep",
    "conjunction": "conj",
    "particle": "particle",
    "interjection": "interjection",
    "numeral": "num",
    "other": "other",
    "expression": "expression",
}


def normalize_lemma(s: str) -> str:
    t = unicodedata.normalize("NFC", s.strip().lower())
    return t.replace("\u0301", "").replace("ё", "е")


def slugify(russian: str, used: set[str]) -> str:
    translit = {
        "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "yo",
        "ж": "zh", "з": "z", "и": "i", "й": "y", "к": "k", "л": "l", "м": "m",
        "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u",
        "ф": "f", "х": "kh", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "shch",
        "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya",
    }
    base = "".join(translit.get(ch, ch) for ch in russian.lower())
    base = re.sub(r"[^a-z0-9]+", "_", base).strip("_") or "word"
    candidate = base
    n = 2
    while candidate in used:
        candidate = f"{base}_{n}"
        n += 1
    used.add(candidate)
    return candidate


def load_words(csv_dir: Path) -> dict[int, dict]:
    path = csv_dir / "openrussian_public - words.csv"
    out: dict[int, dict] = {}
    with path.open(encoding="utf-8-sig", newline="") as f:
        for row in csv.DictReader(f):
            if row.get("disabled", "1") != "0":
                continue
            if not (row.get("type") or "").strip():
                continue
            wid = int(row["id"])
            out[wid] = row
    return out


def load_en_translations(csv_dir: Path) -> dict[int, list[dict]]:
    path = csv_dir / "openrussian_public - translations.csv"
    by_word: dict[int, list[dict]] = defaultdict(list)
    with path.open(encoding="utf-8-sig", newline="") as f:
        for row in csv.DictReader(f):
            if row.get("lang") != "en":
                continue
            tl = (row.get("tl") or "").strip()
            if not tl:
                continue
            by_word[int(row["word_id"])].append(row)
    return by_word


def load_sentence_examples(csv_dir: Path, word_ids: set[int]) -> dict[int, list[tuple[str, str]]]:
    """word_id -> [(ru, en), ...] from Tatoeba-linked sentences (max 6)."""
    sw_path = csv_dir / "openrussian_public - sentences_words.csv"
    st_path = csv_dir / "openrussian_public - sentences_translations.csv"
    s_path = csv_dir / "openrussian_public - sentences.csv"

    sentence_en: dict[int, str] = {}
    with st_path.open(encoding="utf-8-sig", newline="") as f:
        for row in csv.DictReader(f):
            sid = int(row["sentence_id"])
            en = (row.get("tl_en") or "").strip()
            if en:
                sentence_en[sid] = en

    sentence_ru: dict[int, str] = {}
    with s_path.open(encoding="utf-8-sig", newline="") as f:
        for row in csv.DictReader(f):
            sid = int(row["id"])
            if sid in sentence_en:
                ru = (row.get("ru") or "").strip()
                if ru:
                    sentence_ru[sid] = ru

    out: dict[int, list[tuple[str, str]]] = defaultdict(list)
    with sw_path.open(encoding="utf-8-sig", newline="") as f:
        for row in csv.DictReader(f):
            wid = int(row["word_id"])
            if wid not in word_ids:
                continue
            if len(out[wid]) >= MAX_EXAMPLES:
                continue
            sid = int(row["sentence_id"])
            ru = sentence_ru.get(sid)
            en = sentence_en.get(sid)
            if ru and en:
                out[wid].append((ru, en))
    return out


def split_translation_glosses(tl: str) -> list[str]:
    """OpenRussian: meanings separated by ; synonyms by , within a meaning."""
    glosses: list[str] = []
    for meaning in tl.split(";"):
        part = meaning.strip()
        if not part:
            continue
        # First synonym chunk is enough for headline; keep full meaning as one gloss line too
        glosses.append(part)
    return glosses


def gloss_tokens_from_translations(trans_rows: list[dict]) -> set[str]:
    toks: set[str] = set()
    for row in trans_rows:
        for g in split_translation_glosses(row["tl"]):
            for piece in re.split(r"[,;]", g):
                for word in piece.split():
                    w = re.sub(r"[^\w]", "", word.strip().lower())
                    if len(w) >= 3:
                        toks.add(w)
    return toks


def example_aligns(en: str, gloss_tokens: set[str]) -> bool:
    if not gloss_tokens:
        return True
    words = set(re.findall(r"[a-z]{3,}", en.lower()))
    return bool(words & gloss_tokens)


def format_examples(
    trans_rows: list[dict],
    sentence_pairs: list[tuple[str, str]],
    gloss_tokens: set[str],
) -> str | None:
    lines: list[str] = []
    seen_ru: set[str] = set()
    seen_en: set[str] = set()

    def add(ru: str, en: str, *, require_align: bool) -> None:
        ru_t, en_t = ru.strip(), en.strip()
        if not ru_t or not en_t:
            return
        if require_align and not example_aligns(en_t, gloss_tokens):
            return
        rk = normalize_lemma(ru_t)
        ek = re.sub(r"\s+", " ", en_t.lower())
        if rk in seen_ru or ek in seen_en:
            return
        seen_ru.add(rk)
        seen_en.add(ek)
        lines.append(f"{ru_t}{EXAMPLE_FIELD_SEP}{en_t}")

    for row in trans_rows:
        ru = (row.get("example_ru") or "").strip()
        en = (row.get("example_tl") or "").strip()
        if ru and en:
            add(ru, en, require_align=False)

    for ru, en in sentence_pairs:
        if len(lines) >= MAX_EXAMPLES:
            break
        add(ru, en, require_align=True)

    return "\n".join(lines) if lines else None


def pick_word_ids(
    words: dict[int, dict],
    translations: dict[int, list[dict]],
    current_db: Path | None,
    limit: int,
) -> list[int]:
    pinned_norm = {normalize_lemma(b) for b in PINNED_BARE}
    pinned_ids: list[int] = []
    for wid, row in words.items():
        if normalize_lemma(row["bare"]) in pinned_norm:
            pinned_ids.append(wid)

    extra_ids: list[int] = []
    if current_db and current_db.exists():
        import random

        random.seed(42)
        cur_lemmas: list[str] = []
        conn = sqlite3.connect(current_db)
        for (ru,) in conn.execute("SELECT ru FROM words"):
            norm = normalize_lemma(ru)
            if norm in pinned_norm:
                continue
            for wid, row in words.items():
                if normalize_lemma(row["bare"]) == norm and wid in translations:
                    extra_ids.append(wid)
                    break
            else:
                cur_lemmas.append(ru)
        conn.close()
        # Fill remaining from current DB lemmas that exist in OpenRussian
        random.shuffle(extra_ids)
        need = max(0, limit - len(pinned_ids))
        chosen = extra_ids[:need]
        if len(chosen) < need:
            # Any enabled words with EN translations
            pool = [
                wid
                for wid, row in words.items()
                if wid not in pinned_ids
                and wid not in chosen
                and wid in translations
            ]
            random.shuffle(pool)
            chosen.extend(pool[: need - len(chosen)])
        return pinned_ids + chosen[: max(0, limit - len(pinned_ids))]

    pool = [wid for wid in words if wid in translations and wid not in pinned_ids]
    return (pinned_ids + pool)[:limit]


def build_entry(
    wid: int,
    row: dict,
    trans_rows: list[dict],
    sentence_pairs: list[tuple[str, str]],
    used_ids: set[str],
) -> tuple | None:
    bare = row["bare"].strip()
    if not bare:
        return None

    gloss_lines: list[str] = []
    for tr in trans_rows:
        gloss_lines.extend(split_translation_glosses(tr["tl"]))
    if not gloss_lines:
        return None

    headline = gloss_lines[0]
    if len(headline) > 60:
        headline = headline[:59].rstrip() + "…"
    meaning = "; ".join(gloss_lines[:4])
    if len(meaning) > 200:
        meaning = meaning[:199].rstrip() + "…"
    glosses_blob = "\n".join(gloss_lines[:5])

    rank_raw = (row.get("rank") or "").strip()
    try:
        rank = int(rank_raw)
    except ValueError:
        rank = 999_999
    is_common = 1 if 0 < rank <= COMMON_RANK_MAX else 0

    pos = POS_MAP.get((row.get("type") or "").strip().lower(), row.get("type"))

    accented = (row.get("accented") or "").strip()
    usage = (row.get("usage_en") or "").strip()

    gloss_tokens = gloss_tokens_from_translations(trans_rows)
    examples = format_examples(trans_rows, sentence_pairs, gloss_tokens)

    word_id = slugify(bare, used_ids)
    return (
        word_id,
        bare,
        headline,
        meaning,
        pos,
        glosses_blob,
        examples,
        usage or None,
        accented or None,
        normalize_lemma(bare),
        normalize_lemma(headline),
        is_common,
        0,  # wiktionary_baked = 0 → OpenRussian source
    )


SCHEMA_SQL = """
CREATE TABLE words(
  id         TEXT PRIMARY KEY,
  ru         TEXT NOT NULL,
  en         TEXT NOT NULL,
  meaning_en TEXT,
  pos        TEXT,
  glosses_en TEXT,
  examples_en TEXT,
  ai_note_en TEXT,
  phonetic   TEXT,
  ru_norm    TEXT NOT NULL DEFAULT '',
  en_norm    TEXT NOT NULL DEFAULT '',
  is_common  INTEGER NOT NULL DEFAULT 0,
  wiktionary_baked INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE dictionary_version(value INTEGER NOT NULL);
INSERT INTO dictionary_version(value) VALUES (9001);
"""


def main() -> None:
    parser = argparse.ArgumentParser(description="OpenRussian prototype SQLite")
    parser.add_argument("--csv-dir", type=Path, default=DEFAULT_CSV_DIR)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--limit", type=int, default=100)
    parser.add_argument("--current", type=Path, default=DEFAULT_CURRENT)
    args = parser.parse_args()

    print(f"Loading words from {args.csv_dir}…")
    words = load_words(args.csv_dir)
    print(f"  enabled lemmas with type: {len(words):,}")

    print("Loading EN translations…")
    translations = load_en_translations(args.csv_dir)
    with_en = sum(1 for wid in words if wid in translations)
    print(f"  lemmas with ≥1 EN translation: {with_en:,}")

    pick_ids = pick_word_ids(words, translations, args.current, args.limit)
    print(f"Building prototype ({len(pick_ids)} words)…")

    sentence_map = load_sentence_examples(args.csv_dir, set(pick_ids))

    if args.out.exists():
        args.out.unlink()

    conn = sqlite3.connect(args.out)
    conn.executescript(SCHEMA_SQL)
    used_ids: set[str] = set()
    rows = []
    for wid in pick_ids:
        row = words.get(wid)
        if not row:
            continue
        entry = build_entry(wid, row, translations.get(wid, []), sentence_map.get(wid, []), used_ids)
        if entry:
            rows.append(entry)

    conn.executemany(
        "INSERT INTO words(id, ru, en, meaning_en, pos, glosses_en, examples_en, ai_note_en, "
        "phonetic, ru_norm, en_norm, is_common, wiktionary_baked) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
        rows,
    )
    conn.commit()
    conn.close()

    size_kb = args.out.stat().st_size / 1024
    print(f"Wrote {args.out} ({len(rows)} rows, {size_kb:.0f} KB)")


if __name__ == "__main__":
    main()
