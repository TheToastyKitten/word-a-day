#!/usr/bin/env python3
"""
Fill `words.ai_note_en` in a built dictionary.sqlite.

This is a build-time/offline step: it updates the bundled artifact so the app
remains fully offline at runtime.

Provider: OpenAI Responses API (configurable via env vars).

Required env:
  OPENAI_API_KEY

Optional env:
  OPENAI_BASE_URL   (default: https://api.openai.com/v1)
  OPENAI_MODEL      (default: gpt-4.1-mini)

Usage:
  python3 scripts/add_ai_notes.py --db RussianWordADayApp/Resources/dictionary.sqlite --limit 200
  python3 scripts/add_ai_notes.py --db ... --resume
  python3 scripts/add_ai_notes.py --db ... --dry-run --limit 20
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
import time
import urllib.request
from dataclasses import dataclass
from typing import Iterable, Optional


DEFAULT_BASE_URL = "https://api.openai.com/v1"
DEFAULT_MODEL = "gpt-4.1-mini"


SYSTEM_PROMPT = (
    "You write short learner-friendly usage notes for Russian words.\n"
    "Goal: explain nuance/typical context so users can distinguish near-synonyms.\n"
    "Rules:\n"
    "- Use plain English.\n"
    "- 1–2 sentences, max 180 characters.\n"
    "- Be conservative: do NOT invent facts (no etymology, no claims about frequency).\n"
    "- If the provided glosses are too generic to infer nuance, say what it commonly contrasts with "
    "based on the provided glosses only, or return an empty string.\n"
)


@dataclass(frozen=True)
class WordRow:
    id: str
    ru: str
    pos: Optional[str]
    en: str
    glosses_en: Optional[str]
    meaning_en: Optional[str]


def env(name: str, default: Optional[str] = None) -> str:
    v = os.environ.get(name)
    if v:
        return v
    if default is not None:
        return default
    raise RuntimeError(f"Missing required env var: {name}")


def openai_request(payload: dict) -> dict:
    base_url = env("OPENAI_BASE_URL", DEFAULT_BASE_URL).rstrip("/")
    api_key = env("OPENAI_API_KEY")
    url = f"{base_url}/responses"

    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("Authorization", f"Bearer {api_key}")
    req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=90) as resp:
        raw = resp.read().decode("utf-8")
        return json.loads(raw)


def extract_text(resp: dict) -> str:
    # Responses API returns structured output; accept common shapes.
    if isinstance(resp, dict):
        txt = resp.get("output_text")
        if isinstance(txt, str):
            return txt
        out = resp.get("output")
        if isinstance(out, list):
            parts: list[str] = []
            for item in out:
                if not isinstance(item, dict):
                    continue
                content = item.get("content")
                if not isinstance(content, list):
                    continue
                for c in content:
                    if isinstance(c, dict) and c.get("type") == "output_text":
                        t = c.get("text")
                        if isinstance(t, str):
                            parts.append(t)
            if parts:
                return "\n".join(parts)
    return ""


def clamp_note(s: str) -> str:
    s = (s or "").strip()
    s = " ".join(s.split())
    if len(s) > 180:
        s = s[:179].rstrip() + "…"
    return s


def rows_to_prompt(rows: Iterable[WordRow]) -> str:
    # Ask for JSONL mapping id->note so we can write deterministically.
    lines = []
    for r in rows:
        glosses = (r.glosses_en or "").replace("\n", "; ").strip()
        meaning = (r.meaning_en or "").strip()
        pos = (r.pos or "").strip()
        lines.append(
            json.dumps(
                {
                    "id": r.id,
                    "ru": r.ru,
                    "pos": pos,
                    "en": r.en,
                    "glosses_en": glosses,
                    "meaning_en": meaning,
                },
                ensure_ascii=False,
            )
        )
    return (
        "Return JSONL. Each line must be: {\"id\": <id>, \"ai_note_en\": <string>}.\n"
        "If you cannot produce a safe note, set ai_note_en to \"\".\n\n"
        + "\n".join(lines)
    )


def parse_jsonl_notes(text: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for line in (text or "").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(obj, dict):
            continue
        wid = obj.get("id")
        note = obj.get("ai_note_en")
        if isinstance(wid, str) and isinstance(note, str):
            out[wid] = clamp_note(note)
    return out


def ensure_schema(conn: sqlite3.Connection) -> None:
    cols = {row[1] for row in conn.execute("PRAGMA table_info(words);").fetchall()}
    if "ai_note_en" not in cols:
        raise RuntimeError(
            "DB schema missing words.ai_note_en. Rebuild dictionary.sqlite with latest build_seed_db.py first."
        )


def select_batch(conn: sqlite3.Connection, limit: int) -> list[WordRow]:
    sql = """
    SELECT id, ru, pos, en, glosses_en, meaning_en
    FROM words
    WHERE ai_note_en IS NULL OR ai_note_en = ''
    LIMIT ?;
    """
    out: list[WordRow] = []
    for row in conn.execute(sql, (limit,)):
        out.append(
            WordRow(
                id=row[0],
                ru=row[1],
                pos=row[2],
                en=row[3],
                glosses_en=row[4],
                meaning_en=row[5],
            )
        )
    return out


def write_notes(conn: sqlite3.Connection, notes: dict[str, str]) -> int:
    if not notes:
        return 0
    cur = conn.cursor()
    cur.execute("BEGIN IMMEDIATE;")
    try:
        cur.executemany(
            "UPDATE words SET ai_note_en = ? WHERE id = ?;",
            [(v, k) for k, v in notes.items()],
        )
        cur.execute("COMMIT;")
    except Exception:
        cur.execute("ROLLBACK;")
        raise
    return len(notes)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", required=True)
    ap.add_argument("--batch-size", type=int, default=200)
    ap.add_argument("--limit", type=int, default=0, help="Stop after writing N notes (0 = no limit)")
    ap.add_argument("--sleep-ms", type=int, default=250)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    model = os.environ.get("OPENAI_MODEL", DEFAULT_MODEL)

    conn = sqlite3.connect(args.db)
    try:
        ensure_schema(conn)
        written_total = 0

        while True:
            if args.limit and written_total >= args.limit:
                break
            want = args.batch_size
            if args.limit:
                want = min(want, args.limit - written_total)
            batch = select_batch(conn, want)
            if not batch:
                break

            prompt = rows_to_prompt(batch)
            payload = {
                "model": model,
                "input": [
                    {"role": "system", "content": SYSTEM_PROMPT},
                    {"role": "user", "content": prompt},
                ],
            }

            if args.dry_run:
                # No network calls; just show the first prompt chunk size.
                print(f"[dry-run] would request {len(batch)} notes using model={model}")
                print(prompt[:600] + ("\n…\n" if len(prompt) > 600 else ""))
                return 0

            resp = openai_request(payload)
            text = extract_text(resp)
            notes = parse_jsonl_notes(text)

            # Ensure we at least write empty strings for missing IDs so the loop can progress.
            for r in batch:
                notes.setdefault(r.id, "")

            wrote = write_notes(conn, notes)
            written_total += wrote
            print(f"wrote {wrote} (total {written_total})")
            time.sleep(max(0, args.sleep_ms) / 1000.0)

        return 0
    finally:
        conn.close()


if __name__ == "__main__":
    sys.exit(main())

