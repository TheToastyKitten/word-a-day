## Russian – Word a Day (iOS)

Offline Russian–English dictionary with optional daily push notifications, favourites, personal notes, and quizzes.

### Run in Xcode

1. `open RussianWordADay.xcodeproj`
2. Pick an iPhone simulator (iOS 17+).
3. Cmd-R to run. On first launch the app copies the bundled `dictionary.sqlite` into Application Support.

Regenerate the Xcode project after adding files:

```bash
brew install xcodegen   # one-time
xcodegen generate
```

Command-line build:

```bash
xcodebuild -project RussianWordADay.xcodeproj \
  -scheme RussianWordADay \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  build
```

### Dictionary build pipeline

See `scripts/README.md`. Typical rebuild:

```bash
python3 scripts/download_openrussian.py
python3 scripts/build_from_openrussian.py
python3 scripts/enrich_dictionary_tatoeba.py --from-dump --resume
```

Output: `RussianWordADayApp/Resources/dictionary.sqlite` (~11k lemmas). Attributions: `DATA_LICENSES.md`.

### App Store / privacy

- In-app: **Settings → Legal & privacy**
- Hosted policy: https://thetoastykitten.github.io/word-a-day/privacy-policy.html
- Privacy manifest: `RussianWordADayApp/PrivacyInfo.xcprivacy`
- `ITSAppUsesNonExemptEncryption` is `false` in `project.yml`

Current release: **1.2 (4)** in `project.yml`.
