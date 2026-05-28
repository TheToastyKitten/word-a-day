#!/usr/bin/env python3
"""
Build dictionary.sqlite from OpenRussian CSV exports + frequency list.

English glosses and OpenRussian-linked examples come from OpenRussian.
Run Tatoeba enrichment afterward to fill rows still missing examples:

    python3 scripts/download_openrussian.py
    python3 scripts/build_from_openrussian.py
    python3 scripts/enrich_dictionary_tatoeba.py --from-dump --resume

Defaults read ``ru_50k.txt`` from Projects/Assets/RussianWordADay/.
"""

from __future__ import annotations

import argparse
import csv
import re
import sqlite3
import sys
import unicodedata
from collections import defaultdict
from pathlib import Path

# Reuse helpers from the Kaikki builder (no Kaikki dump required).
SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from build_seed_db import (  # noqa: E402
    SCHEMA_SQL,
    english_phrasebook_pronunciation,
    is_clean_lemma,
    load_geo_blocklist,
    normalize_for_index,
    read_frequency,
    slugify,
)

_VOWELS = set("аеёиоуыэюя")


def openrussian_to_nfc_stressed(accented: str, bare: str) -> str:
    """
    OpenRussian marks stress with an apostrophe before the stressed vowel (e.g. пожа'луйста).
    Convert to NFC with U+0301 so the Kaikki phrasebook romanizer can run.
    """
    if not accented or "'" not in accented:
        return bare
    apos = accented.index("'")
    word = bare
    letters_only = accented.replace("'", "")
    if len(letters_only) == len(bare):
        word = letters_only
    stress_i: int | None = None
    start = min(apos, len(word))
    for i in range(start, len(word)):
        if word[i].lower() in _VOWELS:
            stress_i = i
            break
    if stress_i is None:
        for i in range(start - 1, -1, -1):
            if word[i].lower() in _VOWELS:
                stress_i = i
                break
    if stress_i is None:
        return bare
    return unicodedata.normalize(
        "NFC", word[: stress_i + 1] + "\u0301" + word[stress_i + 1 :]
    )


def learner_phonetic(accented: str, bare: str) -> str | None:
    """English-friendly hyphenated syllables (e.g. khah-NZHAH), not Cyrillic stress marks."""
    surface = openrussian_to_nfc_stressed(accented, bare)
    return english_phrasebook_pronunciation(surface, bare)

PROJECT_ROOT = SCRIPT_DIR.parent
WORKSPACE_ASSETS = PROJECT_ROOT.parent / "Assets" / "RussianWordADay"
DEFAULT_CSV_DIR = PROJECT_ROOT / "data" / "openrussian"
DEFAULT_FREQ = WORKSPACE_ASSETS / "ru_50k.txt"
DEFAULT_OUT = PROJECT_ROOT / "RussianWordADayApp" / "Resources" / "dictionary.sqlite"
GEO_BLOCKLIST = SCRIPT_DIR / "geo_lemma_blocklist.txt"

DICTIONARY_VERSION = 32
EXAMPLE_FIELD_SEP = "\t"
MAX_EXAMPLES = 6
MAX_GLOSS_LEN = 60
MAX_MEANING_LEN = 200

# OpenRussian ``type`` values kept in the learner dictionary.
ALLOWED_TYPES = frozenset(
    {
        "noun",
        "verb",
        "adjective",
        "adverb",
        "pronoun",
        "preposition",
        "conjunction",
        "particle",
        "interjection",
        "numeral",
        "other",
    }
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
}


def split_translation_glosses(tl: str) -> list[str]:
    """
    OpenRussian: ``;`` separates meanings, ``,`` separates synonyms within a meaning.
  Each synonym becomes its own gloss line; the first is stored as ``en``.
    """
    glosses: list[str] = []
    seen: set[str] = set()
    for meaning in tl.split(";"):
        for part in meaning.split(","):
            clause = part.strip()
            if not clause or clause in seen:
                continue
            seen.add(clause)
            glosses.append(clause)
    return glosses


_EN_HINT = re.compile(
    r"\b(the|a|an|is|are|was|were|have|has|had|do|does|did|you|your|my|"
    r"this|that|it|in|on|at|to|of|for|with|not|and|but|can't|don't|doesn't)\b",
    re.I,
)
_DE_WORD = re.compile(
    r"\b(nicht|und|des|dem|den|ein|eine|einen|ist|sind|werden|wurde|"
    r"mit|für|außer|geschöpf|menschengestalt|verkraften|können)\b",
    re.I,
)


def is_likely_english(text: str) -> bool:
    """
    Drop mis-tagged German (or other) strings in OpenRussian ``example_tl`` / ``tl_en``.
    """
    t = text.strip()
    if not t:
        return False
    lower = t.lower()
    if re.search(r"[äöß]", lower):
        if len(_EN_HINT.findall(lower)) < 2 and len(_DE_WORD.findall(lower)) >= 1:
            return False
    if lower.startswith(("haben ", "hast ", "hat ", "er konnte", "sie haben", "ich ")):
        return False
    de_hits = len(_DE_WORD.findall(lower))
    en_hits = len(_EN_HINT.findall(lower))
    if de_hits >= 2 and en_hits < 2:
        return False
    return True


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


def load_words(csv_dir: Path) -> dict[int, dict]:
    path = csv_dir / "openrussian_public - words.csv"
    out: dict[int, dict] = {}
    with path.open(encoding="utf-8-sig", newline="") as f:
        for row in csv.DictReader(f):
            if row.get("disabled", "1") != "0":
                continue
            typ = (row.get("type") or "").strip().lower()
            if not typ or typ not in ALLOWED_TYPES:
                continue
            out[int(row["id"])] = row
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
    for wid in by_word:
        by_word[wid].sort(
            key=lambda r: (
                int(r["position"]) if str(r.get("position", "")).strip().isdigit() else 999,
                int(r.get("id") or 0) if str(r.get("id", "")).strip().isdigit() else 0,
            )
        )
    return by_word


def word_rank(row: dict) -> int:
    try:
        return int((row.get("rank") or "").strip())
    except ValueError:
        return 999_999


def index_by_bare(
    words: dict[int, dict],
    translations: dict[int, list[dict]],
) -> dict[str, list[int]]:
    """normalized bare -> [word_id, ...] with EN translations."""
    by_bare: dict[str, list[int]] = defaultdict(list)
    for wid, row in words.items():
        if wid not in translations:
            continue
        bare = (row.get("bare") or "").strip()
        if not bare:
            continue
        by_bare[normalize_for_index(bare)].append(wid)
    return by_bare


def pick_word_id(candidates: list[int], words: dict[int, dict]) -> int | None:
    if not candidates:
        return None
    return min(candidates, key=lambda wid: word_rank(words[wid]))


def _ru_token_count(ru: str) -> int:
    return len(re.findall(r"[а-яёА-ЯЁ]+", normalize_for_index(ru.replace("'", ""))))


def sentence_link_sort_key(form_type: str, ru: str, link_id: int) -> tuple:
    """
    Prefer short, dictionary-form examples. The public CSV has no per-word
    ``position`` for sentences (website order lives in their live DB only).
    """
    ft = (form_type or "").strip().lower()
    inflected = 0 if (not ft or ft == "ru_base") else 1
    tokens = _ru_token_count(ru)
    if tokens < 3:
        length_rank = 10 + (3 - tokens)
    elif tokens <= 8:
        length_rank = abs(tokens - 4)
    else:
        length_rank = tokens + 5
    too_long = max(0, len(ru) - 80)
    return (inflected, length_rank, too_long, link_id)


def load_sentence_examples(
    csv_dir: Path,
    word_ids: set[int],
    *,
    max_per_word: int = MAX_EXAMPLES,
) -> dict[int, list[tuple[str, str]]]:
    sw_path = csv_dir / "openrussian_public - sentences_words.csv"
    st_path = csv_dir / "openrussian_public - sentences_translations.csv"
    s_path = csv_dir / "openrussian_public - sentences.csv"

    sentence_en: dict[int, str] = {}
    with st_path.open(encoding="utf-8-sig", newline="") as f:
        for row in csv.DictReader(f):
            sid = int(row["sentence_id"])
            en = (row.get("tl_en") or "").strip()
            if en and is_likely_english(en):
                sentence_en[sid] = en

    sentence_meta: dict[int, dict] = {}
    with s_path.open(encoding="utf-8-sig", newline="") as f:
        for row in csv.DictReader(f):
            sid = int(row["id"])
            if row.get("disabled", "0") != "0":
                continue
            if sid not in sentence_en:
                continue
            ru = (row.get("ru") or "").strip()
            if ru:
                sentence_meta[sid] = row

    buckets: dict[int, list[tuple[tuple, str, str]]] = defaultdict(list)
    print(f"Linking OpenRussian sentences for {len(word_ids):,} lemmas…", flush=True)
    with sw_path.open(encoding="utf-8-sig", newline="") as f:
        for row in csv.DictReader(f):
            wid = int(row["word_id"])
            if wid not in word_ids:
                continue
            sid = int(row["sentence_id"])
            meta = sentence_meta.get(sid)
            if not meta:
                continue
            ru = (meta.get("ru") or "").strip()
            en = sentence_en.get(sid, "").strip()
            if not ru or not en:
                continue
            link_id = int(row["id"]) if str(row.get("id", "")).strip().isdigit() else 0
            sort_key = sentence_link_sort_key(row.get("form_type") or "", ru, link_id)
            buckets[wid].append((sort_key, ru, en))

    out: dict[int, list[tuple[str, str]]] = {}
    for wid, items in buckets.items():
        items.sort(key=lambda x: x[0])
        out[wid] = [(ru, en) for _, ru, en in items[:max_per_word]]
    return out


def format_examples(
    trans_rows: list[dict],
    sentence_pairs: list[tuple[str, str]],
    gloss_tokens: set[str],
) -> str | None:
    lines: list[str] = []
    seen_ru: set[str] = set()
    seen_en: set[str] = set()

    def add(ru: str, en: str, *, require_align: bool) -> None:
        if len(lines) >= MAX_EXAMPLES:
            return
        ru_t, en_t = ru.strip(), en.strip()
        if not ru_t or not en_t:
            return
        if require_align and not example_aligns(en_t, gloss_tokens):
            return
        rk = normalize_for_index(ru_t)
        ek = re.sub(r"\s+", " ", en_t.lower())
        if rk in seen_ru or ek in seen_en:
            return
        seen_ru.add(rk)
        seen_en.add(ek)
        lines.append(f"{ru_t}{EXAMPLE_FIELD_SEP}{en_t}")

    for row in trans_rows:
        ru = (row.get("example_ru") or "").strip()
        en = (row.get("example_tl") or "").strip()
        if ru and en and is_likely_english(en):
            add(ru, en, require_align=False)

    # Keep OpenRussian sentence order; gloss filter is for Tatoeba fill-in only.
    for ru, en in sentence_pairs:
        add(ru, en, require_align=False)

    return "\n".join(lines) if lines else None


def build_entry(
    wid: int,
    row: dict,
    trans_rows: list[dict],
    sentence_pairs: list[tuple[str, str]],
    *,
    is_common: bool,
    used_ids: set[str],
) -> tuple | None:
    bare = (row.get("bare") or "").strip()
    if not bare:
        return None

    gloss_lines: list[str] = []
    for tr in trans_rows:
        gloss_lines.extend(split_translation_glosses(tr["tl"]))
    if not gloss_lines:
        return None

    headline = gloss_lines[0]
    if len(headline) > MAX_GLOSS_LEN:
        headline = headline[: MAX_GLOSS_LEN - 1].rstrip() + "…"
    extra = gloss_lines[1:]
    meaning = "; ".join(extra[:4]) if extra else None
    if meaning and len(meaning) > MAX_MEANING_LEN:
        meaning = meaning[: MAX_MEANING_LEN - 1].rstrip() + "…"
    glosses_blob = "\n".join(gloss_lines[:5])

    pos = POS_MAP.get((row.get("type") or "").strip().lower(), row.get("type"))
    accented = (row.get("accented") or "").strip()
    usage = (row.get("usage_en") or "").strip()
    phonetic = learner_phonetic(accented, bare)

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
        phonetic,
        normalize_for_index(bare),
        normalize_for_index(headline),
        1 if is_common else 0,
    )


def build(args: argparse.Namespace) -> int:
    csv_dir: Path = args.csv_dir
    if not (csv_dir / "openrussian_public - words.csv").exists():
        print(
            f"Missing CSVs in {csv_dir}. Run: python3 scripts/download_openrussian.py",
            file=sys.stderr,
        )
        return 1

    print(f"Loading OpenRussian words from {csv_dir}…")
    words = load_words(csv_dir)
    print(f"  ↳ {len(words):,} enabled lemmas (allowed types)")

    print("Loading EN translations…")
    translations = load_en_translations(csv_dir)
    with_en = sum(1 for wid in words if wid in translations)
    print(f"  ↳ {with_en:,} with English")

    by_bare = index_by_bare(words, translations)

    print(f"Reading frequency list: {args.freq}")
    freq = read_frequency(args.freq)
    common_set = set(freq[: args.common_limit])
    print(f"  ↳ {len(freq)} ranked; top {len(common_set)} → is_common")

    geo = load_geo_blocklist(GEO_BLOCKLIST)

    selected: list[tuple[str, int]] = []
    missing_or = 0
    for lemma in freq:
        if not is_clean_lemma(lemma):
            continue
        if lemma in geo:
            continue
        cands = by_bare.get(normalize_for_index(lemma), [])
        wid = pick_word_id(cands, words)
        if wid is None:
            missing_or += 1
            continue
        selected.append((lemma, wid))

    print(f"  ↳ {len(selected):,} freq lemmas matched OpenRussian ({missing_or:,} missing)")

    word_ids = {wid for _, wid in selected}
    sentence_map = load_sentence_examples(csv_dir, word_ids)

    used_ids: set[str] = set()
    rows: list[tuple] = []
    for lemma, wid in selected:
        row = words[wid]
        entry = build_entry(
            wid,
            row,
            translations[wid],
            sentence_map.get(wid, []),
            is_common=lemma in common_set,
            used_ids=used_ids,
        )
        if entry:
            rows.append(entry)

    with_ex = sum(1 for r in rows if r[6])
    print(
        f"  ↳ built {len(rows):,} entries; {sum(1 for r in rows if r[11])} common; "
        f"{with_ex:,} with OpenRussian examples"
    )

    out_path: Path = args.out
    out_path.parent.mkdir(parents=True, exist_ok=True)
    if out_path.exists():
        out_path.unlink()

    print(f"Writing SQLite: {out_path}")
    conn = sqlite3.connect(out_path, isolation_level=None)
    try:
        conn.executescript(
            "PRAGMA synchronous=OFF;"
            "PRAGMA journal_mode=MEMORY;"
            "PRAGMA temp_store=MEMORY;"
        )
        conn.executescript(SCHEMA_SQL)
        conn.execute("BEGIN")
        conn.execute("DELETE FROM dictionary_version")
        conn.execute(
            "INSERT INTO dictionary_version(value) VALUES (?)",
            (DICTIONARY_VERSION,),
        )
        conn.executemany(
            "INSERT INTO words(id, ru, en, meaning_en, pos, glosses_en, examples_en, ai_note_en, "
            "phonetic, ru_norm, en_norm, is_common) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
            rows,
        )
        conn.executemany(
            "INSERT INTO words_fts(id, ru, en) VALUES (?, ?, ?)",
            ((r[0], r[9], r[10]) for r in rows),
        )
        conn.execute("COMMIT")
        conn.executescript("PRAGMA optimize;")
        conn.execute("VACUUM")
    finally:
        conn.close()

    size_mb = out_path.stat().st_size / (1024 * 1024)
    print(f"Done. dictionary_version={DICTIONARY_VERSION}, {size_mb:.2f} MB.")
    print(
        "Next: python3 scripts/enrich_dictionary_tatoeba.py --from-dump --resume "
        f"--db {out_path}"
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Build dictionary.sqlite from OpenRussian")
    parser.add_argument("--csv-dir", type=Path, default=DEFAULT_CSV_DIR)
    parser.add_argument("--freq", type=Path, default=DEFAULT_FREQ)
    parser.add_argument("--common-limit", type=int, default=5000)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    args = parser.parse_args()
    return build(args)


if __name__ == "__main__":
    raise SystemExit(main())
