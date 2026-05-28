#!/usr/bin/env python3
"""
Download OpenRussian public CSV exports from TogetherDB.

    python3 scripts/download_openrussian.py
    python3 scripts/download_openrussian.py --out data/openrussian

License: OpenRussian data is CC BY-SA 4.0 (see DATA_LICENSES.md when adopted).
"""

from __future__ import annotations

import argparse
import json
import time
import urllib.request
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent
DEFAULT_OUT = PROJECT_ROOT / "data" / "openrussian"

BASE = "https://worker.togetherdb.com/connections/fwoedz5fvtwvq03v/databases/openrussian_public"
USER_AGENT = "RussianWordADay-openrussian-download/1.0"


def _get_json(url: str, *, post: bool = False) -> dict:
    req = urllib.request.Request(url, method="POST" if post else "GET", headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=300) as resp:
        return json.loads(resp.read().decode())


def _download_bytes(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=300) as resp:
        return resp.read()


def main() -> None:
    parser = argparse.ArgumentParser(description="Download OpenRussian CSV tables")
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--force", action="store_true", help="Re-download even if file exists")
    args = parser.parse_args()

    out_dir: Path = args.out
    out_dir.mkdir(parents=True, exist_ok=True)

    structure = _get_json(f"{BASE}/structure")
    tables = [t["name"] for t in structure["result"]["tables"]]
    print(f"Tables: {', '.join(tables)}")

    for name in tables:
        dest = out_dir / f"openrussian_public - {name}.csv"
        if dest.exists() and dest.stat().st_size > 1000 and not args.force:
            print(f"  skip {name} ({dest.stat().st_size / 1024:.0f} KB)")
            continue
        print(f"  export {name}…")
        export_key = _get_json(
            f"{BASE}/tables/{name}/export?expand=false&filter=&separator=%2C",
            post=True,
        )["result"]["exportKey"]
        data = _download_bytes(f"https://worker.togetherdb.com/exports/{export_key}")
        dest.write_bytes(data)
        print(f"    → {dest.name} ({len(data) / 1024:.0f} KB)")
        time.sleep(0.4)

    print("Done.")


if __name__ == "__main__":
    main()
