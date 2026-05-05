## Data pipeline (offline dictionary)

### Goal
Produce an **open-licensed** offline dictionary dataset for the iOS app with ~5,000 common Russian lemmas, including:
- Russian word (Cyrillic)
- English translation/gloss
- English meaning/definition (short)
- Phonetic pronunciation (IPA or transliteration)

The app can seed its SQLite DB from a bundled JSON file (`RussianWordOfDayApp/Resources/words.seed.json`). For v1, we keep the pipeline **JSON-first** so it’s easy to inspect and update.

### Recommended sources (open data)
- **Kaikki / Wiktionary extracts** (Russian entries): provides pronunciations + English definitions/glosses for many lemmas.\n  - Project: `https://kaikki.org/`\n  - Choose the Russian-language dump that includes English meanings.
- **Frequency list** to select top ~5k words:\n  - Example: Russian frequency lists derived from open corpora (ensure license is compatible and attribution requirements are met).

### High-level steps
1. Download the Kaikki/Wiktionary extract for Russian.
2. Parse and normalize entries:\n   - lowercase\n   - normalize `ё → е` for **search keys** (keep original spelling for display)\n   - pick a single lemma form (exclude multiword phrases for v1 unless desired)
3. Intersect with a frequency list to keep the most common ~5,000.
4. Emit `words.seed.json` with the required schema.
5. Add attribution and license notes into `DATA_LICENSES.md` (repo root).

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

