#!/usr/bin/env python3
"""Build compact JSON for verb conjugation / noun declension from OpenRussian CSVs."""
from __future__ import annotations

import csv
import json
import re
from collections import defaultdict
from pathlib import Path

VERB_PERSON_LABELS = {
    "ru_verb_presfut_sg1": "я",
    "ru_verb_presfut_sg2": "ты",
    "ru_verb_presfut_sg3": "он/она",
    "ru_verb_presfut_pl1": "мы",
    "ru_verb_presfut_pl2": "вы",
    "ru_verb_presfut_pl3": "они",
}

VERB_PAST_LABELS = {
    "ru_verb_past_m": "masculine",
    "ru_verb_past_f": "feminine",
    "ru_verb_past_n": "neuter",
    "ru_verb_past_pl": "plural",
}

VERB_IMPERATIVE_ORDER = (
    ("ru_verb_imperative_sg", "ты"),
    ("ru_verb_imperative_pl", "вы"),
)

FUTURE_AUX = (
    ("я", "бу́ду"),
    ("ты", "бу́дешь"),
    ("он/она", "бу́дет"),
    ("мы", "бу́дем"),
    ("вы", "бу́дете"),
    ("они", "бу́дут"),
)

NOUN_CASE_ORDER = (
    ("nom", "nominative"),
    ("gen", "genitive"),
    ("dat", "dative"),
    ("acc", "accusative"),
    ("inst", "instrumental"),
    ("prep", "prepositional"),
)


def load_verbs_meta(csv_dir: Path) -> dict[int, dict[str, str]]:
    path = csv_dir / "openrussian_public - verbs.csv"
    out: dict[int, dict[str, str]] = {}
    if not path.exists():
        return out
    with path.open(encoding="utf-8-sig", newline="") as f:
        for row in csv.DictReader(f):
            try:
                wid = int((row.get("word_id") or "").strip())
            except ValueError:
                continue
            aspect = (row.get("aspect") or "").strip()
            partner = (row.get("partner") or "").strip()
            out[wid] = {"aspect": aspect, "partner": partner}
    return out


def load_forms_index(csv_dir: Path) -> dict[int, dict[str, str]]:
    path = csv_dir / "openrussian_public - words_forms.csv"
    index: dict[int, dict[str, str]] = defaultdict(dict)
    if not path.exists():
        return index
    with path.open(encoding="utf-8-sig", newline="") as f:
        for row in csv.DictReader(f):
            try:
                wid = int((row.get("word_id") or "").strip())
            except ValueError:
                continue
            ft = (row.get("form_type") or "").strip()
            if not ft:
                continue
            form = (row.get("form") or row.get("form_bare") or "").strip()
            if not form:
                continue
            # Keep first form per type (position 1 is typical).
            if ft not in index[wid]:
                index[wid][ft] = form
    return index


def _rows_from_types(
    forms: dict[str, str], mapping: list[tuple[str, str]]
) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    for key, label in mapping:
        val = forms.get(key)
        if val:
            rows.append({"label": label, "value": val})
    return rows


def _future_rows(bare: str) -> list[dict[str, str]]:
    inf = bare.strip()
    if not inf:
        return []
    return [{"label": label, "value": f"{aux} {inf}"} for label, aux in FUTURE_AUX]


def build_verb_forms_json(
    word_id: int,
    bare: str,
    forms: dict[str, str],
    verb_meta: dict[str, str],
) -> str | None:
    present = _rows_from_types(forms, list(VERB_PERSON_LABELS.items()))
    past = _rows_from_types(forms, list(VERB_PAST_LABELS.items()))
    imperative = _rows_from_types(forms, list(VERB_IMPERATIVE_ORDER))
    if not present and not past and not imperative:
        return None

    blocks: list[dict] = []
    if present:
        blocks.append({"name": "Present", "rows": present})
    aspect = (verb_meta.get("aspect") or "").strip().lower()
    if aspect == "imperfective" and bare:
        future = _future_rows(bare)
        if future:
            blocks.append({"name": "Future", "rows": future})
    if imperative:
        blocks.append({"name": "Imperative", "rows": imperative})
    if past:
        blocks.append({"name": "Past", "rows": past})

    note_parts: list[str] = []
    if aspect:
        note_parts.append(f"{aspect} aspect")
    partner = (verb_meta.get("partner") or "").strip()
    if partner:
        note_parts.append(f"partner {partner}")
    note = " · ".join(note_parts) if note_parts else None

    payload = {"title": "Conjugation", "note": note, "blocks": blocks, "table": None}
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":"))


def build_noun_forms_json(forms: dict[str, str]) -> str | None:
    rows_out: list[dict] = []
    for case_key, case_label in NOUN_CASE_ORDER:
        sg = forms.get(f"ru_noun_sg_{case_key}")
        pl = forms.get(f"ru_noun_pl_{case_key}")
        if not sg and not pl:
            continue
        rows_out.append(
            {
                "label": case_label,
                "cells": [sg or "—", pl or "—"],
            }
        )
    if not rows_out:
        return None
    table = {
        "columns": ["", "singular", "plural"],
        "rows": rows_out,
    }
    payload = {"title": "Declension", "note": None, "blocks": None, "table": table}
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":"))


def build_forms_json_for_word(
    *,
    word_id: int,
    bare: str,
    pos: str | None,
    forms_index: dict[int, dict[str, str]],
    verbs_meta: dict[int, dict[str, str]],
) -> str | None:
    forms = forms_index.get(word_id)
    if not forms:
        return None
    pos_l = (pos or "").strip().lower()
    if pos_l == "verb":
        return build_verb_forms_json(
            word_id, bare, forms, verbs_meta.get(word_id, {})
        )
    if pos_l == "noun":
        return build_noun_forms_json(forms)
    return None
