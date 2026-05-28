## Offline dictionary data sources

This app bundles an offline Russian→English dictionary as
`RussianWordADayApp/Resources/dictionary.sqlite`. The artifact is rebuilt by:

1. `scripts/build_from_openrussian.py` — lemmas, glosses, and OpenRussian-linked examples
2. `scripts/enrich_dictionary_tatoeba.py --from-dump --resume` — Tatoeba examples where OpenRussian has none

A **trimming baseline** (snapshot for resetting before further dictionary cleanup)
is kept at `data/dictionary.base.sqlite` and is not part of the app bundle.

### Bundled sources

#### OpenRussian.org
- **Website**: https://en.openrussian.org/
- **Used for**: Russian lemmas, English glosses/definitions, stress marks (`phonetic`), usage notes, and example sentences bundled in their database (including translation-linked examples).
- **License**: [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/). Attribution: “Dictionary data from OpenRussian.org contributors.”
- **Retrieval**: CSV export via [TogetherDB](https://app.togetherdb.com/db/o9puugtgtauo1ih5/russian3/words) (`python3 scripts/download_openrussian.py`), stored under `data/openrussian/`.

#### Tatoeba (example sentences, fill-in)
- **Website**: https://tatoeba.org/en/downloads
- **Used for**: short RU→EN example sentences on lemmas that have no examples after the OpenRussian bake.
- **License**: CC BY 2.0 FR. Attribution: “Example sentences from Tatoeba contributors.”
- **Retrieval**: weekly dumps under `data/tatoeba/` (`python3 scripts/enrich_dictionary_tatoeba.py --download`).

#### Hermit Dave / FrequencyWords (Russian, 50k)
- **Repository**: https://github.com/hermitdave/FrequencyWords
- **Used for**: which lemmas are included in the bundle and the `is_common` flag (daily push / quiz pool).
- **License**: MIT. Attribution: “Frequency data: Hermit Dave, FrequencyWords (MIT).”
- **Retrieval**: `Projects/Assets/RussianWordADay/ru_50k.txt` (from `content/2018/ru/ru_50k.txt`), retrieved 2026-05-07.

### Attribution in-app
Settings → **Legal & privacy** surfaces the attributions above, license links, and a short in-app privacy summary. The full policy for App Store Connect is hosted at `docs/privacy-policy.html` (see README).
