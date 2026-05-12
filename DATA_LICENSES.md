## Offline dictionary data sources

This app bundles an offline Russian→English dictionary as
`RussianWordOfDayApp/Resources/dictionary.sqlite`. The artifact is rebuilt
by `scripts/build_seed_db.py`; see that script for the exact transform.

A **trimming baseline** (snapshot for resetting before further dictionary cleanup)
is kept at `data/dictionary.base.sqlite` and is not part of the app bundle.

### Bundled sources

#### Kaikki / Wiktionary (Russian)
- **Website**: https://kaikki.org/dictionary/Russian/
- **Used for**: every Russian lemma, English glosses/definitions, IPA
  phonetics.
- **License**: CC-BY-SA 4.0 (via Wiktionary). Attribution: "Includes data
  from Wiktionary contributors, made available via Kaikki.org."
- **Retrieval**: `kaikki.org-dictionary-Russian.jsonl`, retrieved
  2026-05-07.

#### Hermit Dave / FrequencyWords (Russian, 50k)
- **Repository**: https://github.com/hermitdave/FrequencyWords
- **Used for**: top-N frequency ranking that drives the `is_common` flag
  (which is what the daily push picker draws from).
- **License**: MIT. Attribution: "Frequency data: Hermit Dave,
  FrequencyWords (MIT)."
- **Retrieval**: `content/2018/ru/ru_50k.txt`, retrieved
  2026-05-07.

### Attribution in-app
The app currently does not surface a "Data sources" screen. The
attributions above satisfy redistribution requirements at the repository
level. A dedicated About screen is tracked as a follow-up and not in
scope for this runbook.
