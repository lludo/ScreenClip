"""Locale files and safe string interpolation for the static site."""

import html
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent
LOCALES = [
    {"id": "en", "path": "", "html_lang": "en", "hreflang": "en", "og": "en_US"},
    {"id": "zh-Hans", "path": "zh-hans", "html_lang": "zh-Hans", "hreflang": "zh-Hans", "og": "zh_CN"},
    {"id": "es", "path": "es", "html_lang": "es", "hreflang": "es", "og": "es_ES"},
    {"id": "ja", "path": "ja", "html_lang": "ja", "hreflang": "ja", "og": "ja_JP"},
    {"id": "pt-BR", "path": "pt-br", "html_lang": "pt-BR", "hreflang": "pt-BR", "og": "pt_BR"},
    {"id": "de", "path": "de", "html_lang": "de", "hreflang": "de", "og": "de_DE"},
    {"id": "fr", "path": "fr", "html_lang": "fr", "hreflang": "fr", "og": "fr_FR"},
    {"id": "ko", "path": "ko", "html_lang": "ko", "hreflang": "ko", "og": "ko_KR"},
    {"id": "ru", "path": "ru", "html_lang": "ru", "hreflang": "ru", "og": "ru_RU"},
    {"id": "zh-Hant", "path": "zh-hant", "html_lang": "zh-Hant", "hreflang": "zh-Hant", "og": "zh_TW"},
]

CODES = {
    "appSupport": "~/Library/Application Support/ScreenClip",
    "keychain": "com.screenclip.app.external-assistant",
    "branch": "screenclip/",
    "reportJson": "report.json",
    "diagnostics": "~/Library/Application Support/ScreenClip/capture-diagnostics.log",
    "appServer": "app-server",
}
UI = {
    "browserUrl": "Read the active browser URL for project matching",
    "checkAccess": "Check screen access",
    "checkAgain": "Check again",
    "reopen": "Reopen app",
}
KBD = "<kbd>Cmd</kbd> <kbd>Shift</kbd> <kbd>2</kbd>"
TOKEN = re.compile(r"\[\[(.*?)\]\]|\{(kbd|code|ui|link)(?::([A-Za-z0-9]+))?\}", re.DOTALL)


AUTHOR_URL = "https://x.com/ludoviclandry"


def page_path(meta, slug):
    prefix = f"/{meta['path']}" if meta["path"] else ""
    if slug in ("", "home"):
        return prefix or "/"
    return f"{prefix}/{slug}" if prefix else f"/{slug}"


def absolute(origin, path):
    if not origin:
        return path
    if path == "/":
        return origin + "/"
    return origin + path


class Catalog:
    def __init__(self, meta, strings):
        self.meta = meta
        self.strings = strings
        self.id = meta["id"]
        self.path = meta["path"]
        self.html_lang = meta["html_lang"]
        self.hreflang = meta["hreflang"]
        self.og = meta["og"]

    def get(self, key):
        node = self.strings
        for part in key.split("."):
            if not isinstance(node, dict) or part not in node:
                raise KeyError(f"{self.id} is missing {key}")
            node = node[part]
        if not isinstance(node, str):
            raise KeyError(f"{self.id} {key} is not a string")
        return node

    def plain(self, key):
        return plain_text(self.get(key))

    def html(self, key, config):
        return format_message(self.get(key), self, config)

    def page(self, slug):
        return page_path(self.meta, slug)


def plain_text(text):
    def replace(match):
        if match.group(1) is not None:
            return match.group(1)
        return ""

    return TOKEN.sub(replace, text)


def format_message(text, catalog, config):
    parts = []
    cursor = 0
    for match in TOKEN.finditer(text):
        parts.append(html.escape(text[cursor : match.start()]))
        if match.group(1) is not None:
            parts.append(f'<span class="accent">{html.escape(match.group(1))}</span>')
        else:
            parts.append(render_token(match.group(2), match.group(3), catalog, config))
        cursor = match.end()
    parts.append(html.escape(text[cursor:]))
    return "".join(parts)


def render_token(kind, name, catalog, config):
    if kind == "kbd":
        return KBD
    if kind == "code":
        if name not in CODES:
            raise KeyError(f"Unknown code token {name}")
        return f"<code>{html.escape(CODES[name])}</code>"
    if kind == "ui":
        if name not in UI:
            raise KeyError(f"Unknown UI token {name}")
        return f"<strong>{html.escape(UI[name])}</strong>"
    if kind == "link":
        return render_link(name, catalog, config)
    raise KeyError(f"Unknown token {kind}")


def render_link(name, catalog, config):
    label = html.escape(catalog.get(f"link.{name}"))
    internal = {
        "privacy": "privacy",
        "privacyLead": "privacy",
        "support": "support",
        "site": "home",
    }
    if name in internal:
        href = catalog.page(internal[name])
        return f'<a href="{html.escape(href, quote=True)}">{label}</a>'
    urls = {
        "githubRead": config.github_url,
        "github": config.github_url,
        "issues": config.issues_url,
        "download": config.download_url,
        "author": AUTHOR_URL,
        "iosGuide": f"{config.github_url}/blob/main/docs/ios-sdk.md" if config.github_url else "",
    }
    if name not in urls:
        raise KeyError(f"Unknown link token {name}")
    url = urls[name]
    if not url:
        return label
    return f'<a href="{html.escape(url, quote=True)}">{label}</a>'


def shape(value):
    if isinstance(value, dict):
        return {key: shape(item) for key, item in value.items()}
    if isinstance(value, list):
        return [shape(item) for item in value]
    return "str" if isinstance(value, str) else type(value).__name__


def load_catalogs():
    catalogs = []
    for meta in LOCALES:
        path = ROOT / "locales" / f"{meta['id']}.json"
        if not path.is_file():
            raise SystemExit(f"Missing locale file {path.name}")
        strings = json.loads(path.read_text())
        catalogs.append(Catalog(meta, strings))
    expected = shape(catalogs[0].strings)
    for catalog in catalogs[1:]:
        actual = shape(catalog.strings)
        if actual != expected:
            raise SystemExit(f"{catalog.id} does not match the en.json key structure")
        if not catalog.get("languageName"):
            raise SystemExit(f"{catalog.id} is missing languageName")
        if "[[" in catalog.strings["hero"]["title"] and catalog.strings["hero"]["title"].count("[[") != catalog.strings["hero"]["title"].count("]]"):
            raise SystemExit(f"{catalog.id} hero.title has a broken accent marker")
    return catalogs


def apply_copy(template, catalog, config):
    def replace(match):
        return catalog.html(match.group(1), config)

    rendered = re.sub(r"\{\{([a-zA-Z0-9_.]+)\}\}", replace, template)
    if "{{" in rendered:
        raise SystemExit(f"Unresolved copy placeholder in {catalog.id}")
    return rendered
