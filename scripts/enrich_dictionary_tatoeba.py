#!/usr/bin/env python3
"""
Enrich dictionary.sqlite with short RU→EN example sentences from Tatoeba (build-time).

Preferred: weekly Tatoeba exports (no API rate limits):
  python3 scripts/enrich_dictionary_tatoeba.py --download
  python3 scripts/enrich_dictionary_tatoeba.py --from-dump --db RussianWordADayApp/Resources/dictionary.sqlite

Optional: live API for spot checks (slow; be polite):
  python3 scripts/enrich_dictionary_tatoeba.py --api --words "вздор,ерунда"

License: Tatoeba text is typically CC BY 2.0 FR — attribute in-app (see LegalContent).
"""

from __future__ import annotations

import argparse
import bz2
import json
import re
import sqlite3
import sys
import time
import unicodedata
import urllib.parse
import urllib.request
from collections import defaultdict
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent
DEFAULT_TATOEBA_DIR = PROJECT_ROOT / "data" / "tatoeba"

TATOEBA_BASE = "https://downloads.tatoeba.org/exports/per_language"
DUMP_FILES = {
    "rus_sentences.tsv.bz2": f"{TATOEBA_BASE}/rus/rus_sentences.tsv.bz2",
    "rus-eng_links.tsv.bz2": f"{TATOEBA_BASE}/rus/rus-eng_links.tsv.bz2",
    "eng_sentences.tsv.bz2": f"{TATOEBA_BASE}/eng/eng_sentences.tsv.bz2",
}

API = "https://tatoeba.org/en/api_v0/search"
USER_AGENT = "RussianWordADay-bake/1.0 (tatoeba examples; local build)"

DICTIONARY_VERSION = 32
DEFAULT_MAX_EXAMPLES = 6
DEFAULT_SLEEP_SEC = 0.12
MAX_CANDIDATES_PER_LEMMA = 80

MAX_RU_CHARS = 68
MAX_EN_CHARS = 90
MAX_RU_TOKENS = 10
MAX_COMMAS = 1

MIN_STEM_LEN = 4
MAX_INFLECTION_EXTRA = 10

_CYR_WORD = r"[а-яёА-ЯЁ]+"

# Strip common Russian endings to get a prefix stem for inflection matching in
# Tatoeba sentences. Does not add inflected forms to the dictionary — examples only.
_RU_LEMMA_SUFFIXES = (
    "ироваться",
    "ироват",
    "ться",
    "тись",
    "иться",
    "ать",
    "ять",
    "еть",
    "уть",
    "оть",
    "чь",
    "ти",
    "ить",
    "ение",
    "ание",
    "ость",
    "ство",
    "ия",
    "ие",
    "ий",
    "ые",
    "ая",
    "ое",
    "ой",
    "а",
    "я",
    "о",
    "е",
    "ы",
    "и",
)


def normalize(s: str) -> str:
    t = unicodedata.normalize("NFC", s).lower()
    t = t.replace("\u0301", "")
    return t.replace("ё", "е")


def normalize_ru_example_key(s: str) -> str:
    """Dedupe key for example sentences; ignores trailing .!?…"""
    t = normalize(s.strip())
    return re.sub(r"[.!?…]+$", "", t).strip()


def lemma_stem(lemma: str) -> str:
    """Prefix stem for matching inflected Tatoeba tokens to a dictionary headword."""
    w = normalize(lemma)
    if len(w) < MIN_STEM_LEN:
        return w
    for suf in _RU_LEMMA_SUFFIXES:
        if w.endswith(suf) and len(w) - len(suf) >= MIN_STEM_LEN:
            return w[: -len(suf)]
    return w


def token_matches_lemma(
    token: str,
    lemma: str,
    *,
    headword_norms: set[str],
    lemma_stems: dict[str, str] | None = None,
) -> bool:
    tok = normalize(token)
    lem = normalize(lemma)
    if not tok or not lem:
        return False
    if tok == lem:
        return True
    if tok in headword_norms and tok != lem:
        return False
    stem = (lemma_stems or {}).get(lem) or lemma_stem(lem)
    if len(stem) < MIN_STEM_LEN:
        return False
    if not tok.startswith(stem):
        return False
    if len(tok) > len(lem) + MAX_INFLECTION_EXTRA:
        return False
    return True


def sentence_matches_lemma(
    sentence_ru: str,
    lemma_ru: str,
    *,
    headword_norms: set[str],
    lemma_stems: dict[str, str] | None = None,
) -> bool:
    for token in re.findall(_CYR_WORD, sentence_ru):
        if token_matches_lemma(
            token,
            lemma_ru,
            headword_norms=headword_norms,
            lemma_stems=lemma_stems,
        ):
            return True
    return False


def build_stem_index(headword_norms: set[str]) -> tuple[dict[str, str], dict[str, list[str]]]:
    """lemma_norm -> stem; stem -> [lemma_norm, ...] (longest stems win at lookup)."""
    lemma_stems: dict[str, str] = {}
    stem_index: dict[str, list[str]] = defaultdict(list)
    for norm in headword_norms:
        stem = lemma_stem(norm)
        lemma_stems[norm] = stem
        if stem not in stem_index or norm not in stem_index[stem]:
            stem_index[stem].append(norm)
    return lemma_stems, stem_index


def lemmas_matching_token(
    token: str,
    *,
    headword_norms: set[str],
    lemma_stems: dict[str, str],
    stem_index: dict[str, list[str]],
) -> set[str]:
    tok = normalize(token)
    if not tok:
        return set()
    if tok in headword_norms:
        return {tok}
    matched: set[str] = set()
    for length in range(len(tok), MIN_STEM_LEN - 1, -1):
        stem = tok[:length]
        for lemma_norm in stem_index.get(stem, ()):
            if token_matches_lemma(
                tok,
                lemma_norm,
                headword_norms=headword_norms,
                lemma_stems=lemma_stems,
            ):
                matched.add(lemma_norm)
        if matched:
            break
    return matched


def token_count_ru(s: str) -> int:
    return len(re.findall(_CYR_WORD, normalize(s)))


def is_bad_example(ru: str, en: str) -> bool:
    ru_t = ru.strip()
    en_t = en.strip()
    if not ru_t or not en_t:
        return True
    if len(ru_t) > MAX_RU_CHARS or len(en_t) > MAX_EN_CHARS:
        return True
    if token_count_ru(ru_t) > MAX_RU_TOKENS:
        return True
    if ru_t.count(",") > MAX_COMMAS or en_t.count(",") > MAX_COMMAS:
        return True
    if ru_t.count('"') >= 2 or "«" in ru_t or "»" in ru_t:
        return True
    if "http://" in ru_t or "https://" in ru_t:
        return True
    return False


def score_example(ru: str, en: str) -> float:
    ru_t = ru.strip()
    en_t = en.strip()
    score = 0.0
    score += len(ru_t) * 1.0
    score += len(en_t) * 0.35
    score += ru_t.count(",") * 20
    score += en_t.count(",") * 10
    score += token_count_ru(ru_t) * 2
    ru_n = normalize(ru_t)
    if ru_n.startswith("это "):
        score -= 18
    if ru_n.startswith("не "):
        score -= 10
    if ru_n.startswith("что за "):
        score -= 14
    if ru_t.endswith(".") or ru_t.endswith("?") or ru_t.endswith("!"):
        score -= 6
    if ";" in ru_t or ":" in ru_t:
        score += 18
    return score


def normalize_en_key(s: str) -> str:
    """Normalize English gloss for deduping near-duplicate Tatoeba translations."""
    t = normalize(s.strip())
    t = t.replace("'", "'").replace("'", "'")
    t = re.sub(r"[-‐‑–—]", " ", t)
    t = re.sub(r"[^\w\s]", "", t)
    return re.sub(r"\s+", " ", t).strip()


EXAMPLE_FIELD_SEP = "\t"


def format_line(ru: str, en: str, include_author: bool, author: str = "") -> str:
    # Tab between RU and EN so Russian em dashes (Том — бездомный) do not break parsing.
    line = f"{ru.strip()}{EXAMPLE_FIELD_SEP}{en.strip()}"
    if include_author and author:
        line = f"{line} (Tatoeba: {author})"
    return line


def gloss_tokens_for_word(glosses_en: str | None, en_head: str) -> set[str]:
    toks: set[str] = set()
    blob = "\n".join(filter(None, [glosses_en or "", en_head or ""]))
    for line in blob.split("\n"):
        for part in re.split(r"[,;]", line):
            for word in part.split():
                w = re.sub(r"[^\w]", "", word.strip().lower())
                if len(w) >= 3:
                    toks.add(w)
    return toks


def example_aligns_gloss(en: str, gloss_tokens: set[str]) -> bool:
    if not gloss_tokens:
        return True
    words = set(re.findall(r"[a-z]{3,}", en.lower()))
    return bool(words & gloss_tokens)


def pick_best_lines(
    pairs: list[tuple[str, str]],
    max_examples: int,
    include_author: bool,
    *,
    gloss_tokens: set[str] | None = None,
    require_gloss_align: bool = False,
) -> list[str]:
    """One line per unique Russian and per unique English (best score wins)."""
    candidates: list[tuple[float, str, str]] = []
    for ru, en in pairs:
        if is_bad_example(ru, en):
            continue
        en_t = en.strip()
        if require_gloss_align and gloss_tokens and not example_aligns_gloss(en_t, gloss_tokens):
            continue
        candidates.append((score_example(ru, en), ru.strip(), en_t))
    candidates.sort(key=lambda x: x[0])

    seen_ru: set[str] = set()
    seen_en: set[str] = set()
    lines: list[str] = []
    for _score, ru, en in candidates:
        ru_key = normalize_ru_example_key(ru)
        en_key = normalize_en_key(en)
        if ru_key in seen_ru or en_key in seen_en:
            continue
        seen_ru.add(ru_key)
        seen_en.add(en_key)
        lines.append(format_line(ru, en, include_author))
        if len(lines) >= max_examples:
            break
    return lines


def download_dump_files(tatoeba_dir: Path) -> None:
    tatoeba_dir.mkdir(parents=True, exist_ok=True)
    for name, url in DUMP_FILES.items():
        dest = tatoeba_dir / name
        if dest.exists() and dest.stat().st_size > 0:
            print(f"  skip (exists): {dest.name}")
            continue
        print(f"  downloading {name} …")
        req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(req, timeout=600) as resp:
            data = resp.read()
        dest.write_bytes(data)
        print(f"  wrote {dest.name} ({len(data) / 1_048_576:.1f} MB)")


def open_bz2_lines(path: Path):
    with bz2.open(path, "rt", encoding="utf-8", errors="replace") as f:
        for line in f:
            yield line.rstrip("\n")


def load_headword_map(conn: sqlite3.Connection) -> dict[str, list[tuple[str, str]]]:
    """normalized lemma -> [(word_id, surface_ru), ...]"""
    out: dict[str, list[tuple[str, str]]] = defaultdict(list)
    for wid, ru in conn.execute("SELECT id, ru FROM words"):
        key = normalize(ru)
        if key:
            out[key].append((str(wid), ru))
    return out


def index_rus_sentences(
    rus_path: Path,
    headword_norms: set[str],
    lemma_stems: dict[str, str],
    stem_index: dict[str, list[str]],
) -> tuple[dict[str, list[tuple[int, str]]], set[int]]:
    """
    lemma_norm -> [(rus_id, rus_text), ...] capped per lemma.
    Matches dictionary headwords and inflected surface forms (examples only).
    """
    buckets: dict[str, list[tuple[int, str]]] = defaultdict(list)
    rus_ids: set[int] = set()
    n = 0
    for line in open_bz2_lines(rus_path):
        parts = line.split("\t", 2)
        if len(parts) < 3:
            continue
        try:
            sid = int(parts[0])
        except ValueError:
            continue
        text = parts[2].strip()
        if not text:
            continue
        n += 1
        if n % 200_000 == 0:
            print(f"  … scanned {n:,} Russian sentences", flush=True)

        matched: set[str] = set()
        for token in re.findall(_CYR_WORD, text):
            matched |= lemmas_matching_token(
                token,
                headword_norms=headword_norms,
                lemma_stems=lemma_stems,
                stem_index=stem_index,
            )
        if not matched:
            continue

        for lemma_norm in matched:
            bucket = buckets[lemma_norm]
            if len(bucket) >= MAX_CANDIDATES_PER_LEMMA:
                continue
            bucket.append((sid, text))
            rus_ids.add(sid)

    print(f"  indexed {n:,} Russian sentences; {len(rus_ids):,} linked to dictionary lemmas", flush=True)
    return buckets, rus_ids


def load_rus_eng_links(links_path: Path, rus_ids: set[int]) -> dict[int, list[int]]:
    """rus_id -> [eng_id, ...]"""
    out: dict[int, list[int]] = defaultdict(list)
    n = 0
    for line in open_bz2_lines(links_path):
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        try:
            a = int(parts[0])
            b = int(parts[1])
        except ValueError:
            continue
        n += 1
        # rus-eng_links.tsv.bz2 rows are Russian_id [tab] English_id
        if a in rus_ids:
            out[a].append(b)
    print(f"  loaded {n:,} rus↔eng link rows for {len(out):,} Russian ids", flush=True)
    return out


def load_eng_texts(eng_path: Path, needed_ids: set[int]) -> dict[int, str]:
    out: dict[int, str] = {}
    if not needed_ids:
        return out
    n = 0
    for line in open_bz2_lines(eng_path):
        parts = line.split("\t", 2)
        if len(parts) < 3:
            continue
        try:
            sid = int(parts[0])
        except ValueError:
            continue
        if sid not in needed_ids:
            continue
        out[sid] = parts[2].strip()
        if len(out) >= len(needed_ids):
            break
        n += 1
        if n % 100_000 == 0:
            print(f"  … loaded {len(out):,} / {len(needed_ids):,} English sentences", flush=True)
    print(f"  loaded {len(out):,} English sentence texts", flush=True)
    return out


def enrich_from_dump(
    conn: sqlite3.Connection,
    tatoeba_dir: Path,
    *,
    resume: bool,
    max_examples: int,
    include_author: bool,
    dry_run: bool,
    words_filter: list[str] | None,
) -> None:
    rus_path = tatoeba_dir / "rus_sentences.tsv.bz2"
    links_path = tatoeba_dir / "rus-eng_links.tsv.bz2"
    eng_path = tatoeba_dir / "eng_sentences.tsv.bz2"
    for p in (rus_path, links_path, eng_path):
        if not p.exists():
            raise FileNotFoundError(
                f"Missing {p.name}. Run: python3 scripts/enrich_dictionary_tatoeba.py --download"
            )

    headword_map = load_headword_map(conn)
    headword_norms = set(headword_map.keys())
    if words_filter:
        filt = {normalize(w) for w in words_filter}
        headword_norms &= filt
        headword_map = {k: v for k, v in headword_map.items() if k in filt}

    lemma_stems, stem_index = build_stem_index(headword_norms)
    print(
        f"Indexing Russian Tatoeba sentences (headwords + inflections, "
        f"{len(stem_index):,} stems)…",
        flush=True,
    )
    buckets, rus_ids = index_rus_sentences(
        rus_path, headword_norms, lemma_stems, stem_index
    )

    print("Loading rus↔eng links…", flush=True)
    rus_to_eng = load_rus_eng_links(links_path, rus_ids)

    needed_eng: set[int] = set()
    for eng_list in rus_to_eng.values():
        needed_eng.update(eng_list)

    print("Loading English sentence texts…", flush=True)
    eng_text = load_eng_texts(eng_path, needed_eng)

    # Build pairs per lemma
    lemma_pairs: dict[str, list[tuple[str, str]]] = defaultdict(list)
    for lemma_norm, candidates in buckets.items():
        for rus_id, ru_text in candidates:
            for eng_id in rus_to_eng.get(rus_id, []):
                en_text = eng_text.get(eng_id)
                if not en_text:
                    continue
                lemma_pairs[lemma_norm].append((ru_text, en_text))

    updated = empty = 0

    conn.execute("BEGIN IMMEDIATE")
    for lemma_norm, entries in headword_map.items():
        for wid, surface_ru in entries:
            gloss_row = conn.execute(
                "SELECT COALESCE(examples_en,''), glosses_en, en FROM words WHERE id = ?",
                (wid,),
            ).fetchone()
            if resume and gloss_row and str(gloss_row[0]).strip():
                continue

            pairs = lemma_pairs.get(lemma_norm, [])
            gloss_tokens = gloss_tokens_for_word(
                str(gloss_row[1]) if gloss_row else None,
                str(gloss_row[2]) if gloss_row else "",
            )

            lines = pick_best_lines(
                pairs,
                max_examples=max(1, min(max_examples, 10)),
                include_author=include_author,
                gloss_tokens=gloss_tokens,
                require_gloss_align=True,
            )
            if not lines:
                empty += 1
                continue

            if dry_run:
                print(f"\n{surface_ru} →")
                for j, ln in enumerate(lines, 1):
                    print(f"  {j}. {ln}")
            else:
                conn.execute(
                    "UPDATE words SET examples_en = ? WHERE id = ?",
                    ("\n".join(lines), wid),
                )
            updated += 1

    if not dry_run:
        conn.execute("DELETE FROM dictionary_version")
        conn.execute("INSERT INTO dictionary_version(value) VALUES (?)", (DICTIONARY_VERSION,))
        conn.execute("COMMIT")
        print(f"Done. {updated} words updated, {empty} without examples; dictionary_version={DICTIONARY_VERSION}", flush=True)
    else:
        conn.execute("ROLLBACK")
        print(f"Dry run: {updated} words would update, {empty} empty", flush=True)


# --- Optional live API path (small batches only) ---


def fetch_tatoeba_api(headword_ru: str, limit: int = 30) -> list[dict]:
    qs = urllib.parse.urlencode(
        {
            "from": "rus",
            "to": "eng",
            "query": headword_ru,
            "orphans": "no",
            "unapproved": "no",
            "page": 1,
            "perPage": min(max(limit, 5), 50),
        }
    )
    url = f"{API}?{qs}"
    req = urllib.request.Request(
        url,
        headers={"Accept": "application/json", "User-Agent": USER_AGENT},
        method="GET",
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    return data.get("results") or []


def best_pairs_api(
    headword_ru: str,
    max_examples: int,
    include_author: bool,
    *,
    headword_norms: set[str],
    lemma_stems: dict[str, str],
    gloss_tokens: set[str] | None = None,
) -> list[str]:
    pairs: list[tuple[str, str]] = []
    for r in fetch_tatoeba_api(headword_ru, limit=35):
        ru = (r.get("text") or "").strip()
        if not ru or not sentence_matches_lemma(
            ru,
            headword_ru,
            headword_norms=headword_norms,
            lemma_stems=lemma_stems,
        ):
            continue
        en = ""
        for group in r.get("translations") or []:
            if not isinstance(group, list):
                continue
            for t in group:
                if isinstance(t, dict) and t.get("lang") == "eng":
                    en = (t.get("text") or "").strip()
                    if en:
                        break
            if en:
                break
        if en:
            pairs.append((ru, en))
    return pick_best_lines(
        pairs,
        max_examples,
        include_author,
        gloss_tokens=gloss_tokens,
        require_gloss_align=True,
    )


def enrich_via_api(
    conn: sqlite3.Connection,
    *,
    resume: bool,
    limit: int,
    max_examples: int,
    sleep_sec: float,
    include_author: bool,
    dry_run: bool,
    words_filter: list[str] | None,
) -> None:
    where_parts: list[str] = []
    binds: list[str] = []
    if resume:
        where_parts.append("COALESCE(examples_en,'') = ''")
    if words_filter:
        where_parts.append(f"ru IN ({','.join(['?'] * len(words_filter))})")
        binds.extend(words_filter)
    where = f"WHERE {' AND '.join(where_parts)}" if where_parts else ""
    rows = list(
        conn.execute(
            f"SELECT id, ru FROM words {where} ORDER BY is_common DESC, ru COLLATE NOCASE",
            binds,
        )
    )
    if not words_filter and limit > 0:
        rows = rows[:limit]

    headword_norms = {
        normalize(r[1]) for r in conn.execute("SELECT ru FROM words") if normalize(r[1])
    }
    lemma_stems, _stem_index = build_stem_index(headword_norms)

    total = len(rows)
    print(f"Tatoeba API bake: {total} words", flush=True)
    updated = empty = errors = 0
    conn.execute("BEGIN IMMEDIATE")
    for i, (wid, ru) in enumerate(rows, start=1):
        gloss_row = conn.execute(
            "SELECT glosses_en, en FROM words WHERE id = ?", (wid,)
        ).fetchone()
        gloss_tokens = gloss_tokens_for_word(
            str(gloss_row[0]) if gloss_row else None,
            str(gloss_row[1]) if gloss_row else "",
        )
        try:
            lines = best_pairs_api(
                ru,
                max_examples,
                include_author,
                headword_norms=headword_norms,
                lemma_stems=lemma_stems,
                gloss_tokens=gloss_tokens,
            )
        except Exception:
            errors += 1
            time.sleep(max(sleep_sec, 0.25))
            continue
        if not lines:
            empty += 1
            time.sleep(sleep_sec)
            continue
        if dry_run:
            print(f"\n{ru} →")
            for j, ln in enumerate(lines, 1):
                print(f"  {j}. {ln}")
        else:
            conn.execute("UPDATE words SET examples_en = ? WHERE id = ?", ("\n".join(lines), wid))
        updated += 1
        if i % 25 == 0 or i == total:
            print(f"  … {i}/{total} ({updated} updated, {empty} empty, {errors} errors)", flush=True)
        time.sleep(sleep_sec)

    if not dry_run:
        conn.execute("DELETE FROM dictionary_version")
        conn.execute("INSERT INTO dictionary_version(value) VALUES (?)", (DICTIONARY_VERSION,))
        conn.execute("COMMIT")
        print(f"Done. dictionary_version={DICTIONARY_VERSION}", flush=True)
    else:
        conn.execute("ROLLBACK")


def ensure_columns(conn: sqlite3.Connection) -> None:
    cols = {row[1] for row in conn.execute("PRAGMA table_info(words)")}
    if "examples_en" not in cols:
        conn.execute("ALTER TABLE words ADD COLUMN examples_en TEXT")


def main() -> int:
    ap = argparse.ArgumentParser(description="Bake short Tatoeba examples into dictionary.sqlite")
    ap.add_argument("--db", type=Path, default=Path("RussianWordADayApp/Resources/dictionary.sqlite"))
    ap.add_argument("--tatoeba-dir", type=Path, default=DEFAULT_TATOEBA_DIR)
    ap.add_argument("--download", action="store_true", help="Download weekly Tatoeba export files (~45 MB)")
    ap.add_argument("--from-dump", action="store_true", help="Use weekly Tatoeba dumps (recommended)")
    ap.add_argument("--api", action="store_true", help="Use live Tatoeba API (slow; small batches only)")
    ap.add_argument(
        "--resume",
        action="store_true",
        help="Skip rows that already have examples_en (fill Tatoeba holes after OpenRussian bake)",
    )
    ap.add_argument("--limit", type=int, default=0, help="API mode only: max words")
    ap.add_argument("--max-examples", type=int, default=DEFAULT_MAX_EXAMPLES)
    ap.add_argument("--sleep", type=float, default=DEFAULT_SLEEP_SEC, help="API mode only")
    ap.add_argument("--include-author", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--words", type=str, default="", help="Comma-separated Russian headwords")
    args = ap.parse_args()

    if args.download:
        print(f"Downloading Tatoeba weekly exports to {args.tatoeba_dir} …")
        download_dump_files(args.tatoeba_dir)
        if not args.from_dump and not args.api:
            print("Download complete. Re-run with --from-dump to bake examples.")
            return 0

    if not args.db.exists():
        print(f"Database not found: {args.db}", file=sys.stderr)
        return 1

    words_filter = [w.strip() for w in args.words.split(",") if w.strip()] or None

    conn = sqlite3.connect(args.db, isolation_level=None)
    try:
        conn.executescript("PRAGMA synchronous=OFF; PRAGMA journal_mode=MEMORY; PRAGMA temp_store=MEMORY;")
        ensure_columns(conn)

        if args.from_dump:
            if args.api:
                print("Use either --from-dump or --api, not both.", file=sys.stderr)
                return 2
            enrich_from_dump(
                conn,
                args.tatoeba_dir,
                resume=args.resume,
                max_examples=args.max_examples,
                include_author=args.include_author,
                dry_run=args.dry_run,
                words_filter=words_filter,
            )
        elif args.api:
            enrich_via_api(
                conn,
                resume=args.resume,
                limit=args.limit,
                max_examples=args.max_examples,
                sleep_sec=args.sleep,
                include_author=args.include_author,
                dry_run=args.dry_run,
                words_filter=words_filter,
            )
        else:
            print("Nothing to do. Use --download and/or --from-dump.", file=sys.stderr)
            return 2
    finally:
        conn.close()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
