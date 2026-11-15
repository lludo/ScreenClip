#!/usr/bin/env python3
"""Build ScreenClip String Catalogs from the translation tables in scripts/l10n_part1.py, l10n_part2.py, l10n_part3.py and l10n_formats.py."""
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
LANGS = ["en", "zh-Hans", "es", "ja", "pt-BR", "de", "fr", "ko", "ru", "zh-Hant"]
sys.path.insert(0, str(ROOT / "scripts"))
from l10n_part3 import T as SIMPLE_ROWS  # noqa: E402
from l10n_formats import FORMATS, INFO_PLIST  # noqa: E402


def unesc(value: str) -> str:
    return bytes(value, "utf-8").decode("unicode_escape").encode("latin1").decode("utf-8")


def swift_keys() -> set[str]:
    text = "\n".join(path.read_text(encoding="utf-8") for path in (ROOT / "Sources").rglob("*.swift"))
    keys = set()
    for match in re.finditer(r'(?:chrome:\s*|Chrome\.text\(\s*)"((?:\\.|[^"\\])*)"', text):
        keys.add(unesc(match.group(1)))
    for match in re.finditer(r"static let exact: Set<String> = \[(.*?)\]", text, re.S):
        for item in re.findall(r'"((?:\\.|[^"\\])*)"', match.group(1)):
            keys.add(unesc(item))
    return keys


def unit(value: str) -> dict:
    return {"stringUnit": {"state": "translated", "value": value}}


def simple_entry(comment: str, values: dict) -> dict:
    return {
        "comment": comment,
        "extractionState": "manual",
        "localizations": {lang: unit(values[lang]) for lang in LANGS},
    }


def plural_entry(comment: str, forms: dict) -> dict:
    localizations = {}
    for lang in LANGS:
        variations = {
            category: unit(text) for category, text in forms[lang].items()
        }
        localizations[lang] = {"variations": {"plural": variations}}
    return {"comment": comment, "extractionState": "manual", "localizations": localizations}


def catalog(strings: dict) -> dict:
    return {"sourceLanguage": "en", "strings": strings, "version": "1.0"}


def comments_from_source() -> dict[str, str]:
    text = "\n".join(path.read_text(encoding="utf-8") for path in (ROOT / "Sources").rglob("*.swift"))
    found = {}
    pattern = re.compile(
        r'(?:chrome:\s*|Chrome\.text\(\s*)"((?:\\.|[^"\\])*)"\s*,\s*comment:\s*"((?:\\.|[^"\\])*)"'
    )
    for match in pattern.finditer(text):
        found.setdefault(unesc(match.group(1)), unesc(match.group(2)))
    return found


def core_exact_keys() -> set[str]:
    text = (ROOT / "Sources/ScreenClipCore/Localization.swift").read_text(encoding="utf-8")
    match = re.search(r"static let exact: Set<String> = \[(.*)\]\n\}", text, re.S)
    return {unesc(item) for item in re.findall(r'"((?:\\.|[^"\\])*)"', match.group(1))}


def values_for(row: list[str], english: str) -> dict[str, str]:
    mapped = dict(zip(LANGS[1:], row))
    mapped["en"] = english
    return mapped


def main() -> int:
    comments = comments_from_source()
    missing = sorted(swift_keys() - set(SIMPLE_ROWS))
    if missing:
        print("Missing translations:", file=sys.stderr)
        for key in missing:
            print(key, file=sys.stderr)
        return 1
    app_strings = {}
    core_exact = core_exact_keys()
    core_strings = {}
    for key, row in SIMPLE_ROWS.items():
        entry = simple_entry(comments.get(key, "ScreenClip interface text."), values_for(row, key))
        app_strings[key] = entry
        if key in core_exact:
            core_strings[key] = entry
    for key, item in FORMATS.items():
        if item.get("plural"):
            entry = plural_entry(item["comment"], item["forms"])
        else:
            entry = simple_entry(item["comment"], item["values"])
        if item["bundle"] in ("app", "both"):
            app_strings[key] = entry
        if item["bundle"] in ("core", "both"):
            core_strings[key] = entry
    (ROOT / "Sources/ScreenClip/Localizable.xcstrings").write_text(
        json.dumps(catalog(app_strings), ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    (ROOT / "Sources/ScreenClipCore/Localizable.xcstrings").write_text(
        json.dumps(catalog(core_strings), ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    info = {}
    for key, item in INFO_PLIST.items():
        info[key] = simple_entry(item["comment"], item["values"])
    (ROOT / "Resources/InfoPlist.xcstrings").write_text(
        json.dumps(catalog(info), ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(
        f"app {len(app_strings)} core {len(core_strings)} info {len(info)} simple {len(SIMPLE_ROWS)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
