## Data pipeline (offline dictionary)

### Goal
Produce an **open-licensed** offline dictionary for the iOS app: Russian lemma, English glosses, stress marks, usage notes, and short RU→EN examples — all bundled in `RussianWordADayApp/Resources/dictionary.sqlite`.

### Sources
- **[OpenRussian.org](https://en.openrussian.org/)** (CC BY-SA 4.0) — definitions, usage notes, stress, OpenRussian-linked examples.
- **[Tatoeba](https://tatoeba.org/en/downloads)** (CC BY 2.0 FR) — fills in examples where OpenRussian has none (`--resume`).
- **[FrequencyWords](https://github.com/hermitdave/FrequencyWords)** `ru_50k.txt` (MIT) — which lemmas ship in the bundle and `is_common` for daily push.

### Build inputs (workspace Assets)

- `Projects/Assets/RussianWordADay/ru_50k.txt` — frequency list (MIT)

OpenRussian CSV exports live in `data/openrussian/` (gitignored; ~260 MB).

### Rebuild (recommended)

```bash
python3 scripts/download_openrussian.py
python3 scripts/build_from_openrussian.py
python3 scripts/enrich_dictionary_tatoeba.py --from-dump --resume
```

**Example order:** OpenRussian’s public CSV has no per-sentence “display order” (the website
curates in its live DB, and the list can change). We rank linked sentences by dictionary
form, short length (~3–8 words), and stable link id — not by “all *Не …* sentences first”.
To re-apply after ranking changes without a full rebuild:

```bash
python3 scripts/refresh_openrussian_examples.py
python3 scripts/enrich_dictionary_tatoeba.py --from-dump --resume
```

Legacy Kaikki pipeline: `scripts/build_seed_db.py` (kept for reference / diffs).

See `DATA_LICENSES.md` for attribution text.

### Output schema (`words.seed.json`)
Each entry:
```json
{
  "id": "stable_id_string",
  "russian": "привет",
  "english": "hello",
  "meaning_en": "A greeting; “hello/hi”.",
  "phonetic": "pree-VYET"
}
```

### Notes
- If you later want faster startup, you can generate a prebuilt `words.sqlite` and bundle that instead of seeding at runtime.\n  For now, runtime seeding keeps iteration easy.

### Tatoeba examples (build-time, recommended)

Short RU→EN examples come from [Tatoeba weekly exports](https://tatoeba.org/en/downloads) (CC BY 2.0 FR):

```bash
python3 scripts/enrich_dictionary_tatoeba.py --download
python3 scripts/enrich_dictionary_tatoeba.py --from-dump \
  --db RussianWordADayApp/Resources/dictionary.sqlite \
  --resume
```

Dumps are stored under `data/tatoeba/` (~45 MB download). No API rate limits.
Example matching uses inflected forms in sentences (e.g. **прикончил** → **прикончить**);
inflected words are never added as searchable dictionary headwords.
Use `--api` only for spot checks on a few words.

### OpenRussian evaluation spike (optional)

Download [OpenRussian](https://en.openrussian.org/) CSV exports (CC BY-SA 4.0) and build a 100-word prototype for comparison:

```bash
python3 scripts/download_openrussian.py
python3 scripts/prototype_openrussian.py --limit 100
python3 scripts/compare_openrussian_spike.py
```

Outputs: `data/openrussian/` (gitignored CSVs), `data/openrussian/prototype_dictionary.sqlite`.

