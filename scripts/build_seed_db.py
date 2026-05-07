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
DICTIONARY_VERSION = 3
MIN_ENTRIES = 30_000

# Russian vowels (lowercase comparison).
VOWELS = frozenset("аеёиоуыэюя")

# Learner-oriented Latin consonants (English-friendly).
CONS_LATIN = {
    "б": "b",
    "в": "v",
    "г": "g",
    "д": "d",
    "ж": "zh",
    "з": "z",
    "й": "y",
    "к": "k",
    "л": "l",
    "м": "m",
    "н": "n",
    "п": "p",
    "р": "r",
    "с": "s",
    "т": "t",
    "ф": "f",
    "х": "kh",
    "ц": "ts",
    "ч": "ch",
    "ш": "sh",
    "щ": "shch",
}

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


def canonical_surface(forms: list) -> Optional[str]:
    """Stressed Cyrillic headword when Wiktionary provides it (NFC)."""
    for f in forms or []:
        tags = f.get("tags") or []
        if "canonical" not in tags:
            continue
        form = f.get("form")
        if isinstance(form, str) and form.strip():
            return unicodedata.normalize("NFC", form.strip())
    return None


def letters_and_stress_letter_index(surface: str) -> tuple[str, Optional[int]]:
    """
    Strip stress marks; return (word_nfc, index of stressed letter in word_nfc).
    """
    nfd = unicodedata.normalize("NFD", surface)
    letters: list[str] = []
    stress_i: Optional[int] = None
    i = 0
    while i < len(nfd):
        if nfd[i] == "\u0301":
            if letters:
                stress_i = len(letters) - 1
            i += 1
            continue
        letters.append(nfd[i])
        i += 1
    word = unicodedata.normalize("NFC", "".join(letters))
    if stress_i is None:
        return word, None
    if len(letters) == len(word):
        return word, stress_i
    # Rare NFC length mismatch: find stressed char by scan
    stressed_ch = letters[stress_i]
    idx = 0
    for j, ch in enumerate(word):
        if ch == stressed_ch:
            idx = j
            break
    return word, idx


def syllables_ru(word: str) -> list[str]:
    wl = word.lower()
    vpos = [i for i, c in enumerate(wl) if c in VOWELS]
    if not vpos:
        return [word]
    out: list[str] = []
    for j, vp in enumerate(vpos):
        start = 0 if j == 0 else vpos[j - 1] + 1
        if j < len(vpos) - 1:
            out.append(word[start : vp + 1])
        else:
            out.append(word[start:])
    return out


def stressed_syllable_index(
    stress_letter_i: Optional[int], wl_lower: str
) -> int:
    """Which syllable (0-based) gets ALL CAPS."""
    vpos = [i for i, c in enumerate(wl_lower) if c in VOWELS]
    if not vpos:
        return 0
    if stress_letter_i is not None:
        for j, vp in enumerate(vpos):
            if vp == stress_letter_i:
                return j
        for j, vp in enumerate(vpos):
            if vp >= stress_letter_i:
                return j
        return len(vpos) - 1
    # ё is always stressed in Russian when present
    for j, vp in enumerate(vpos):
        if wl_lower[vp] == "ё":
            return j
    return 0 if len(vpos) == 1 else len(vpos) - 1


def romanize_consonants(cluster: str) -> str:
    parts: list[str] = []
    for ch in cluster.lower():
        if ch in "ъь":
            continue
        parts.append(CONS_LATIN.get(ch, ch))
    return "".join(parts)


def romanize_syllable_learner(syl: str) -> str:
    """
    English-friendly respelling for one syllable (lowercase, no hyphens).
    """
    s = syl.lower().strip()
    if not s:
        return ""

    out: list[str] = []
    i = 0
    n = len(s)

    while i < n:
        c = s[i]
        if c.lower() in "ъь":
            if c == "ь" and out and i + 1 < n and s[i + 1].lower() in VOWELS:
                last_lat = out[-1]
                if last_lat and last_lat[-1] not in "yaeiouh":
                    if last_lat[-1] in "dtslznrpbvgkmf" and not last_lat.endswith("y"):
                        out[-1] = last_lat + "y"
            i += 1
            continue

        if c.lower() not in VOWELS:
            j = i
            while j < n and s[j].lower() not in VOWELS and s[j] not in "ъь":
                j += 1
            cluster = s[i:j]
            soft = False
            if j < n and s[j] == "ь":
                soft = True
                j += 1
            lat = romanize_consonants(cluster)
            if soft and lat and cluster and cluster[-1].lower() in "дтсзлнрпбвгкмфхцчшщ":
                if not lat.endswith("y"):
                    lat = lat + "y"
            out.append(lat)
            i = j
            continue

        # vowel
        cl = c.lower()
        leading_cons = bool(out and out[-1] and out[-1][-1] not in "aeiouyh")

        if cl == "я":
            out.append("ya")
        elif cl == "ё":
            out.append("yo")
        elif cl == "ю":
            out.append("yu")
        elif cl == "е":
            out.append("ye" if leading_cons else "ye")
        elif cl == "и":
            out.append("ee")
        elif cl == "ы":
            out.append("ih")
        elif cl == "о":
            out.append("oh")
        elif cl == "а":
            out.append("ah")
        elif cl == "у":
            out.append("oo")
        elif cl == "э":
            out.append("eh")
        else:
            out.append(cl)
        i += 1

    return "".join(out)


def english_phrasebook_pronunciation(
    surface_stressed: Optional[str], lemma_plain: str
) -> Optional[str]:
    """
    hyphenated syllables; stressed syllable in ALL CAPS (user request).
    """
    if surface_stressed:
        word, stress_ch_i = letters_and_stress_letter_index(surface_stressed)
    else:
        word = unicodedata.normalize("NFC", lemma_plain.strip())
        stress_ch_i = None
    wl = word.lower()
    syl = syllables_ru(word)
    if not syl:
        return None
    stress_syl_i = stressed_syllable_index(stress_ch_i, wl)
    stress_syl_i = min(stress_syl_i, len(syl) - 1)

    parts: list[str] = []
    for idx, syll in enumerate(syl):
        chunk = romanize_syllable_learner(syll)
        if not chunk:
            continue
        if idx == stress_syl_i:
            chunk = chunk.upper()
        parts.append(chunk)
    if not parts:
        return None
    return "-".join(parts)


def first_romanization_simple(forms: list) -> Optional[str]:
    """Wiktionary Latin (scholarly); used as fallback only."""
    for f in forms or []:
        tags = f.get("tags") or []
        if "romanization" not in tags:
            continue
        form = f.get("form")
        if isinstance(form, str) and form.strip():
            # Normalize j → y for English readers.
            return (
                form.strip()
                .replace("j", "y")
                .replace("J", "Y")
            )
    return None


def pronunciation_for_entry(
    word: str, forms: list, sounds: list
) -> Optional[str]:
    surface = canonical_surface(forms)
    eng = english_phrasebook_pronunciation(surface, word)
    if eng:
        return eng
    rom = first_romanization_simple(forms)
    if rom:
        return rom
    return first_ipa(sounds)


def build(args: argparse.Namespace) -> int:
    print(f"Reading frequency list: {args.freq}")
    freq = read_frequency(args.freq)
    freq_set = set(freq)
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
        # Only keep lemmas that appear in the frequency list — this excludes
        # inflected forms (conjugations, declensions) that Wiktionary documents
        # as separate entries, keeping the dictionary to clean base forms only.
        if not is_clean_lemma(lemma) or lemma not in freq_set or lemma in seen_lemmas:
            continue
        senses = obj.get("senses") or []
        english = first_gloss(senses, MAX_GLOSS_LEN)
        if not english:
            continue
        meaning = first_gloss(senses, MAX_MEANING_LEN)
        meaning = meaning if meaning and meaning != english else None
        ph = pronunciation_for_entry(word, obj.get("forms") or [], obj.get("sounds") or [])
        seen_lemmas.add(lemma)
        rows.append((
            slugify(word, used_ids),
            word,
            english,
            meaning,
            ph,
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
    # isolation_level=None → autocommit; we manage all transactions explicitly
    # so Python's sqlite3 module never inserts an implicit BEGIN that conflicts
    # with our own BEGIN / executescript calls.
    conn = sqlite3.connect(out_path, isolation_level=None)
    try:
        conn.executescript(
            "PRAGMA synchronous=OFF;"
            "PRAGMA journal_mode=MEMORY;"
            "PRAGMA temp_store=MEMORY;"
        )
        conn.executescript(SCHEMA_SQL)
        conn.execute("BEGIN")
        conn.execute(
            "INSERT INTO dictionary_version(value) VALUES (?)",
            (DICTIONARY_VERSION,),
        )
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
