#!/usr/bin/env python3
"""Check ScreenClip string catalogs for missing translations, placeholder drift, and the screenshot fixture."""
import json
import pathlib
import re
import sqlite3
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
LANGS = ["en", "zh-Hans", "es", "ja", "pt-BR", "de", "fr", "ko", "ru", "zh-Hant"]
PRODUCTS = ["ScreenClip", "Grok Bot", "Claude Code", "Codex", "GitHub"]
SPEC = re.compile(r"%(?:\d+\$)?(?:@|lld|ld|d|f|lf)|%%")


def unesc(value: str) -> str:
    return bytes(value, "utf-8").decode("unicode_escape").encode("latin1").decode("utf-8")


def source_files():
    return (ROOT / "Sources").rglob("*.swift")


def simple_keys() -> set[str]:
    keys = set()
    for path in source_files():
        text = path.read_text(encoding="utf-8")
        for match in re.finditer(r'(?:chrome:\s*|Chrome\.text\(\s*)"((?:\\.|[^"\\])*)"', text):
            keys.add(unesc(match.group(1)))
        for match in re.finditer(r"static let exact: Set<String> = \[(.*?)\]\n", text, re.S):
            for item in re.findall(r'"((?:\\.|[^"\\])*)"', match.group(1)):
                keys.add(unesc(item))
    return keys


def format_keys() -> set[str]:
    keys = set()
    for path in source_files():
        text = path.read_text(encoding="utf-8")
        keys.update(re.findall(r'(?:Chrome\.format|localized:)\(\s*\n?\s*"([A-Za-z0-9_.]+)"', text))
    return keys


def load(path: pathlib.Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def leaf_values(node: dict) -> list[str]:
    if "stringUnit" in node:
        return [node["stringUnit"].get("value", "")]
    values = []
    for child in node.get("variations", {}).get("plural", {}).values():
        values.extend(leaf_values(child))
    return values


def specs(value: str) -> list[str]:
    return SPEC.findall(value)


def pseudolocalize(value: str) -> str:
    table = str.maketrans({"a": "à", "e": "é", "i": "í", "o": "ó", "u": "ú", "A": "À", "E": "É", "O": "Ó"})
    return "⟦" + value.translate(table) + "⟧"


def main() -> int:
    errors = []
    app = load(ROOT / "Sources/ScreenClip/Localizable.xcstrings")
    core = load(ROOT / "Sources/ScreenClipCore/Localizable.xcstrings")
    info = load(ROOT / "Resources/InfoPlist.xcstrings")
    needed = simple_keys()
    missing = sorted(key for key in needed if key not in app["strings"])
    if missing:
        errors.append(f"{len(missing)} interface strings are missing from the app catalog")
        errors.extend("  " + key for key in missing[:20])
    core_text = (ROOT / "Sources/ScreenClipCore/Localization.swift").read_text(encoding="utf-8")
    core_match = re.search(r"static let exact: Set<String> = \[(.*)\]\n\}", core_text, re.S)
    core_needed = {unesc(item) for item in re.findall(r'"((?:\\.|[^"\\])*)"', core_match.group(1))}
    for key in sorted(core_needed):
        if key not in core["strings"]:
            errors.append(f"core catalog missing {key!r}")
    for key in sorted(format_keys()):
        if key not in app["strings"] and key not in core["strings"]:
            errors.append(f"format key missing from catalogs: {key}")
    for label, catalog in ("app", app), ("core", core), ("info", info):
        for key, entry in catalog["strings"].items():
            localizations = entry.get("localizations", {})
            for lang in LANGS:
                if lang not in localizations:
                    errors.append(f"{label} {key!r} missing {lang}")
                    continue
                values = leaf_values(localizations[lang])
                if not values or any(not value.strip() for value in values):
                    errors.append(f"{label} {key!r} has an empty {lang} value")
            english_node = localizations.get("en", {})
            english_forms = english_node.get("variations", {}).get("plural", {})
            english_values = leaf_values(english_node)
            for lang in LANGS:
                if lang not in localizations:
                    continue
                forms = localizations[lang].get("variations", {}).get("plural")
                pairs = []
                if forms and english_forms:
                    for category, node in forms.items():
                        source_node = english_forms.get(category) or english_forms.get("other")
                        if source_node is None:
                            errors.append(f"{label} {key!r} {lang} has unexpected plural {category}")
                            continue
                        pairs.append((leaf_values(source_node)[0], leaf_values(node)[0]))
                else:
                    pairs = list(zip(english_values, leaf_values(localizations[lang])))
                for source, value in pairs:
                    if specs(source) != specs(value):
                        errors.append(
                            f"{label} {key!r} {lang} placeholders {specs(value)} != {specs(source)}"
                        )
                    for name in PRODUCTS:
                        if name in source and name not in value:
                            errors.append(f"{label} {key!r} {lang} dropped {name}")
                    for token in ("screenclip.external.v1.test", "screenclip/", "⌘"):
                        if token in source and token not in value:
                            errors.append(f"{label} {key!r} {lang} dropped {token!r}")
    sample = pseudolocalize("Open queue")
    if not (sample.startswith("⟦") and sample.endswith("⟧") and len(sample) > len("Open queue")):
        errors.append("pseudolocalization did not expand a sample string")
    fixture = ROOT / "Fixtures/ScreenshotData"
    total = sum(path.stat().st_size for path in fixture.rglob("*") if path.is_file())
    if total > 10 * 1024 * 1024:
        errors.append(f"screenshot fixture is {total / 1024 / 1024:.1f} MB; keep it under 10 MB")
    database = fixture / "screenclip.sqlite"
    if not database.exists():
        errors.append("screenshot fixture is missing screenclip.sqlite")
    else:
        payload = json.loads(sqlite3.connect(database).execute("select payload from state").fetchone()[0])
        absent = []
        for issue in payload["issues"]:
            for capture in issue.get("captures") or []:
                for field, folder in ("imagePath", "assets"), ("originalPath", "originals"):
                    raw = capture.get(field)
                    if raw and not (fixture / folder / pathlib.Path(raw).name).exists():
                        absent.append(f"{folder}/{pathlib.Path(raw).name}")
        if absent:
            errors.append("fixture images missing: " + ", ".join(absent[:8]))
    if errors:
        print("\n".join(errors))
        return 1
    print(
        f"catalogs ok: app {len(app['strings'])}, core {len(core['strings'])}, "
        f"info {len(info['strings'])}; fixture {total / 1024 / 1024:.2f} MB"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
