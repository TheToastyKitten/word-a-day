#!/usr/bin/env python3
"""
Compare OpenRussian prototype vs current bundled dictionary.

    python3 scripts/compare_openrussian_spike.py
"""

from __future__ import annotations

import csv
import re
import sqlite3
import unicodedata
from collections import defaultdict
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent
CSV_DIR = PROJECT_ROOT / "data" / "openrussian"
PROTOTYPE = CSV_DIR / "prototype_dictionary.sqlite"
CURRENT = PROJECT_ROOT / "RussianWordADayApp" / "Resources" / "dictionary.sqlite"
COMMON_RANK_MAX = 5000


def normalize_lemma(s: str) -> str:
    t = unicodedata.normalize("NFC", s.strip().lower())
    return t.replace("\u0301", "").replace("ё", "е")


def gloss_tokens(glosses_en: str | None, en_head: str) -> set[str]:
    toks: set[str] = set()
    blob = "\n".join(filter(None, [glosses_en or "", en_head or ""]))
    for line in blob.split("\n"):
        for part in re.split(r"[,;]", line):
            w = re.sub(r"[^\w]", "", part.strip().lower())
            if len(w) >= 3:
                toks.add(w)
    return toks


def example_alignment(examples_en: str | None, glosses_en: str | None, en_head: str) -> tuple[int, int]:
    if not examples_en:
        return 0, 0
    gt = gloss_tokens(glosses_en, en_head)
    aligned = 0
    total = 0
    for line in examples_en.split("\n"):
        if "\t" not in line:
            continue
        total += 1
        en = line.split("\t", 1)[1]
        words = set(re.findall(r"[a-z]{3,}", en.lower()))
        if not gt or (words & gt):
            aligned += 1
    return aligned, total


def load_openrussian_index(csv_dir: Path) -> dict[str, list[int]]:
    path = csv_dir / "openrussian_public - words.csv"
    by_bare: dict[str, list[int]] = defaultdict(list)
    with path.open(encoding="utf-8-sig", newline="") as f:
        for row in csv.DictReader(f):
            if row.get("disabled", "1") != "0" or not (row.get("type") or "").strip():
                continue
            by_bare[normalize_lemma(row["bare"])].append(int(row["id"]))
    return by_bare


def full_openrussian_stats(csv_dir: Path) -> dict:
    words_path = csv_dir / "openrussian_public - words.csv"
    trans_path = csv_dir / "openrussian_public - translations.csv"

    enabled = 0
    common = 0
    with_trans: set[int] = set()
    with words_path.open(encoding="utf-8-sig", newline="") as f:
        for row in csv.DictReader(f):
            if row.get("disabled", "1") != "0" or not (row.get("type") or "").strip():
                continue
            enabled += 1
            try:
                rank = int((row.get("rank") or "").strip())
            except ValueError:
                rank = 999_999
            if 0 < rank <= COMMON_RANK_MAX:
                common += 1

    with trans_path.open(encoding="utf-8-sig", newline="") as f:
        for row in csv.DictReader(f):
            if row.get("lang") == "en" and (row.get("tl") or "").strip():
                with_trans.add(int(row["word_id"]))

    return {
        "enabled_lemmas": enabled,
        "common_by_rank": common,
        "with_en_translation": len(with_trans),
    }


def fetch_db(path: Path) -> dict[str, dict]:
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    out = {}
    for row in conn.execute(
        "SELECT ru, en, meaning_en, glosses_en, examples_en, phonetic, ai_note_en, pos, is_common FROM words"
    ):
        out[normalize_lemma(row["ru"])] = dict(row)
    conn.close()
    return out


def main() -> None:
    if not PROTOTYPE.exists():
        raise SystemExit(f"Missing prototype DB: {PROTOTYPE}\nRun: python3 scripts/prototype_openrussian.py")

    print("=" * 60)
    print("OPENRUSSIAN FULL EXPORT (coverage estimate)")
    print("=" * 60)
    if CSV_DIR.exists():
        stats = full_openrussian_stats(CSV_DIR)
        for k, v in stats.items():
            print(f"  {k}: {v:,}")
        csv_mb = sum(f.stat().st_size for f in CSV_DIR.glob("*.csv")) / (1024 * 1024)
        print(f"  CSV export total: {csv_mb:.0f} MB (not bundled size)")

    print()
    print("=" * 60)
    print("CURRENT BUNDLED DICTIONARY")
    print("=" * 60)
    cur = fetch_db(CURRENT)
    cur_with_ex = sum(1 for r in cur.values() if r.get("examples_en"))
    cur_common = sum(1 for r in cur.values() if r["is_common"])
    cur_size = CURRENT.stat().st_size / (1024 * 1024)
    print(f"  lemmas: {len(cur):,}")
    print(f"  is_common: {cur_common:,}")
    print(f"  with examples: {cur_with_ex:,}")
    print(f"  bundle size: {cur_size:.2f} MB")

    print()
    print("=" * 60)
    print("PROTOTYPE (100 words)")
    print("=" * 60)
    proto = fetch_db(PROTOTYPE)
    proto_with_ex = sum(1 for r in proto.values() if r.get("examples_en"))
    proto_common = sum(1 for r in proto.values() if r["is_common"])
    proto_size = PROTOTYPE.stat().st_size / 1024
    print(f"  lemmas: {len(proto):,}")
    print(f"  is_common (rank≤{COMMON_RANK_MAX}): {proto_common:,}")
    print(f"  with examples: {proto_with_ex:,}")
    print(f"  sqlite size: {proto_size:.0f} KB")

    in_both = 0
    # Lemma overlap
    if CSV_DIR.exists():
        opr_index = load_openrussian_index(CSV_DIR)
        in_both = sum(1 for ru in cur if ru in opr_index)
        print()
        print("=" * 60)
        print("COVERAGE: current lemmas in OpenRussian")
        print("=" * 60)
        print(f"  current lemmas also in OpenRussian: {in_both:,} / {len(cur):,} ({100*in_both/len(cur):.1f}%)")
        print(f"  current lemmas missing from OpenRussian: {len(cur) - in_both:,}")

    # Compare prototype subset
    print()
    print("=" * 60)
    print("SIDE-BY-SIDE (prototype sample)")
    print("=" * 60)

    proto_align = 0
    proto_ex_total = 0
    cur_align = 0
    cur_ex_total = 0

    pinned = {normalize_lemma(p) for p in ("ханжа", "пожалуйста", "говорить", "москва")}
    for ru in sorted(proto.keys(), key=lambda x: (x not in pinned, x)):
        p = proto[ru]
        c = cur.get(ru)
        pa, pt = example_alignment(p.get("examples_en"), p.get("glosses_en"), p["en"])
        proto_align += pa
        proto_ex_total += pt
        if c:
            ca, ct = example_alignment(c.get("examples_en"), c.get("glosses_en"), c["en"])
            cur_align += ca
            cur_ex_total += ct

        if ru not in {normalize_lemma(x) for x in ("ханжа", "пожалуйста", "говорить", "москва")}:
            continue

        print(f"\n--- {p['ru']} ({p.get('pos')}) ---")
        print(f"  OpenRussian headline: {p['en']}")
        if c:
            print(f"  Current headline:     {c['en']}")
        else:
            print("  Current:              (not in bundle)")
        print(f"  OpenRussian glosses:  {(p.get('glosses_en') or '').replace(chr(10), ' | ')}")
        if p.get("examples_en"):
            print("  OpenRussian examples:")
            for line in (p["examples_en"] or "").split("\n")[:4]:
                if "\t" in line:
                    r, e = line.split("\t", 1)
                    gt = gloss_tokens(p.get("glosses_en"), p["en"])
                    ew = set(re.findall(r"[a-z]{3,}", e.lower()))
                    mark = "✓" if (not gt or (ew & gt)) else "?"
                    print(f"    {mark} {r} — {e}")
        if c and c.get("examples_en"):
            print("  Current examples:")
            for line in (c["examples_en"] or "").split("\n")[:4]:
                if "\t" in line:
                    r, e = line.split("\t", 1)
                    print(f"    · {r} — {e}")

    print()
    print("=" * 60)
    print("EXAMPLE ↔ GLOSS ALIGNMENT (sample only)")
    print("=" * 60)
    if proto_ex_total:
        print(f"  Prototype: {proto_align}/{proto_ex_total} ({100*proto_align/proto_ex_total:.0f}%)")
    if cur_ex_total:
        print(f"  Current (same lemmas): {cur_align}/{cur_ex_total} ({100*cur_align/cur_ex_total:.0f}%)")

    # Extrapolated full bundle size if we built all overlapping lemmas
    if CSV_DIR.exists() and len(proto) > 0:
        bytes_per_row = PROTOTYPE.stat().st_size / len(proto)
        est_rows = in_both if CSV_DIR.exists() else len(cur)
        est_mb = bytes_per_row * est_rows / (1024 * 1024)
        print()
        print("=" * 60)
        print("ROUGH FULL-BUNDLE ESTIMATE (very approximate)")
        print("=" * 60)
        print(f"  If ~{est_rows:,} OpenRussian rows at ~{bytes_per_row/1024:.1f} KB/row → ~{est_mb:.1f} MB sqlite")
        print(f"  (Current bundle is {cur_size:.2f} MB for {len(cur):,} rows)")


if __name__ == "__main__":
    main()
