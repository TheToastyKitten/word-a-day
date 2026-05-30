#!/usr/bin/env python3
"""
Build RussianWordADayApp/Resources/dictionary.sqlite from a Kaikki Russian
dump and a CC-BY frequency list. Bundled with the app and copied into the
user's sandbox on first launch by WordStore.installBundledDictionaryIfMissing().
Lexical merges keep **nouns, verbs, adjectives, adverbs**, cardinal **numerals**
(`num`), plus high-frequency **particles** and **interjections** (e.g. пожалуйста,
спасибо), plus **pronouns, prepositions, and conjunctions**. Determiners and other
function words remain omitted. **WordStore** search includes the same POS set;
numerals are used for the Numbers screen and direct lookups, not beginner POS chips.

Usage (defaults read build inputs from ../../Assets/RussianWordADay/):

    python3 scripts/build_seed_db.py \
        [--kaikki <path-to-kaikki-russian.jsonl>] \
        [--freq   <path-to-ru_50k.txt>] \
        [--common-limit 5000] \
        [--out RussianWordADayApp/Resources/dictionary.sqlite]

Refresh POS / gloss choices for every lemma row in an existing DB (needs the
Kaikki dump locally; avoids a full freq rebuild):

    python3 scripts/build_seed_db.py \
        --kaikki <kaikki.org-dictionary-Russian.jsonl> \
        --refresh-sqlite RussianWordADayApp/Resources/dictionary.sqlite

Strip morphology-only headword rows from an existing bundle (no Kaikki dump):

    python3 scripts/build_seed_db.py \
        --scrub-morph-headwords-in RussianWordADayApp/Resources/dictionary.sqlite

Baseline SQLite for iterative trimming (not bundled in the app; safe to reset from):

    data/dictionary.base.sqlite

    Reset the app bundle from that snapshot, try another trim, then copy back when happy::

        cp data/dictionary.base.sqlite RussianWordADayApp/Resources/dictionary.sqlite
        # …edit / scrub…
        cp RussianWordADayApp/Resources/dictionary.sqlite data/dictionary.base.sqlite
"""
from __future__ import annotations

import argparse
import contextlib
import json
import re
import sqlite3
import sys
import unicodedata
from collections.abc import Set as AbstractSet
from pathlib import Path
from typing import Iterator, Optional

CYRILLIC_RE = re.compile(r"^[\u0400-\u04FF]+$")
GLOSS_PARENS_RE = re.compile(r"\s*\([^)]*\)")
MAX_GLOSS_LEN = 60
MAX_MEANING_LEN = 200
MAX_GLOSSES = 5
MEANING_GLOSSES_LIMIT = 4
DICTIONARY_VERSION = 28
# Lexical POS: content words + everyday function words learners need in speech.

# Allowed Kaikki `pos` values for rows that may enter lemma merge (must agree
# with WordStore.allowedPOS synonym spellings).
LEXICAL_BUILD_POS: frozenset[str] = frozenset(
    (
        "noun",
        "verb",
        "adj",
        "adjective",
        "adv",
        "adverb",
        "num",
        "particle",
        "interjection",
        "intj",
        "pron",
        "pronoun",
        "prep",
        "preposition",
        "conj",
        "conjunction",
        "other",
    )
)

# English substrings in the *first* lexical gloss for “this headword is chiefly
# a place / administrative region”, so we do not drop mixed entries like
# Pushkin (person) that only mention a town in a secondary sense.
GEO_GLOSS_RE = re.compile(
    r"(?is)\b("
    r"a country|an archipelago|insular state|federal city|capital city|capital of|"
    r"principal city|census-designated place|municipal town|town in|city in|city of|"
    r"province of|territorial entity|district of|borough of|national park|prefecture|"
    r"County,|County in|County of|census area|canton of|department of France|"
    r"borough of|historic county|historic region|historic territory|"
    r"Atlantic Ocean|Pacific Ocean|Indian Ocean|Arctic Ocean|Southern Ocean|Oceania|"
    r"United States|Russian Federation|Soviet Union|United Kingdom|\bUSA\b|"
    r"North America|South America|Central America|Western Europe|Eastern Europe|"
    r"located primarily|geographic region|archipelago\b|\bislands?\b|\binsular\b|"
    r"\bcontinent\b|River in|river in|Mountain range|"
    r"States of the United States|\bU\.S\. state\b"
    r")\b"
)

GEO_TOPIC_MARKERS = (
    # Only unambiguous category/topic substrings (Kaikki mirrors Wiktionary).
    # Avoid bare "capital ", "state ", etc.: they match maintenance categories.
    "places in ",
    "places of ",
    "states of the united",
    "islands of ",
    "archipelag",
    "countries in ",
    "cities in ",
    "towns in ",
    "villages in ",
    "districts of ",
    "provinces of ",
    "regions of ",
    "subdivisions of ",
    "administrative divisions",
    " national park",
)

# Cyrillic lemmas containing these contiguous substrings are treated as tied to a
# foreign toponym (e.g. лондонский). Use only distinctive stems (avoid short
# stems like «рим», which hits unrelated words).
TOPONYM_LEMMA_SUBSTRINGS = frozenset({
    "лондон",
    "париж",
    "берлин",
    "вашингтон",
    "гаваи",
    "гавай",
    "токио",
    "пекин",
    "шанхай",
})

# Lowercased English headword tokens (first token of the learner gloss).
# Matches relational adjectives: «*-ский » demonyms glossed “London”, “Paris”, etc.
EN_SOLO_TOPONYM_HEADWORDS = frozenset({
    "london",
    "paris",
    "berlin",
    "moscow",
    "moskva",
    "washington",
    "hawaii",
    "hawaiian",
    "tokyo",
    "beijing",
    "peking",
    "rome",
    "madrid",
    "vienna",
    "warsaw",
    "prague",
    "budapest",
    "istanbul",
    "cairo",
    "dublin",
    "amsterdam",
    "brussels",
    "copenhagen",
    "stockholm",
    "oslo",
    "helsinki",
    "warszawa",
    "venice",
    "milan",
    "florence",
    "naples",
    "sydney",
    "melbourne",
    "toronto",
    "vancouver",
    "montreal",
    "chicago",
    "boston",
    "miami",
    "atlanta",
    "seattle",
    "dallas",
    "denver",
    "phoenix",
    "detroit",
    "houston",
    "philadelphia",
    "california",
    "florida",
    "texas",
    "colorado",
    "arizona",
    "virginia",
    "georgia",
    "indiana",
    "kentucky",
    "oregon",
    "oklahoma",
    "alabama",
    "alaska",
    "utah",
    "kansas",
    "iowa",
    "canada",
    "australia",
    "mexico",
    "brazil",
    "argentina",
    "chile",
    "peru",
    "colombia",
    "venezuela",
    "cuba",
    "jamaica",
    "india",
    "pakistan",
    "bangladesh",
    "thailand",
    "vietnam",
    "indonesia",
    "philippines",
    "malaysia",
    "singapore",
    "portugal",
    "greece",
    "poland",
    "ukraine",
    "kyiv",
    "kiev",
    "minsk",
    "riga",
    "tallinn",
    "vilnius",
    "bucharest",
    "sofia",
    "zagreb",
    "belgrade",
    "russia",
    "america",
    "usa",
    "china",
    "japan",
    "korea",
    "france",
    "germany",
    "spain",
    "italy",
    "england",
    "britain",
    "egypt",
    "norway",
    "sweden",
    "switzerland",
    "austria",
    "netherlands",
    "ireland",
    "israel",
    "turkey",
    "scotland",
    "wales",
})

# English headwords that are geographic common nouns, not placenames (avoid
# false positives from GEO_GLOSS_RE substrings like “continent”, “island”).
GEO_VOCAB_HEADWORDS = frozenset({
    "continent",
    "island",
    "islands",
    "river",
    "lake",
    "mountain",
    "ocean",
    "sea",
    "country",
    "city",
    "town",
    "village",
    "region",
    "state",
    "peninsula",
    "archipelago",
})

# OpenRussian headlines: person names / letter names (headline-only; stricter
# than PERSON_NAME_GLOSS_RE so “nickname” / “first name” vocabulary stays).
OPENRUSSIAN_PERSON_HEADLINE_RE = re.compile(
    r"(?is)"
    r"\b(?:a|the)\s+(?:male|female)\s+given\s+name\b|"
    r"\b(?:a|the)\s+surname\b|"
    r"\([^)]*\b(?:surname|given\s+name|first\s+name)\b[^)]*\)|"
    r"\b(?:male|female)\s+(?:given\s+)?name\)"
)

OPENRUSSIAN_PLACE_HEADLINE_RE = re.compile(
    r"(?is)\b("
    r"a country|an archipelago|insular state|federal city|capital city|capital of|"
    r"principal city|census-designated place|municipal town|town in|city in|city of|"
    r"province of|territorial entity|district of|borough of|national park|prefecture|"
    r"United States|Russian Federation|Soviet Union|United Kingdom|\bUSA\b|"
    r"North America|South America|Central America|"
    r"located primarily|geographic region|"
    r"States of the United States|\bU\.S\. state\b"
    r")\b"
)

OPENRUSSIAN_LETTER_NAME_RE = re.compile(
    r"(?i)\b(name of the letter|Cyrillic letter|Roman letter)\b"
)

# Lemma ends with relational placename adjectives (-ский paradigm).
RU_TOPONYMIC_ADJ_SUFFIX_RE = re.compile(
    r"(?iu)(скими|ским|ские|ская|ских|ское|ский|ской|скому|ском|скую|ского)$"
)

NAME_TOPIC_MARKERS = (
    "given names",
    "male given names",
    "female given names",
    "surnames",
    "patronymics",
    "hypocoristics",
    "nicknames",
    "personal names",
)

PERSON_NAME_GLOSS_RE = re.compile(
    r"(?is)"
    r"(?:\bgiven\s+name\b|\bforename\b|\bsurname\b|\bfamily\s+name\b|\bpatronymic\b|"
    r"\bmale\s+given\s+name\b|\bfemale\s+given\s+name\b|"
    r"\bhypocoristic\b|\bnickname\b|"
    r"\bromanization\s+of\s+the\s+name\b|"
    r"a\s+transliteration\b[^\n]{0,96}\bgiven\s+name\b|"
    r"\btransliteration\b[^\n]{0,96}\bgiven\s+name\b)"
)

# Morph-style definitions suppressed for learner-visible gloss selection.
HARD_GRAMMAR_GLOSS_RES: tuple[re.Pattern[str], ...] = (
    re.compile(
        r"(?is)^(.*\b)?("
        r"past\b.*\bparticiple|present\b.*\bparticiple|"
        r"perfective\b.*\bparticiple|"
        r"past passive|past active|adverbial participle"
        r")\s+.*\bof\b"
    ),
    re.compile(r"(?is)\b(?:imperfective|perfective)?\s*adverbial\s+participle\s+of\b"),
    re.compile(r"(?is)\bparticiple\s+.*\bof\b"),
    re.compile(r"(?is)\bgerund\s+.*\bof\b"),
    re.compile(r"(?is)\bsupine\s+.*\bof\b"),
    re.compile(r"(?is)\binfinitive\s+.*\bof\b"),
    re.compile(r"(?is)\bverbal noun\s+.*\bof\b"),
    re.compile(r"(?is)\bimperative\b.*\bof\b"),
    # Finite verb morphology ("masculine singular past indicative perfective of …").
    # These are inflected surface forms, not learner dictionary glosses.
    re.compile(r"(?is)\bindicative\b.*\bof\b"),
    re.compile(r"(?is)\bsubjunctive\b.*\bof\b"),
    re.compile(r"(?is)\bconditional\b[^\n]{0,40}\bof\b"),
    re.compile(r"(?is)\bpast\s+tense\b.*\bof\b"),
    re.compile(r"(?is)\bsimple\s+past\b.*\bof\b"),
    re.compile(r"(?is)\bpast\s+historic\b.*\bof\b"),
    # Truncated finite-verb morph lines (MAX_GLOSS_LEN may cut before " of …").
    re.compile(
        r"(?is)^(?:masculine|feminine|neuter)\b[^\n]{0,180}\b(?:past|present|future)\s+indicative\b"
    ),
    # Case-form headwords (людям → "dative of люди", etc.). These are inflected
    # forms, not learner dictionary lemmas.
    re.compile(
        r"(?is)\b(?:dative|genitive|accusative|instrumental|prepositional|locative|vocative|ablative)\b.*\bof\b"
    ),
    # Same, but some headlines are truncated before “of …” when we shorten `en`
    # to MAX_GLOSS_LEN. Treat any gloss that *starts* with these morphology case
    # keywords as non-lemma (very unlikely to be a real definition).
    re.compile(
        r"(?is)^(?:genitive|dative|accusative|instrumental|prepositional|locative|vocative|ablative|nominative)\b"
    ),
    # Many inflection heads start with gender (or gender list) then list cases:
    #   "feminine genitive/dative/instrumental/prepositional singular …"
    #   "masculine/neuter dative singular of …"
    # Treat these as inflected-form heads even if “of …” is truncated.
    re.compile(
        r"(?is)\b(?:masculine|feminine|neuter)\b[^\n]{0,120}\b(?:"
        r"genitive|dative|accusative|instrumental|prepositional|locative|vocative|ablative|nominative"
        r")\b"
    ),
    re.compile(r"(?is)\b(?:singular|plural)\b[^\n]{0,120}\b(?:genitive|dative|accusative|instrumental|prepositional|locative|vocative|ablative|nominative)\b"),
    # Other common inflection-style headwords (plural/tense/degree/etc.).
    re.compile(
        r"(?is)\b(?:nominative|plural|singular|past|present|future|comparative|superlative)\b.*\bof\b"
    ),
    # Truncated variants without “of …”.
    re.compile(r"(?is)^(?:plural|singular|comparative|superlative)\b"),
    # Russian "short-form adjective" heads often show up as:
    #   "short masculine singular of уверенный"
    #   "short feminine singular of …"
    #   "short plural of …"
    # These are inflected forms, not lemmas.
    re.compile(
        r"(?is)\bshort\b(?:\s+(?:masculine|feminine|neuter|plural))?"
        r"(?:\s+(?:singular|plural))?\s+\bof\b"
    ),
    # Truncated short-form adjective heads without “of …”.
    re.compile(
        r"(?is)^short\b(?:\s+(?:masculine|feminine|neuter|plural))?"
        r"(?:\s+(?:singular|plural))?\b"
    ),
    re.compile(r"(?is)\bshort\s+form\s+of\b"),
    # Relational / possessive adjective from a name (e.g. Ленин as adjective of Лена).
    re.compile(r"(?is)\brelational\s+adjective\b.*\bof\b"),
    re.compile(r"(?is)\bpossessive\s+adjective\b.*\bof\b"),
    re.compile(
        r"(?is)^(?:masculine|feminine|neuter)\b[^\n]{0,160}\brelational\s+adjective\b"
    ),
    # Kaikki inflected-surface glosses: "inflection of быль: genitive …"
    re.compile(r"(?is)\binflection\s+of\b"),
    re.compile(r"(?is)^(\s*)Romanization\b"),
)

# Alternate label without trailing meaning (“: gloss”) stripped for senses.
ALT_FORM_WITHOUT_MEANING_RE = re.compile(
    r"(?is)^alternative\s+(form|spelling)\s+of\b[^:]*$"
)

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent
WORKSPACE_ASSETS = PROJECT_ROOT.parent / "Assets" / "RussianWordADay"
DEFAULT_KAIKKI = WORKSPACE_ASSETS / "kaikki.org-dictionary-Russian.jsonl"
DEFAULT_FREQ = WORKSPACE_ASSETS / "ru_50k.txt"


def is_hard_morph_gloss(text: str) -> bool:
    if not text:
        return True
    if ALT_FORM_WITHOUT_MEANING_RE.match(text.strip()):
        return True
    for rx in HARD_GRAMMAR_GLOSS_RES:
        if rx.search(text):
            return True
    return False


# Russian vowels (lowercase comparison).
VOWELS = frozenset("аеёиоуыэюя")

# Learner-oriented Latin consonants (English-friendly).
CONS_LATIN = {
    "б": "b",
    "в": "v",
    "г": "g",
    "д": "d",
    "ж": "zh",
    "з": "z",
    "й": "y",
    "к": "k",
    "л": "l",
    "м": "m",
    "н": "n",
    "п": "p",
    "р": "r",
    "с": "s",
    "т": "t",
    "ф": "f",
    "х": "kh",
    "ц": "ts",
    "ч": "ch",
    "ш": "sh",
    "щ": "shch",
}

TRANSLIT_MAP = {
    "а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "yo",
    "ж": "zh", "з": "z", "и": "i", "й": "y", "к": "k", "л": "l", "м": "m",
    "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u",
    "ф": "f", "х": "kh", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "shch",
    "ъ": "", "ы": "y", "ь": "", "э": "e", "ю": "yu", "я": "ya",
}

SCHEMA_SQL = """
CREATE TABLE words(
  id         TEXT PRIMARY KEY,
  ru         TEXT NOT NULL,
  en         TEXT NOT NULL,
  meaning_en TEXT,
  pos        TEXT,
  glosses_en TEXT,
  examples_en TEXT,
  ai_note_en TEXT,
  phonetic   TEXT,
  ru_norm    TEXT NOT NULL DEFAULT '',
  en_norm    TEXT NOT NULL DEFAULT '',
  is_common  INTEGER NOT NULL DEFAULT 0,
  wiktionary_baked INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX idx_words_is_common ON words(is_common) WHERE is_common = 1;

CREATE VIRTUAL TABLE words_fts USING fts5(
  id UNINDEXED,
  ru,
  en,
  tokenize = 'unicode61'
);

CREATE TABLE dictionary_version(value INTEGER NOT NULL);
"""


def unique_glosses(senses: list, limit: int) -> list[str]:
    """Collect unique learner-facing English glosses across senses."""
    out: list[str] = []
    seen: set[str] = set()
    for g in iter_lexical_gloss_texts(senses):
        s = g.strip()
        if not s:
            continue
        if s in seen:
            continue
        seen.add(s)
        out.append(s)
        if len(out) >= limit:
            break
    return out


def make_meaning_description(glosses: list[str]) -> Optional[str]:
    """Readable longer meaning string from multiple glosses."""
    if not glosses:
        return None
    joined = "; ".join(glosses[:MEANING_GLOSSES_LIMIT])
    if len(joined) > MAX_MEANING_LEN:
        joined = joined[: MAX_MEANING_LEN - 1].rstrip() + "…"
    return joined


def slugify(russian: str, used: set[str]) -> str:
    base = "".join(TRANSLIT_MAP.get(ch, ch) for ch in russian.lower())
    base = re.sub(r"[^a-z0-9]+", "_", base).strip("_") or "word"
    candidate = base
    n = 2
    while candidate in used:
        candidate = f"{base}_{n}"
        n += 1
    used.add(candidate)
    return candidate


def normalize_lemma(s: str) -> str:
    return unicodedata.normalize("NFC", s.strip().lower()).replace("\u0301", "")


def normalize_for_index(s: str) -> str:
    return normalize_lemma(s).replace("ё", "е")


def is_clean_lemma(s: str) -> bool:
    if not s or " " in s:
        return False
    # Single-token lemmas only — drop hyphenated onomatopoeia / scraps (ха-ха, etc.).
    if "-" in s:
        return False
    return bool(CYRILLIC_RE.match(s))


def load_geo_blocklist(path: Path) -> frozenset[str]:
    if not path.exists():
        return frozenset()
    out: set[str] = set()
    with path.open(encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            out.add(normalize_lemma(line))
    return frozenset(out)


def strip_gloss_fragment(gloss: str) -> str:
    text = GLOSS_PARENS_RE.sub("", gloss).strip()
    text = re.split(r"[;,]", text, maxsplit=1)[0].strip()
    return text


def sense_has_nonempty_form_of(sense: dict) -> bool:
    fo = sense.get("form_of")
    if not fo:
        return False
    if isinstance(fo, list):
        return any(isinstance(it, dict) and it.get("word") for it in fo)
    if isinstance(fo, dict):
        return bool(fo.get("word"))
    return False


def gloss_learner_text(gloss: str, sense: dict) -> Optional[str]:
    """Pick an English gloss for learners: hide participle-only lines, but keep
    short definitions even when Wiktionary marks a sense as form-of (often
    without a `:` tail)."""
    if not isinstance(gloss, str) or not gloss.strip():
        return None
    has_fo = sense_has_nonempty_form_of(sense)

    colon_idx = gloss.find(":")
    if has_fo and colon_idx >= 0:
        tail = strip_gloss_fragment(gloss[colon_idx + 1 :])
        if tail and not is_hard_morph_gloss(tail):
            return tail

    full = strip_gloss_fragment(gloss)
    if not full or is_hard_morph_gloss(full):
        return None
    return full


def iter_lexical_gloss_texts(senses: list) -> Iterator[str]:
    for sense in senses or []:
        for gloss in sense.get("glosses", []) or []:
            t = gloss_learner_text(gloss, sense)
            if t:
                yield t


def has_any_lexical_gloss(senses: list) -> bool:
    return any(iter_lexical_gloss_texts(senses))


def first_english_topo_headword(gloss: str) -> str:
    """First surface token of a gloss, for matching bare English placenames."""
    if not gloss or not gloss.strip():
        return ""
    frag = strip_gloss_fragment(gloss).strip()
    if not frag:
        return ""
    part = re.split(r"[\s,;(]", frag, maxsplit=1)[0]
    return part.strip().strip('"').strip("'").rstrip(".:-–—").lower()


def topic_string_matches_geo(s: str) -> bool:
    sl = s.lower()
    return any(marker in sl for marker in GEO_TOPIC_MARKERS)


def entry_has_geo_topic(obj: dict) -> bool:
    for t in obj.get("topics") or []:
        if isinstance(t, str) and topic_string_matches_geo(t):
            return True
    for sense in obj.get("senses") or []:
        for t in sense.get("topics") or []:
            if isinstance(t, str) and topic_string_matches_geo(t):
                return True
        for cat in sense.get("categories") or []:
            if isinstance(cat, dict):
                nm = cat.get("name")
                if isinstance(nm, str) and topic_string_matches_geo(nm):
                    return True
            elif isinstance(cat, str) and topic_string_matches_geo(cat):
                return True
    return False


def should_exclude_place_entry(
    obj: dict, lemma_norm: str, geo_lemmas: frozenset[str]
) -> bool:
    if lemma_norm in geo_lemmas:
        return True
    if any(stem in lemma_norm for stem in TOPONYM_LEMMA_SUBSTRINGS):
        return True
    senses = obj.get("senses") or []
    if not has_any_lexical_gloss(senses):
        return False
    if entry_has_geo_topic(obj):
        return True
    first_lex = next(iter_lexical_gloss_texts(senses), None)
    if first_lex:
        if GEO_GLOSS_RE.search(first_lex):
            return True
        head = first_english_topo_headword(first_lex)
        if (
            head in EN_SOLO_TOPONYM_HEADWORDS
            and RU_TOPONYMIC_ADJ_SUFFIX_RE.search(lemma_norm)
        ):
            return True
    return False


def topic_string_matches_person_name_cat(s: str) -> bool:
    sl = s.lower()
    return any(marker in sl for marker in NAME_TOPIC_MARKERS)


def entry_has_person_name_category(obj: dict) -> bool:
    for t in obj.get("topics") or []:
        if isinstance(t, str) and topic_string_matches_person_name_cat(t):
            return True
    for sense in obj.get("senses") or []:
        for t in sense.get("topics") or []:
            if isinstance(t, str) and topic_string_matches_person_name_cat(t):
                return True
        for cat in sense.get("categories") or []:
            if isinstance(cat, dict):
                nm = cat.get("name")
                if isinstance(nm, str) and topic_string_matches_person_name_cat(nm):
                    return True
            elif isinstance(cat, str) and topic_string_matches_person_name_cat(cat):
                return True
    return False


def should_exclude_person_name_entry(obj: dict, first_lex: Optional[str]) -> bool:
    pos = (obj.get("pos") or "").strip().lower()
    if pos == "name":
        return True
    if entry_has_person_name_category(obj):
        return True
    if first_lex and PERSON_NAME_GLOSS_RE.search(first_lex):
        return True
    return False


def is_letter_name_only_entry(en: str, gloss_lines: list[str]) -> bool:
    """True when every gloss is about a letter name (no homonym senses like ша → shush)."""
    if not OPENRUSSIAN_LETTER_NAME_RE.search(en or ""):
        return False
    for gloss in gloss_lines:
        g = (gloss or "").strip()
        if not g or g == (en or "").strip():
            continue
        if OPENRUSSIAN_LETTER_NAME_RE.search(g):
            continue
        return False
    return True


def should_exclude_proper_noun_openrussian(
    ru: str,
    en: str,
    gloss_lines: list[str],
    *,
    geo_lemmas: frozenset[str],
) -> bool:
    """
    Drop OpenRussian rows whose learner headline is chiefly a placename, personal
    name, or letter name. Uses the English headline only (not secondary glosses)
    so vocabulary like имя / фамилия / остров stay in the dictionary.
    """
    lemma_norm = normalize_for_index(ru)
    if lemma_norm in geo_lemmas:
        return True
    if any(stem in lemma_norm for stem in TOPONYM_LEMMA_SUBSTRINGS):
        return True

    headline = (en or "").strip()
    if not headline:
        return False

    if is_letter_name_only_entry(headline, gloss_lines):
        return True

    if OPENRUSSIAN_PERSON_HEADLINE_RE.search(headline):
        return True

    head = first_english_topo_headword(headline)
    if head in GEO_VOCAB_HEADWORDS:
        return False

    if OPENRUSSIAN_PLACE_HEADLINE_RE.search(headline):
        return True

    if head in EN_SOLO_TOPONYM_HEADWORDS:
        return True

    return False


def read_frequency(path: Path) -> list[str]:
    out: list[str] = []
    seen: set[str] = set()
    with path.open(encoding="utf-8") as f:
        for line in f:
            parts = line.split()
            if not parts:
                continue
            lemma = normalize_lemma(parts[0])
            if not is_clean_lemma(lemma) or lemma in seen:
                continue
            seen.add(lemma)
            out.append(lemma)
    return out


def stream_kaikki(path: Path) -> Iterator[dict]:
    with path.open(encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def first_ipa(sounds: list) -> Optional[str]:
    for s in sounds or []:
        ipa = s.get("ipa")
        if isinstance(ipa, str) and ipa.strip():
            return ipa.strip().strip("/[]")
    return None


def canonical_surface(forms: list) -> Optional[str]:
    """Stressed Cyrillic headword when Wiktionary provides it (NFC)."""
    for f in forms or []:
        tags = f.get("tags") or []
        if "canonical" not in tags:
            continue
        form = f.get("form")
        if isinstance(form, str) and form.strip():
            return unicodedata.normalize("NFC", form.strip())
    return None


def letters_and_stress_letter_index(surface: str) -> tuple[str, Optional[int]]:
    """
    Strip stress marks; return (word_nfc, index of stressed letter in word_nfc).
    """
    nfd = unicodedata.normalize("NFD", surface)
    letters: list[str] = []
    stress_i: Optional[int] = None
    i = 0
    while i < len(nfd):
        if nfd[i] == "\u0301":
            if letters:
                stress_i = len(letters) - 1
            i += 1
            continue
        letters.append(nfd[i])
        i += 1
    word = unicodedata.normalize("NFC", "".join(letters))
    if stress_i is None:
        return word, None
    if len(letters) == len(word):
        return word, stress_i
    # Rare NFC length mismatch: find stressed char by scan
    stressed_ch = letters[stress_i]
    idx = 0
    for j, ch in enumerate(word):
        if ch == stressed_ch:
            idx = j
            break
    return word, idx


def syllables_ru(word: str) -> list[str]:
    wl = word.lower()
    vpos = [i for i, c in enumerate(wl) if c in VOWELS]
    if not vpos:
        return [word]
    out: list[str] = []
    for j, vp in enumerate(vpos):
        start = 0 if j == 0 else vpos[j - 1] + 1
        if j < len(vpos) - 1:
            out.append(word[start : vp + 1])
        else:
            out.append(word[start:])
    return out


def stressed_syllable_index(
    stress_letter_i: Optional[int], wl_lower: str
) -> int:
    """Which syllable (0-based) gets ALL CAPS."""
    vpos = [i for i, c in enumerate(wl_lower) if c in VOWELS]
    if not vpos:
        return 0
    if stress_letter_i is not None:
        for j, vp in enumerate(vpos):
            if vp == stress_letter_i:
                return j
        for j, vp in enumerate(vpos):
            if vp >= stress_letter_i:
                return j
        return len(vpos) - 1
    # ё is always stressed in Russian when present
    for j, vp in enumerate(vpos):
        if wl_lower[vp] == "ё":
            return j
    return 0 if len(vpos) == 1 else len(vpos) - 1


def romanize_consonants(cluster: str) -> str:
    parts: list[str] = []
    for ch in cluster.lower():
        if ch in "ъь":
            continue
        parts.append(CONS_LATIN.get(ch, ch))
    return "".join(parts)


def romanize_syllable_learner(syl: str) -> str:
    """
    English-friendly respelling for one syllable (lowercase, no hyphens).
    """
    s = syl.lower().strip()
    if not s:
        return ""

    out: list[str] = []
    i = 0
    n = len(s)

    while i < n:
        c = s[i]
        if c.lower() in "ъь":
            if c == "ь" and out and i + 1 < n and s[i + 1].lower() in VOWELS:
                last_lat = out[-1]
                if last_lat and last_lat[-1] not in "yaeiouh":
                    if last_lat[-1] in "dtslznrpbvgkmf" and not last_lat.endswith("y"):
                        out[-1] = last_lat + "y"
            i += 1
            continue

        if c.lower() not in VOWELS:
            j = i
            while j < n and s[j].lower() not in VOWELS and s[j] not in "ъь":
                j += 1
            cluster = s[i:j]
            soft = False
            if j < n and s[j] == "ь":
                soft = True
                j += 1
            lat = romanize_consonants(cluster)
            if soft and lat and cluster and cluster[-1].lower() in "дтсзлнрпбвгкмфхцчшщ":
                if not lat.endswith("y"):
                    lat = lat + "y"
            out.append(lat)
            i = j
            continue

        # vowel
        cl = c.lower()
        leading_cons = bool(out and out[-1] and out[-1][-1] not in "aeiouyh")

        if cl == "я":
            out.append("ya")
        elif cl == "ё":
            out.append("yo")
        elif cl == "ю":
            out.append("yu")
        elif cl == "е":
            out.append("ye" if leading_cons else "ye")
        elif cl == "и":
            out.append("ee")
        elif cl == "ы":
            out.append("ih")
        elif cl == "о":
            out.append("oh")
        elif cl == "а":
            out.append("ah")
        elif cl == "у":
            out.append("oo")
        elif cl == "э":
            out.append("eh")
        else:
            out.append(cl)
        i += 1

    return "".join(out)


def english_phrasebook_pronunciation(
    surface_stressed: Optional[str], lemma_plain: str
) -> Optional[str]:
    """
    hyphenated syllables; stressed syllable in ALL CAPS (user request).
    """
    if surface_stressed:
        word, stress_ch_i = letters_and_stress_letter_index(surface_stressed)
    else:
        word = unicodedata.normalize("NFC", lemma_plain.strip())
        stress_ch_i = None
    wl = word.lower()
    syl = syllables_ru(word)
    if not syl:
        return None
    stress_syl_i = stressed_syllable_index(stress_ch_i, wl)
    stress_syl_i = min(stress_syl_i, len(syl) - 1)

    parts: list[str] = []
    for idx, syll in enumerate(syl):
        chunk = romanize_syllable_learner(syll)
        if not chunk:
            continue
        if idx == stress_syl_i:
            chunk = chunk.upper()
        parts.append(chunk)
    if not parts:
        return None
    return "-".join(parts)


def first_romanization_simple(forms: list) -> Optional[str]:
    """Wiktionary Latin (scholarly); used as fallback only."""
    for f in forms or []:
        tags = f.get("tags") or []
        if "romanization" not in tags:
            continue
        form = f.get("form")
        if isinstance(form, str) and form.strip():
            # Normalize j → y for English readers.
            return (
                form.strip()
                .replace("j", "y")
                .replace("J", "Y")
            )
    return None


def pronunciation_for_entry(
    word: str, forms: list, sounds: list
) -> Optional[str]:
    surface = canonical_surface(forms)
    eng = english_phrasebook_pronunciation(surface, word)
    if eng:
        return eng
    rom = first_romanization_simple(forms)
    if rom:
        return rom
    return first_ipa(sounds)


def kaikki_row_rank(obj: dict) -> int:
    """Prefer dictionary-style POS rows when Kaikki repeats the same surface."""
    score = 0
    for t in obj.get("head_templates") or []:
        if not isinstance(t, dict):
            continue
        blob = f"{t.get('name', '')} {t.get('expansion', '')}"
        bl = blob.lower()
        if "past passive participle" in bl:
            score -= 60_000
        if "participle" in bl and ("verb form" in bl or "head" in bl):
            score -= 40_000
        if "verb form" in bl:
            score -= 12_000
        if "adjective form" in bl:
            score -= 4_000
        if "pronoun form" in bl:
            score -= 3_000
        if "determiner form" in bl:
            score -= 2_000
        if "predicative form" in bl or "adverb form" in bl:
            score -= 1_500
        if "noun form" in bl:
            score -= 2_200
        if "romanization" in bl:
            score -= 5_000

    pos = (obj.get("pos") or "").lower()
    # When Kaikki splits the same surface into several POS rows (e.g. по́мочь
    # verb vs belt noun, посторо́нний adjective vs “stranger” noun), the old
    # ordering preferred noun over verb/adj. Learner entries should keep the
    # core lemma sense.
    pos_bump = {
        "adv": 80,
        "det": 76,
        "pron": 74,
        "verb": 64,
        "adj": 62,
        "noun": 54,
        "name": -180,
        "particle": 50,
        "conj": 48,
    }
    score += pos_bump.get(pos, 42)
    return score


def collect_lemma_best(
    kaikki_path: Path,
    lemma_allowlist: AbstractSet[str],
    common_lemmas: AbstractSet[str],
    geo_lemmas: frozenset[str],
) -> dict[str, tuple[int, tuple]]:
    """
    Map normalized lemma → (rank, candidate tuple) using the same filters and
    merge rules as a full build. Only Kaikki rows tagged noun/verb/adj/adverb/num
    (see LEXICAL_BUILD_POS) participate. Used by build() and
    refresh_lexeme_preferences().
    """
    lemma_best: dict[str, tuple[int, tuple]] = {}
    for obj in stream_kaikki(kaikki_path):
        word = obj.get("word")
        if not isinstance(word, str):
            continue
        lemma = normalize_lemma(word)
        if not is_clean_lemma(lemma) or lemma not in lemma_allowlist:
            continue
        pos_raw = (obj.get("pos") or "").strip().lower()
        if pos_raw not in LEXICAL_BUILD_POS:
            continue
        senses = obj.get("senses") or []
        if not has_any_lexical_gloss(senses):
            continue
        if should_exclude_place_entry(obj, lemma, geo_lemmas):
            continue
        raw = next(iter_lexical_gloss_texts(senses), None)
        if not raw:
            continue
        if should_exclude_person_name_entry(obj, raw):
            continue
        glosses = unique_glosses(senses, limit=MAX_GLOSSES)
        if not glosses:
            continue

        headline = glosses[0]
        english = (
            headline[: MAX_GLOSS_LEN - 1].rstrip() + "…"
            if len(headline) > MAX_GLOSS_LEN
            else headline
        )
        meaning = make_meaning_description(glosses)

        pos = pos_raw or None
        glosses_blob = "\n".join(glosses) if glosses else None
        ph = pronunciation_for_entry(word, obj.get("forms") or [], obj.get("sounds") or [])
        rk = kaikki_row_rank(obj)
        cand = (
            word,
            english,
            meaning,
            pos,
            glosses_blob,
            ph,
            normalize_for_index(word),
            normalize_for_index(english),
            1 if lemma in common_lemmas else 0,
            lemma,
        )

        prev = lemma_best.get(lemma)
        if prev is None or rk > prev[0]:
            lemma_best[lemma] = (rk, cand)

    return lemma_best


def apply_manual_lexeme_fixes(conn: sqlite3.Connection) -> None:
    """
    Kaikki occasionally picks the wrong sense for a surface form (homograph).
    Patch specific word_id rows and keep words_fts aligned with ru_norm / en_norm.
    """
    fixes: list[dict[str, str]] = [
        {
            "id": "pomoch",
            "en": "to help",
            "pos": "verb",
            "meaning_en": "to help",
            "glosses_en": "to help\nhelp\nassist",
        },
        {
            "id": "postoronniy",
            "en": "extraneous",
            "pos": "adj",
            "meaning_en": "extraneous; foreign; outsider (substantive)",
            "glosses_en": "extraneous\nforeign\noutside\nstranger",
        },
    ]
    for f in fixes:
        en_norm = normalize_for_index(f["en"])
        cur = conn.execute(
            "UPDATE words SET en = ?, pos = ?, en_norm = ?, meaning_en = ?, glosses_en = ? "
            "WHERE id = ?",
            (f["en"], f["pos"], en_norm, f["meaning_en"], f["glosses_en"], f["id"]),
        )
        if cur.rowcount == 0:
            continue
        row = conn.execute(
            "SELECT ru_norm, en_norm FROM words WHERE id = ?",
            (f["id"],),
        ).fetchone()
        if row:
            conn.execute(
                "UPDATE words_fts SET ru = ?, en = ? WHERE id = ?",
                (row[0], row[1], f["id"]),
            )


def build(args: argparse.Namespace) -> int:
    print(f"Reading frequency list: {args.freq}")
    freq = read_frequency(args.freq)
    freq_set = set(freq)
    common_set = set(freq[: args.common_limit])
    print(f"  ↳ {len(freq)} ranked lemmas; top {len(common_set)} flagged common")

    print(f"Streaming Kaikki dump: {args.kaikki}")

    geo_lemmas = load_geo_blocklist(SCRIPT_DIR / "geo_lemma_blocklist.txt")

    lemma_best = collect_lemma_best(args.kaikki, freq_set, common_set, geo_lemmas)

    used_ids = set[str]()
    rows: list[tuple] = []
    for lem in freq:
        got = lemma_best.get(lem)
        if got is None:
            continue
        _rk, cand = got
        w_surface, english, meaning, pos, glosses_blob, ph, ru_i, en_i, is_common_f, _lemma_dup = cand
        rows.append(
            (
                slugify(w_surface, used_ids),
                w_surface,
                english,
                meaning,
                pos,
                glosses_blob,
                None,
                ph,
                ru_i,
                en_i,
                is_common_f,
            )
        )

    print(f"  ↳ built {len(rows)} entries; "
          f"{sum(1 for r in rows if r[10] == 1)} marked common")

    out_path: Path = args.out
    out_path.parent.mkdir(parents=True, exist_ok=True)
    if out_path.exists():
        out_path.unlink()

    print(f"Writing SQLite: {out_path}")
    # isolation_level=None → autocommit; we manage all transactions explicitly
    # so Python's sqlite3 module never inserts an implicit BEGIN that conflicts
    # with our own BEGIN / executescript calls.
    conn = sqlite3.connect(out_path, isolation_level=None)
    try:
        conn.executescript(
            "PRAGMA synchronous=OFF;"
            "PRAGMA journal_mode=MEMORY;"
            "PRAGMA temp_store=MEMORY;"
        )
        conn.executescript(SCHEMA_SQL)
        conn.execute("BEGIN")
        conn.execute(
            "INSERT INTO dictionary_version(value) VALUES (?)",
            (DICTIONARY_VERSION,),
        )
        conn.executemany(
            "INSERT INTO words(id, ru, en, meaning_en, pos, glosses_en, phonetic, "
            "ai_note_en, ru_norm, en_norm, is_common) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
            rows,
        )
        conn.executemany(
            "INSERT INTO words_fts(id, ru, en) VALUES (?, ?, ?)",
            ((r[0], r[8], r[9]) for r in rows),
        )
        apply_manual_lexeme_fixes(conn)
        conn.execute("COMMIT")
        conn.executescript("PRAGMA optimize;")
        conn.execute("VACUUM")
    finally:
        conn.close()

    size_mb = out_path.stat().st_size / (1024 * 1024)
    print(f"Done. {len(rows)} entries, {size_mb:.1f} MB.")
    return 0


def refresh_lexeme_preferences(args: argparse.Namespace) -> int:
    """Re-run Kaikki merge for every lemma in an existing DB; update changed rows."""
    sqlite_path: Path = args.refresh_sqlite
    geo_lemmas = load_geo_blocklist(SCRIPT_DIR / "geo_lemma_blocklist.txt")

    conn = sqlite3.connect(sqlite_path, isolation_level=None)
    try:
        rows = conn.execute(
            "SELECT id, ru, ru_norm, en, meaning_en, pos, glosses_en, phonetic, en_norm, is_common "
            "FROM words"
        ).fetchall()
    finally:
        conn.close()

    lemma_allowlist = {normalize_lemma(r[1]) for r in rows}
    common_lemmas = {
        normalize_lemma(r[1]) for r in rows if r[9] == 1
    }

    print(
        f"Re-scoring {len(lemma_allowlist)} lemmas from Kaikki "
        f"({len(common_lemmas)} marked common in DB)…"
    )
    lemma_best = collect_lemma_best(args.kaikki, lemma_allowlist, common_lemmas, geo_lemmas)

    conn = sqlite3.connect(sqlite_path, isolation_level=None)
    try:
        conn.execute("BEGIN")
        updated = 0
        missing_lemmas: set[str] = set()
        for (
            wid,
            ru,
            ru_norm,
            en,
            meaning_en,
            pos,
            glosses_en,
            phonetic,
            en_norm,
            is_common,
        ) in rows:
            lem = normalize_lemma(ru)
            got = lemma_best.get(lem)
            if got is None:
                missing_lemmas.add(lem)
                continue
            _rk, cand = got
            (
                _w_surface,
                english,
                meaning,
                win_pos,
                glosses_blob,
                ph,
                ru_i,
                en_i,
                _is_common_f,
                _lemma_dup,
            ) = cand

            def norm_text(x: Optional[str]) -> str:
                return "" if x is None else x

            if (
                en == english
                and norm_text(meaning_en) == norm_text(meaning)
                and norm_text(pos).lower() == norm_text(win_pos).lower()
                and norm_text(glosses_en) == norm_text(glosses_blob)
                and norm_text(phonetic) == norm_text(ph)
                and en_norm == en_i
            ):
                continue

            conn.execute(
                "UPDATE words SET en = ?, meaning_en = ?, pos = ?, glosses_en = ?, "
                "phonetic = ?, en_norm = ? WHERE id = ?",
                (english, meaning, win_pos, glosses_blob, ph, en_i, wid),
            )
            conn.execute(
                "UPDATE words_fts SET ru = ?, en = ? WHERE id = ?",
                (ru_norm, en_i, wid),
            )
            updated += 1

        conn.execute("DELETE FROM dictionary_version")
        conn.execute(
            "INSERT INTO dictionary_version(value) VALUES (?)",
            (DICTIONARY_VERSION,),
        )
        apply_manual_lexeme_fixes(conn)
        conn.execute("COMMIT")
        conn.executescript("PRAGMA optimize;")
        print(
            f"Updated {updated} words; no Kaikki candidate for "
            f"{len(missing_lemmas)} distinct normalized lemmas "
            "(often morphology-only heads)."
        )
    finally:
        conn.close()

    return 0


_SCRUB_OF_CYRILLIC_LEMMA_RE = re.compile(r"\s+of\s+[\u0400-\u04FF]+", re.IGNORECASE)
_ALT_FORM_HEADWORD_RE = re.compile(r"(?is)^alternative\s+(form|spelling)\s+of\b")
_TRUNCATED_FINITE_VERB_RE = re.compile(
    r"(?is)\b(?:masculine|feminine|neuter)\b[^\n]{0,180}\b(?:past|present|future)\s+indicative\b"
)
_HEADWORD_CASE_OR_NUMBER_RE = re.compile(
    r"(?is)^(?:genitive|dative|accusative|instrumental|prepositional|locative|"
    r"vocative|ablative|nominative|plural|singular|comparative|superlative)\b"
)


def english_headword_is_scrubbable_morph(en: str) -> bool:
    """
    True when `en` is Wiktionary-style morphology pointing at a Russian lemma
    (\"… of позвонить\"), an \"inflection of …\" surface gloss, an alternative
    spelling head, or a finite-verb/case headline truncated before \" of …\".
    """
    t = (en or "").strip()
    if not t:
        return False
    if re.search(r"(?is)\binflection\s+of\b", t):
        return True
    if _ALT_FORM_HEADWORD_RE.match(t):
        return True
    if not is_hard_morph_gloss(t):
        return False
    if _SCRUB_OF_CYRILLIC_LEMMA_RE.search(t):
        return True
    if _TRUNCATED_FINITE_VERB_RE.search(t):
        return True
    if _HEADWORD_CASE_OR_NUMBER_RE.match(t):
        return True
    return False


def scrub_morph_headwords_in_sqlite(db_path: Path) -> int:
    """
    Delete `words` rows whose primary English string is Wiktionary-style
    morphology (same rules as learner gloss filtering). Removes matching FTS
    rows. Sets `dictionary_version` to DICTIONARY_VERSION.
    """
    conn = sqlite3.connect(db_path, isolation_level=None)
    try:
        conn.execute("BEGIN IMMEDIATE")
        rows = list(conn.execute("SELECT id, en FROM words"))
        to_delete: list[str] = []
        for wid, en in rows:
            t = (en or "").strip()
            if not t:
                continue
            if english_headword_is_scrubbable_morph(t):
                to_delete.append(str(wid))
        n_del = len(to_delete)
        print(
            f"Morph-headword scrub: deleting {n_del} of {len(rows)} rows from {db_path}"
        )
        chunk_size = 400
        for i in range(0, n_del, chunk_size):
            chunk = to_delete[i : i + chunk_size]
            ph = ",".join("?" * len(chunk))
            conn.execute(f"DELETE FROM words_fts WHERE id IN ({ph})", chunk)
            conn.execute(f"DELETE FROM words WHERE id IN ({ph})", chunk)
        remaining = conn.execute("SELECT COUNT(*) FROM words").fetchone()[0]
        conn.execute("DELETE FROM dictionary_version")
        conn.execute(
            "INSERT INTO dictionary_version(value) VALUES (?)",
            (DICTIONARY_VERSION,),
        )
        conn.execute("COMMIT")
        conn.execute("PRAGMA optimize")
        print(f"  ↳ committed; {remaining} words; dictionary_version={DICTIONARY_VERSION}")
        return 0
    except BaseException:
        with contextlib.suppress(Exception):
            conn.execute("ROLLBACK")
        raise
    finally:
        conn.close()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--scrub-morph-headwords-in",
        type=Path,
        default=None,
        metavar="PATH",
        help=(
            "Delete rows whose English headword is morphology-only (see "
            "is_hard_morph_gloss). Updates words_fts and dictionary_version. "
            "Does not require --kaikki or --freq."
        ),
    )
    ap.add_argument(
        "--kaikki",
        required=False,
        type=Path,
        default=DEFAULT_KAIKKI,
        help=f"Kaikki Russian JSONL (default: {DEFAULT_KAIKKI})",
    )
    ap.add_argument(
        "--freq",
        required=False,
        type=Path,
        default=DEFAULT_FREQ,
        help=f"frequency list lemma allowlist (default: {DEFAULT_FREQ})",
    )
    ap.add_argument(
        "--refresh-sqlite",
        type=Path,
        default=None,
        metavar="PATH",
        help=(
            "Re-merge Kaikki rows for lemmas already in this DB; bumps "
            "dictionary_version and applies manual_lexeme_fixes "
            f"(currently {DICTIONARY_VERSION})."
        ),
    )
    ap.add_argument("--common-limit", type=int, default=5000)
    ap.add_argument(
        "--out",
        type=Path,
        default=Path("RussianWordADayApp/Resources/dictionary.sqlite"),
    )
    args = ap.parse_args()

    if args.scrub_morph_headwords_in is not None:
        if not args.scrub_morph_headwords_in.exists():
            print(
                f"sqlite DB not found: {args.scrub_morph_headwords_in}",
                file=sys.stderr,
            )
            return 2
        return scrub_morph_headwords_in_sqlite(args.scrub_morph_headwords_in)

    if args.kaikki is None or not str(args.kaikki):
        print(
            "--kaikki is required unless --scrub-morph-headwords-in is given "
            f"(default: {DEFAULT_KAIKKI})",
            file=sys.stderr,
        )
        return 2
    if not args.kaikki.exists():
        print(f"kaikki dump not found: {args.kaikki}", file=sys.stderr)
        return 2
    if args.refresh_sqlite is not None:
        if not args.refresh_sqlite.exists():
            print(f"sqlite DB not found: {args.refresh_sqlite}", file=sys.stderr)
            return 2
        return refresh_lexeme_preferences(args)

    if args.freq is None or not str(args.freq):
        print(
            f"--freq is required unless --refresh-sqlite is given (default: {DEFAULT_FREQ})",
            file=sys.stderr,
        )
        return 2
    if not args.freq.exists():
        print(f"frequency list not found: {args.freq}", file=sys.stderr)
        return 2
    return build(args)


if __name__ == "__main__":
    sys.exit(main())
