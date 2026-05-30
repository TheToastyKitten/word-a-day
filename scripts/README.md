## Data pipeline (offline dictionary)

### Goal
Produce an **open-licensed** offline dictionary for the iOS app: Russian lemma, English glosses, stress marks, and short RU→EN examples — bundled in `RussianWordADayApp/Resources/dictionary.sqlite`.

### Sources
- **[OpenRussian.org](https://en.openrussian.org/)** (CC BY-SA 4.0) — definitions, stress, OpenRussian-linked examples.
- **[Tatoeba](https://tatoeba.org/en/downloads)** (CC BY 2.0 FR) — fills in examples where OpenRussian has none (`--resume`).
- **[FrequencyWords](https://github.com/hermitdave/FrequencyWords)** `ru_50k.txt` (MIT) — which lemmas ship in the bundle and `is_common` for daily push.

### Build inputs (workspace Assets)

- `Projects/Assets/RussianWordADay/ru_50k.txt` — frequency list (MIT)
- `Projects/Assets/RussianWordADay/tatoeba/` — Tatoeba dumps (gitignored)

OpenRussian CSV exports live in `data/openrussian/` (gitignored; ~260 MB).

### Rebuild

```bash
python3 scripts/download_openrussian.py
python3 scripts/build_from_openrussian.py
python3 scripts/enrich_dictionary_tatoeba.py --from-dump --resume
```

To refresh OpenRussian example ordering without a full rebuild:

```bash
python3 scripts/refresh_openrussian_examples.py
python3 scripts/enrich_dictionary_tatoeba.py --from-dump --resume
```

### Shared build utilities

`scripts/build_seed_db.py` holds shared helpers (schema SQL, frequency list, geo blocklist, slugify, phonetics). The legacy Kaikki seed **builder** in that file is no longer used for the shipping app bundle.

`scripts/clean_usage_notes.py` filters junk rows and clears legacy `ai_note_en` columns after `build_from_openrussian.py`.

See `DATA_LICENSES.md` for attribution text.

### Tatoeba examples

```bash
python3 scripts/enrich_dictionary_tatoeba.py --download
python3 scripts/enrich_dictionary_tatoeba.py --from-dump \
  --db RussianWordADayApp/Resources/dictionary.sqlite \
  --resume
```

Example matching uses inflected forms in sentences (e.g. **прикончил** → **прикончить**). Use `--api` only for spot checks.
