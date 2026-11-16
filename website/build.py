#!/usr/bin/env python3
"""Build ScreenClip's static site. Python standard library only."""

import argparse
import base64
import hashlib
import html
import json
import re
import shutil
import struct
import zlib
from dataclasses import dataclass
from datetime import datetime
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

import i18n

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "src"
DIST = ROOT / "dist"

@dataclass(frozen=True)
class Config:
    site_url: str
    github_url: str
    download_url: str
    donate_url: str

    @property
    def origin(self):
        return self.site_url.rstrip("/")

    def page_url(self, slug):
        if not self.origin:
            return ""
        return f"{self.origin}/" if not slug else f"{self.origin}/{slug}"

    @property
    def issues_url(self):
        if not self.github_url:
            return ""
        return self.github_url.rstrip("/") + "/issues"


def configured_url(raw, key):
    value = str(raw or "").strip()
    if not value:
        return ""
    parsed = urlsplit(value)
    if parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password:
        raise ValueError(f"{key} must be an absolute HTTPS URL, or empty")
    if key == "siteUrl" and (parsed.query or parsed.fragment):
        raise ValueError("siteUrl cannot contain a query or fragment")
    return value


def load_config():
    data = json.loads((ROOT / "site.config.json").read_text())
    return Config(
        site_url=configured_url(data.get("siteUrl", ""), "siteUrl"),
        github_url=configured_url(data.get("githubUrl", ""), "githubUrl"),
        download_url=configured_url(data.get("downloadUrl", ""), "downloadUrl"),
        donate_url=configured_url(data.get("donateUrl", ""), "donateUrl"),
    )


def esc(value):
    return html.escape(value, quote=True)


def link(url, label, class_name):
    return f'<a class="{class_name}" href="{esc(url)}">{esc(label)}</a>'


def catalog_or_english(catalog):
    return catalog if catalog is not None else i18n.load_catalogs()[0]


def render_actions(config, catalog=None, *, hero=False):
    catalog = catalog_or_english(catalog)
    download = catalog.strings["download"]
    rows = []
    if config.download_url:
        rows.append(("primary", config.download_url, download["button"]))
    if config.github_url:
        kind = "secondary" if config.download_url else "primary"
        rows.append((kind, config.github_url, download["github"]))
    if config.donate_url:
        rows.append(("text", config.donate_url, download["donate"]))
    notes = []
    if config.download_url:
        notes.append(download["noteReady"])
    else:
        notes.append(download["noteSoon"])
    parts = []
    if hero and not config.download_url and not config.github_url:
        parts.append(link(catalog.page("home") + "#loop", catalog.get("nav.how"), "button button-primary"))
    for kind, url, label in rows:
        class_name = {"primary": "button button-primary", "secondary": "button button-secondary"}[kind] if kind != "text" else "text-link"
        parts.append(link(url, label, class_name))
    for note in notes:
        parts.append(f'<p class="status-note">{esc(note)}</p>')
    if not parts:
        parts.append(f'<p class="status-note">{esc(download["macSoon"])}</p>')
    return '<div class="actions">' + "".join(parts) + "</div>"


def hero_title(catalog, config):
    """The headline breaks after its first comma, in whichever script the language uses."""
    title = catalog.html("hero.title", config)
    for comma in (", ", "、", "，"):
        if comma in title:
            return title.replace(comma, comma.rstrip() + "<br>", 1)
    return title


def header_cta(config, catalog):
    return link(catalog.page("home") + "#download", catalog.get("nav.download"), "button button-primary button-small")


def source_line(config, catalog):
    if config.github_url:
        return catalog.html("download.source", config)
    return catalog.html("download.sourceMissing", config)


def issues_html(config, catalog):
    key = "support.issues" if config.issues_url else "support.issuesMissing"
    return catalog.html(key, config)


def download_status(config, catalog):
    key = "support.statusReady" if config.download_url else "support.statusSoon"
    return catalog.html(key, config)


def source_html(config, catalog):
    key = "support.buildSource" if config.github_url else "support.buildMissing"
    result = catalog.html(key, config)
    return result + " " + catalog.html("support.build", config) if config.github_url else result


def github_button(config, catalog):
    if not config.github_url:
        return ""
    return link(config.github_url, catalog.get("download.github"), "button button-secondary")


def faq_items(config, catalog=None):
    catalog = catalog_or_english(catalog)
    faq = catalog.strings["faq"]
    items = []
    for item in faq["items"]:
        if item.get("id") == "cost":
            answer = faq["cost"] + (faq["costSource"] if config.github_url else "")
        elif item.get("id") == "download":
            if config.download_url:
                answer = faq["downloadYes"] + (faq["downloadSource"] if config.github_url else "")
            else:
                answer = faq["downloadNo"] + (faq["downloadNoSource"] if config.github_url else "")
        else:
            answer = item["a"]
        items.append((item["q"], answer))
    return items


def render_faq(config, catalog):
    blocks = []
    for question, answer in faq_items(config, catalog):
        blocks.append(
            "<details><summary>"
            + esc(question)
            + "</summary><p>"
            + esc(answer)
            + "</p></details>"
        )
    return "\n        ".join(blocks)


def structured_data(config, catalog=None):
    catalog = catalog_or_english(catalog)
    offers = {"@type": "Offer", "price": "0", "priceCurrency": "USD"}
    if config.download_url:
        offers["url"] = config.download_url
    app = {
        "@type": "SoftwareApplication",
        "name": "ScreenClip",
        "applicationCategory": "DeveloperApplication",
        "operatingSystem": catalog.get("schema.os"),
        "inLanguage": catalog.html_lang,
        "description": catalog.plain("meta.homeDescription"),
        "featureList": list(catalog.strings["schema"]["features"]),
    }
    page = i18n.absolute(config.origin, catalog.page("home"))
    if config.origin:
        app["url"] = page
        app["image"] = f"{config.origin}/assets/og.png"
    if config.github_url:
        app["codeRepository"] = config.github_url
        app["sameAs"] = config.github_url
    if config.download_url:
        app["offers"] = offers
        app["isAccessibleForFree"] = True
        app["downloadUrl"] = config.download_url
        app["softwareVersion"] = "1.0.0"
    faq = {
        "@type": "FAQPage",
        "inLanguage": catalog.html_lang,
        "mainEntity": [
            {
                "@type": "Question",
                "name": question,
                "acceptedAnswer": {"@type": "Answer", "text": answer},
            }
            for question, answer in faq_items(config, catalog)
        ],
    }
    payload = {"@context": "https://schema.org", "@graph": [app, faq]}
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":")).replace("<", "\\u003c")


def fragment_href(catalog, slug, fragment):
    if slug == "home":
        return f"#{fragment}"
    return f"{catalog.page('home')}#{fragment}"


def nav(catalog, slug):
    items = [
        (fragment_href(catalog, slug, "loop"), catalog.get("nav.how"), ""),
        (fragment_href(catalog, slug, "agents"), catalog.get("nav.agents"), ""),
        (fragment_href(catalog, slug, "faq"), catalog.get("nav.questions"), ""),
    ]
    parts = []
    for href, label, class_name in items:
        class_attr = f' class="{class_name}"' if class_name else ""
        parts.append(f'<a href="{esc(href)}"{class_attr}>{esc(label)}</a>')
    return "".join(parts)


def footer_nav(config, catalog, slug):
    items = [
        (catalog.page("privacy"), catalog.get("nav.privacy"), slug == "privacy"),
        (catalog.page("support"), catalog.get("nav.support"), slug == "support"),
        (fragment_href(catalog, slug, "faq"), catalog.get("nav.questions"), False),
    ]
    if config.github_url:
        items.append((config.github_url, catalog.get("nav.source"), False))
    parts = []
    for href, label, current in items:
        current_attr = ' aria-current="page"' if current else ""
        parts.append(f'<a href="{esc(href)}"{current_attr}>{esc(label)}</a>')
    return "".join(parts)


def language_switcher(catalogs, catalog, slug):
    target = "home" if slug == "404" else slug
    parts = []
    for other in catalogs:
        current_attr = ' aria-current="true"' if other.id == catalog.id else ""
        parts.append(
            f'<a href="{esc(other.page(target))}" lang="{esc(other.html_lang)}" hreflang="{esc(other.hreflang)}" data-locale="{esc(other.path or "en")}"{current_attr}>{esc(other.get("languageName"))}</a>'
        )
    return (
        f'<nav class="lang-switcher wrap" aria-label="{esc(catalog.get("nav.languages"))}" data-lang-switcher>'
        + "".join(parts)
        + "</nav>"
    )


def hreflang_tags(config, catalogs, slug):
    tags = []
    for other in catalogs:
        href = i18n.absolute(config.origin, other.page(slug))
        tags.append(f'<link rel="alternate" hreflang="{esc(other.hreflang)}" href="{esc(href)}">')
    default_href = i18n.absolute(config.origin, catalogs[0].page(slug))
    tags.append(f'<link rel="alternate" hreflang="x-default" href="{esc(default_href)}">')
    return "\n  ".join(tags)


def render_preloads(preloads):
    tags = []
    for href, media, mime in preloads:
        attrs = f'rel="preload" as="image" href="{esc(href)}"'
        if mime:
            attrs += f' type="{esc(mime)}"'
        if media:
            attrs += f' media="{esc(media)}"'
        tags.append(f"<link {attrs}>")
    return "\n  ".join(tags)


def layout(config, catalogs, catalog, *, slug, robots, body, json_ld, css_href, js_href, preloads):
    title = catalog.plain("meta.notFoundTitle" if slug == "404" else {
        "home": "meta.homeTitle",
        "privacy": "meta.privacyTitle",
        "support": "meta.supportTitle",
    }[slug])
    description = catalog.plain({
        "home": "meta.homeDescription",
        "privacy": "meta.privacyDescription",
        "support": "meta.supportDescription",
        "404": "meta.notFoundDescription",
    }[slug])
    og_title = catalog.plain("hero.title") if slug == "home" else title
    canonical = ""
    og_url = ""
    alternates = ""
    if slug != "404":
        url = i18n.absolute(config.origin, catalog.page(slug))
        canonical = f'<link rel="canonical" href="{esc(url)}">'
        og_url = f'<meta property="og:url" content="{esc(url)}">'
        alternates = hreflang_tags(config, catalogs, slug)
    alternate_locales = "\n  ".join(
        f'<meta property="og:locale:alternate" content="{esc(other.og)}">'
        for other in catalogs
        if other.id != catalog.id and slug != "404"
    )
    image = f"{config.origin}/assets/og.png" if config.origin else "/assets/og.png"
    json_tag = f'<script type="application/ld+json">{json_ld}</script>' if json_ld else ""
    home = catalog.page("home")
    return f"""<!doctype html>
<html lang="{esc(catalog.html_lang)}">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{esc(title)}</title>
  <meta name="description" content="{esc(description)}">
  <meta name="robots" content="{esc(robots)}">
  <meta name="theme-color" content="#f6f3ec" media="(prefers-color-scheme: light)">
  <meta name="theme-color" content="#161411" media="(prefers-color-scheme: dark)">
  <meta property="og:type" content="website">
  <meta property="og:locale" content="{esc(catalog.og)}">
  {alternate_locales}
  <meta property="og:site_name" content="ScreenClip">
  <meta property="og:title" content="{esc(og_title)}">
  <meta property="og:description" content="{esc(description)}">
  <meta property="og:image" content="{esc(image)}">
  <meta property="og:image:width" content="1200">
  <meta property="og:image:height" content="630">
  <meta property="og:image:type" content="image/png">
  <meta property="og:image:alt" content="{esc(catalog.plain("meta.ogAlt"))}">
  <meta name="twitter:card" content="summary_large_image">
  <meta name="twitter:title" content="{esc(og_title)}">
  <meta name="twitter:description" content="{esc(description)}">
  <meta name="twitter:image" content="{esc(image)}">
  <meta name="twitter:image:alt" content="{esc(catalog.plain("meta.ogAlt"))}">
  {canonical}
  {og_url}
  {alternates}
  <link rel="icon" href="/favicon.ico" sizes="32x32">
  <link rel="icon" href="/assets/icon.svg" type="image/svg+xml">
  <link rel="icon" href="/assets/favicon-32.png" type="image/png" sizes="32x32">
  <link rel="apple-touch-icon" href="/assets/apple-touch-icon.png">
  <link rel="manifest" href="/manifest.webmanifest">
  {render_preloads(preloads)}
  <link rel="stylesheet" href="{esc(css_href)}">
  {json_tag}
  <script type="module" src="{esc(js_href)}"></script>
</head>
<body>
  <a class="skip-link" href="#main">{esc(catalog.get("nav.skip"))}</a>
  <header class="site-header">
    <div class="wrap header-bar">
      <a class="brand" href="{esc(home)}"><img src="/assets/icon.svg" width="32" height="32" alt=""><span>ScreenClip</span></a>
      <nav aria-label="{esc(catalog.get("nav.primary"))}">{nav(catalog, slug)}</nav>
      <div class="header-cta">{header_cta(config, catalog)}</div>
    </div>
  </header>
  <main id="main">
    {body}
  </main>
  <footer class="site-footer">
    <div class="wrap footer-bar">
      <a class="brand" href="{esc(home)}"><img src="/assets/icon.svg" width="28" height="28" alt=""><span>ScreenClip</span></a>
      <nav class="footer-nav" aria-label="{esc(catalog.get("nav.footer"))}">{footer_nav(config, catalog, slug)}</nav>
      <p class="copyright">© {datetime.now().year} ScreenClip</p>
    </div>
    {language_switcher(catalogs, catalog, slug)}
  </footer>
</body>
</html>
"""


def sha256_file(path):
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    return digest[:12]


def png_size(path):
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"{path.name} is not a PNG")
    return struct.unpack(">II", data[16:24])


def fingerprinted(path, dest_dir):
    digest = sha256_file(path)
    name = f"{path.stem}.{digest}{path.suffix}"
    target = dest_dir / name
    shutil.copyfile(path, target)
    return f"/assets/h/{name}"


def write_png(path, width, height, rgba):
    if len(rgba) != width * height * 4:
        raise ValueError("PNG buffer has the wrong size")

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    raw = b"".join(b"\x00" + rgba[y * width * 4 : (y + 1) * width * 4] for y in range(height))
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    path.write_bytes(
        b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    )


def dist_to_segment(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    length = dx * dx + dy * dy
    if length == 0:
        return ((px - ax) ** 2 + (py - ay) ** 2) ** 0.5
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / length))
    qx, qy = ax + t * dx, ay + t * dy
    return ((px - qx) ** 2 + (py - qy) ** 2) ** 0.5


def icon_rgba(size):
    samples = 2
    orange = (247, 104, 38)
    out = bytearray(size * size * 4)
    radius = size * 0.24
    half = size / 2
    stroke = size * 0.055 / 2
    arm = size * 0.115
    corners = []
    anchors = []
    for x, y, dx, dy in ((0.27, 0.27, 1, 1), (0.73, 0.27, -1, 1), (0.27, 0.73, 1, -1), (0.73, 0.73, -1, -1)):
        cx, cy = x * size, y * size
        anchors.append((cx, cy))
        corners.append((cx + dx * arm, cy, cx, cy))
        corners.append((cx, cy, cx, cy + dy * arm))
    dot = size * 0.048
    near = arm + stroke + 1.5
    for y in range(size):
        for x in range(size):
            cover_orange = 0
            cover_white = 0
            near_mark = abs(x + 0.5 - half) <= dot + 1.5 and abs(y + 0.5 - half) <= dot + 1.5
            if not near_mark:
                near_mark = any(abs(x + 0.5 - ax) <= near and abs(y + 0.5 - ay) <= near for ax, ay in anchors)
            for sy in range(samples):
                for sx in range(samples):
                    fx = x + (sx + 0.5) / samples
                    fy = y + (sy + 0.5) / samples
                    qx = abs(fx - half) - (half - radius)
                    qy = abs(fy - half) - (half - radius)
                    outside = (max(qx, 0) ** 2 + max(qy, 0) ** 2) ** 0.5
                    inside = min(max(qx, qy), 0)
                    if outside + inside - radius > 0:
                        continue
                    white = False
                    if near_mark:
                        white = (fx - half) ** 2 + (fy - half) ** 2 <= dot * dot
                        if not white:
                            white = any(dist_to_segment(fx, fy, *seg) <= stroke for seg in corners)
                    if white:
                        cover_white += 1
                    else:
                        cover_orange += 1
            total = cover_white + cover_orange
            if not total:
                continue
            mix = cover_white / total
            offset = (y * size + x) * 4
            out[offset] = int(255 * mix + orange[0] * (1 - mix))
            out[offset + 1] = int(255 * mix + orange[1] * (1 - mix))
            out[offset + 2] = int(255 * mix + orange[2] * (1 - mix))
            out[offset + 3] = int(round(255 * total / (samples * samples)))
    return bytes(out)


def write_ico(path, png_bytes):
    header = struct.pack("<HHH", 0, 1, 1)
    entry = struct.pack("<BBBBHHII", 32, 32, 0, 0, 1, 32, len(png_bytes), 6 + 16)
    path.write_bytes(header + entry + png_bytes)


def write_icons(assets):
    sizes = {
        32: assets / "favicon-32.png",
        180: assets / "apple-touch-icon.png",
        192: assets / "icon-192.png",
        512: assets / "icon-512.png",
    }
    png32 = None
    for size, path in sizes.items():
        rgba = icon_rgba(size)
        write_png(path, size, size, rgba)
        if size == 32:
            png32 = path.read_bytes()
    write_ico(DIST / "favicon.ico", png32)


def manifest(config):
    description = "Screenshot feedback for AI coding agents on Mac."
    data = {
        "name": "ScreenClip",
        "short_name": "ScreenClip",
        "description": description,
        "start_url": "/",
        "display": "browser",
        "background_color": "#f6f3ec",
        "theme_color": "#f6f3ec",
        "icons": [
            {"src": "/assets/icon-192.png", "sizes": "192x192", "type": "image/png"},
            {"src": "/assets/icon-512.png", "sizes": "512x512", "type": "image/png"},
        ],
    }
    if config.origin:
        data["id"] = config.origin + "/"
    return json.dumps(data, indent=2) + "\n"


def csp_hashes(html_text):
    hashes = []
    for body in re.findall(r'<script type="application/ld\+json">(.*?)</script>', html_text):
        digest = base64.b64encode(hashlib.sha256(body.encode("utf-8")).digest()).decode("ascii")
        hashes.append(f"'sha256-{digest}'")
    return hashes


def security_headers(hashes, upgrade=True):
    script = " ".join(["'self'", *hashes])
    csp = (
        "default-src 'self'; "
        f"script-src {script}; "
        "style-src 'self'; "
        "img-src 'self'; "
        "font-src 'self'; "
        "connect-src 'self'; "
        "object-src 'none'; "
        "base-uri 'self'; "
        "form-action 'none'; "
        "frame-ancestors 'none'"
    )
    if upgrade:
        csp += "; upgrade-insecure-requests"
    return [
        ("Content-Security-Policy", csp),
        ("X-Content-Type-Options", "nosniff"),
        ("Referrer-Policy", "strict-origin-when-cross-origin"),
        ("Permissions-Policy", "camera=(), microphone=(), geolocation=(), payment=()"),
        ("Strict-Transport-Security", "max-age=63072000; includeSubDomains; preload"),
    ]


def check_vercel_csp(hashes):
    config = json.loads((ROOT / "vercel.json").read_text())
    expected = dict(security_headers(hashes))
    found = {}
    for block in config.get("headers", []):
        if block.get("source") != "/(.*)":
            continue
        for header in block.get("headers", []):
            found[header.get("key")] = header.get("value")
    if found != expected:
        raise SystemExit(
            "vercel.json security headers do not match the build.\n"
            f"Expected: {json.dumps(expected, indent=2)}\n"
            f"Found: {json.dumps(found, indent=2)}"
        )


def check_output(config, pages):
    text = "\n".join(path.read_text() for path in DIST.rglob("*.html"))
    if re.search(r"@@[A-Z0-9_]+@@", text):
        raise SystemExit("Unresolved template token in HTML")
    for path in DIST.rglob("*.html"):
        page = path.read_text()
        if page.count("<h1") != 1:
            raise SystemExit(f"{path.name} should have exactly one h1")
        if not re.search(r'<html lang="[a-zA-Z-]+">', page):
            raise SystemExit(f"{path} is missing lang")
        if 'rel="alternate" hreflang="x-default"' not in page and "noindex" not in page:
            raise SystemExit(f"{path} is missing hreflang")
    joined = text + (DIST / "sitemap.xml").read_text() + (DIST / "manifest.webmanifest").read_text()
    if "0.99" in joined or "App Store" in text:
        raise SystemExit("App Store copy leaked into the site")
    if config.download_url:
        if "Download for Mac (free)" not in text:
            raise SystemExit("downloadUrl is set, but the download label is missing")
    elif "Download for Mac (free)" in text:
        raise SystemExit("Download label rendered without downloadUrl")
    if config.donate_url:
        if "Support the project" not in text:
            raise SystemExit("donateUrl is set, but the support link is missing")
    elif "Support the project" in text:
        raise SystemExit("Donate link rendered without donateUrl")
    if config.download_url and '"price":"0"' not in text:
        raise SystemExit("JSON-LD is missing the free offer")
    if '"@type":"FAQPage"' not in text or '"@type":"SoftwareApplication"' not in text:
        raise SystemExit("JSON-LD is missing SoftwareApplication or FAQPage")
    if '"operatingSystem":"macOS 14 or later"' not in text or '"inLanguage":' not in text:
        raise SystemExit("JSON-LD must name macOS and inLanguage")
    if config.download_url and '"downloadUrl":' not in text:
        raise SystemExit("JSON-LD is missing downloadUrl")
    home = (DIST / "index.html").read_text()
    lcp = re.search(r"<img[^>]*fetchpriority=\"high\"[^>]*>", home)
    if not lcp or "loading=" in lcp.group(0) or 'alt=""' in lcp.group(0):
        raise SystemExit("The menu bar image must be eager, sized, and described")
    if 'width="' not in lcp.group(0) or 'height="' not in lcp.group(0):
        raise SystemExit("The menu bar image needs explicit width and height")
    if "image/png" not in home or "prefers-color-scheme: dark" not in home:
        raise SystemExit("The menu bar picture is missing its dark source")
    for href in re.findall(r'(?:href|src|srcset)="([^"]+)"', text):
        if href.startswith(("https://", "http://", "mailto:")):
            continue
        check_local_ref(href, pages)
    og = (DIST / "assets" / "og.png").read_bytes()
    if og[16:24] != struct.pack(">II", 1200, 630):
        raise SystemExit("og.png must be 1200 by 630")


def resolve_output(url):
    path, _, fragment = url.partition("#")
    if path in ("", "/"):
        file_path = DIST / "index.html"
    else:
        rel = path.lstrip("/")
        file_path = DIST / rel
        html_path = DIST / f"{rel}.html"
        index_path = DIST / rel / "index.html"
        if file_path.is_dir():
            file_path = index_path
        elif not file_path.is_file() and html_path.is_file():
            file_path = html_path
        elif not file_path.is_file() and index_path.is_file():
            file_path = index_path
        if not file_path.is_file():
            raise SystemExit(f"Missing local target for {url}")
    if fragment and f'id="{fragment}"' not in file_path.read_text():
        raise SystemExit(f"Missing fragment #{fragment} for {url}")
    return file_path


def check_local_ref(url, pages):
    resolve_output(url)


def build():
    config = load_config()
    self_test()
    if DIST.is_symlink():
        raise SystemExit("Refusing to replace a symlink at dist")
    if DIST.exists():
        shutil.rmtree(DIST)
    assets = DIST / "assets"
    hashed = assets / "h"
    assets.mkdir(parents=True)
    hashed.mkdir()
    shutil.copyfile(SRC / "assets" / "icon.svg", assets / "icon.svg")
    shutil.copyfile(SRC / "assets" / "og.png", assets / "og.png")
    css_href = fingerprinted(SRC / "styles.css", hashed)
    queue_image = fingerprinted(SRC / "assets" / "report-queue-example.png", hashed)
    notification_image = fingerprinted(SRC / "assets" / "retest-notifications.png", hashed)
    print("Drawing icons…")
    write_icons(assets)

    match_source = (ROOT / "locale-match.js").read_text()
    match_href = fingerprinted(ROOT / "locale-match.js", hashed)
    locale_script = (SRC / "locale.js").read_text().replace("/assets/locale-match.js", match_href)
    locale_path = hashed / "locale.js"
    locale_path.write_text(locale_script)
    js_href = fingerprinted(locale_path, hashed)
    locale_path.unlink()
    if "export function matchTags" not in match_source:
        raise SystemExit("locale-match.js is missing matchTags")
    catalogs = i18n.load_catalogs()
    page_specs = [
        ("home", "index.html", "index, follow, max-image-preview:large", True),
        ("privacy", "privacy.html", "index, follow", False),
        ("support", "support.html", "index, follow", False),
        ("404", "404.html", "noindex", False),
    ]
    written = {}
    hashes = []
    for catalog in catalogs:
        popup_dir = SRC / "assets" / "localized-menu"
        light = popup_dir / f"{catalog.id}-light.png"
        dark = popup_dir / f"{catalog.id}-dark.png"
        popup_width, popup_height = png_size(light)
        if png_size(dark) != (popup_width, popup_height):
            raise SystemExit(f"Mismatched menu image sizes for {catalog.id}")
        popup = {
            "POPUP_LIGHT_PNG": fingerprinted(light, hashed),
            "POPUP_DARK_PNG": fingerprinted(dark, hashed),
            "POPUP_W": str(popup_width),
            "POPUP_H": str(popup_height),
        }
        home_preloads = [
            (popup["POPUP_LIGHT_PNG"], "(prefers-color-scheme: light)", "image/png"),
            (popup["POPUP_DARK_PNG"], "(prefers-color-scheme: dark)", "image/png"),
        ]
        tokens = {
            "QUEUE_PNG": queue_image,
            "NOTIFICATION_PNG": notification_image,
            "HERO_TITLE": hero_title(catalog, config),
            "DOWNLOAD_TITLE": catalog.html("download.title" if config.download_url else "download.titleSoon", config),
            "ACTIONS": render_actions(config, catalog, hero=True),
            "DOWNLOAD_ACTIONS": render_actions(config, catalog) if (config.download_url or config.github_url or config.donate_url) else "",
            "FAQ": render_faq(config, catalog),
            "SOURCE_LINE": source_line(config, catalog),
            "ISSUES_HTML": issues_html(config, catalog),
            "DOWNLOAD_STATUS": download_status(config, catalog),
            "SOURCE_HTML": source_html(config, catalog),
            "GITHUB_BUTTON": github_button(config, catalog),
            "HOME_PATH": catalog.page("home"),
            "SUPPORT_PATH": catalog.page("support"),
            "PRIVACY_PATH": catalog.page("privacy"),
            **popup,
        }
        for slug, filename, robots, with_json in page_specs:
            body = (SRC / "pages" / ("home.html" if slug == "home" else f"{slug}.html")).read_text()
            body = i18n.apply_copy(body, catalog, config)
            for key, value in tokens.items():
                body = body.replace(f"@@{key}@@", value)
            json_ld = structured_data(config, catalog) if with_json else ""
            document = layout(
                config,
                catalogs,
                catalog,
                slug=slug,
                robots=robots,
                body=body,
                json_ld=json_ld,
                css_href=css_href,
                js_href=js_href,
                preloads=home_preloads if slug == "home" else [],
            )
            if catalog.path:
                destination = DIST / catalog.path / filename
                destination.parent.mkdir(parents=True, exist_ok=True)
            else:
                destination = DIST / filename
            destination.write_text(document)
            written[f"{catalog.path or 'en'}:{slug}"] = document
            hashes.extend(csp_hashes(document))
    if config.origin:
        blocks = []
        for slug in ("home", "privacy", "support"):
            for catalog in catalogs:
                loc = i18n.absolute(config.origin, catalog.page(slug))
                alternates = []
                for other in catalogs:
                    href = i18n.absolute(config.origin, other.page(slug))
                    alternates.append(
                        f'<xhtml:link rel="alternate" hreflang="{esc(other.hreflang)}" href="{esc(href)}"/>'
                    )
                default_href = i18n.absolute(config.origin, catalogs[0].page(slug))
                alternates.append(
                    f'<xhtml:link rel="alternate" hreflang="x-default" href="{esc(default_href)}"/>'
                )
                blocks.append(f"<url><loc>{esc(loc)}</loc>{''.join(alternates)}</url>")
        (DIST / "sitemap.xml").write_text(
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" '
            'xmlns:xhtml="http://www.w3.org/1999/xhtml">'
            + "".join(blocks)
            + "</urlset>\n"
        )
        (DIST / "robots.txt").write_text(
            "User-agent: *\nAllow: /\n\nSitemap: " + config.origin + "/sitemap.xml\n"
        )
    else:
        (DIST / "robots.txt").write_text("User-agent: *\nAllow: /\n")
    (DIST / "manifest.webmanifest").write_text(manifest(config))
    check_output(config, written)
    check_vercel_csp(hashes)
    print(f"Built {DIST}")
    return hashes


def self_test():
    def contrast(front, back):
        def channel(hex_color):
            value = int(hex_color, 16) / 255
            return value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4

        def luminance(color):
            red, green, blue = color[1:3], color[3:5], color[5:7]
            return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)

        lighter, darker = sorted((luminance(front), luminance(back)), reverse=True)
        return (lighter + 0.05) / (darker + 0.05)

    pairs = [
        ("#241f1a", "#f6f3ec", 7),
        ("#5c564e", "#f6f3ec", 4.5),
        ("#b8430a", "#f6f3ec", 4.5),
        ("#1a120c", "#f76826", 4.5),
        ("#1a120c", "#ff7a3c", 4.5),
        ("#5c564e", "#fffdf8", 4.5),
        ("#b8430a", "#fffdf8", 4.5),
        ("#f4efe6", "#161411", 7),
        ("#c8bfb2", "#221e1a", 4.5),
        ("#ffb088", "#221e1a", 4.5),
        ("#f4efe6", "#221e1a", 7),
        ("#c8bfb2", "#161411", 4.5),
        ("#ffb088", "#161411", 4.5),
        ("#f6f1e8", "#2a211c", 7),
        ("#d9cfc2", "#2a211c", 4.5),
        ("#ffb088", "#2a211c", 4.5),
    ]
    for front, back, minimum in pairs:
        ratio = contrast(front, back)
        if ratio < minimum:
            raise SystemExit(f"Contrast {front} on {back} is {ratio:.2f}, below {minimum}")

    empty = Config("", "", "", "")
    free = Config("", "", "https://example.com/ScreenClip.dmg", "")
    tipped = Config("", "https://example.com/repo", free.download_url, "https://example.com/donate")
    price = i18n.load_catalogs()[0].get("download.price")
    if "0.99" in price or "App Store" in price:
        raise SystemExit("Pricing copy must stay free of the App Store")
    empty_actions = render_actions(empty, hero=True)
    if 'href="/#loop"' not in empty_actions or "Mac download coming soon." not in empty_actions:
        raise SystemExit("Unreleased site needs a useful action and clear availability")
    unavailable = json.loads(structured_data(empty).replace("\\u003c", "<"))["@graph"][0]
    if "offers" in unavailable or "downloadUrl" in unavailable:
        raise SystemExit("Unreleased site must not advertise a download offer")
    free_actions = render_actions(free)
    if "Download for Mac (free)" not in free_actions:
        raise SystemExit("Download label missing")
    if "Support the project" in render_actions(free):
        raise SystemExit("Donate link rendered while empty")
    if "Support the project" not in render_actions(tipped):
        raise SystemExit("Donate link missing")
    if "App Store" in free_actions or "App Store" in render_actions(empty):
        raise SystemExit("App Store button rendered")
    offer = json.loads(structured_data(free).replace("\\u003c", "<"))
    if offer["@graph"][0]["offers"]["price"] != "0":
        raise SystemExit("Direct download should publish a free offer")


class PreviewHandler(SimpleHTTPRequestHandler):
    extensions_map = {
        **getattr(SimpleHTTPRequestHandler, "extensions_map", {}),
        ".webmanifest": "application/manifest+json",
        ".svg": "image/svg+xml",
        ".ico": "image/x-icon",
        ".avif": "image/avif",
        ".webp": "image/webp",
    }

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(DIST), **kwargs)

    def end_headers(self):
        # Local preview is http. upgrade-insecure-requests would break its assets.
        for key, value in security_headers(getattr(self.server, "csp_hashes", []), upgrade=False):
            self.send_header(key, value)
        path = urlsplit(self.path).path
        if path.startswith("/assets/h/"):
            self.send_header("Cache-Control", "public, max-age=31536000, immutable")
        else:
            self.send_header("Cache-Control", "public, max-age=0, must-revalidate")
        super().end_headers()

    def _route(self):
        parsed = urlsplit(self.path)
        path, query = parsed.path, parsed.query
        suffix = f"?{query}" if query else ""
        if path != "/" and path.endswith("/"):
            self.send_response(308)
            self.send_header("Location", (path.rstrip("/") or "/") + suffix)
            self.end_headers()
            return False
        if path.endswith(".html"):
            self.send_response(308)
            self.send_header("Location", (path[: -len(".html")] or "/") + suffix)
            self.end_headers()
            return False
        relative = path.lstrip("/")
        file_path = DIST / "index.html" if relative == "" else DIST / relative
        if relative and file_path.is_dir():
            file_path = file_path / "index.html"
        if relative and not file_path.is_file():
            html_path = DIST / f"{relative}.html"
            if html_path.is_file():
                file_path = html_path
        if not file_path.is_file():
            error = (DIST / "404.html").read_bytes()
            self.send_response(404)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(error)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(error)
            return False
        self.path = "/" + file_path.relative_to(DIST).as_posix() + suffix
        return True

    def do_GET(self):
        if self._route():
            super().do_GET()

    def do_HEAD(self):
        if self._route():
            super().do_HEAD()

    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args))


def serve(port, hashes):
    server = ThreadingHTTPServer(("127.0.0.1", port), PreviewHandler)
    server.csp_hashes = hashes
    print(f"Serving {DIST} at http://127.0.0.1:{port}")
    server.serve_forever()


def main(argv=None):
    parser = argparse.ArgumentParser(description="Build the ScreenClip website")
    parser.add_argument("--preview", nargs="?", const=4173, type=int, help="Build, then serve dist on 127.0.0.1")
    args = parser.parse_args(argv)
    hashes = build()
    if args.preview is not None:
        serve(args.preview, hashes)


if __name__ == "__main__":
    main()
