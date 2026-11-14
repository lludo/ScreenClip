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

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "src"
DIST = ROOT / "dist"

HOME_TITLE = "ScreenClip — Screenshot feedback for AI coding agents"
HOME_DESCRIPTION = (
    "Free Mac menu bar app. Capture a screenshot, hand it to Codex, Claude Code, or Grok Bot, "
    "and track the pull request through checks, merge, and retest."
)
OG_TITLE = "From a screenshot to a pull request"
OG_ALT = "ScreenClip. From a screenshot to a pull request, for Codex, Claude Code, and Grok Bot."


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


def price_copy(config):
    return "ScreenClip is free. There is no subscription."


def action_rows(config):
    rows = []
    if config.download_url:
        rows.append(("primary", config.download_url, "Download for Mac (free)"))
    if config.github_url:
        kind = "secondary" if config.download_url else "primary"
        rows.append((kind, config.github_url, "View on GitHub"))
    if config.donate_url:
        rows.append(("text", config.donate_url, "Support the project"))
    notes = []
    if config.download_url:
        notes.append(
            "Notarized disk image on GitHub Releases. The file is attached when a version tag is published."
        )
    else:
        notes.append("Direct Mac download coming soon.")
    if not config.github_url:
        notes.append("Source coming soon.")
    return rows, notes


def render_actions(config):
    rows, notes = action_rows(config)
    parts = []
    for kind, url, label in rows:
        if kind == "primary":
            parts.append(link(url, label, "button button-primary"))
        elif kind == "secondary":
            parts.append(link(url, label, "button button-secondary"))
        else:
            parts.append(link(url, label, "text-link"))
    for note in notes:
        parts.append(f'<p class="status-note">{esc(note)}</p>')
    if not parts:
        parts.append('<p class="status-note">Mac download coming soon.</p>')
    return '<div class="actions">' + "".join(parts) + "</div>"


def header_cta(config):
    for kind, url, label in action_rows(config)[0]:
        if kind == "primary":
            return link(url, "Download for Mac", "button button-primary button-small")
    return ""


def source_line(config):
    if config.github_url:
        return (
            f'ScreenClip is open source. <a href="{esc(config.github_url)}">Read it on GitHub</a>, '
            "file an issue, or build it with Xcode 16 or later."
        )
    return "The source link is not configured yet."


def issues_html(config):
    if config.issues_url:
        return (
            f'Use <a href="{esc(config.issues_url)}">GitHub issues</a> for bugs, setup questions, and feature requests. '
            "Include the macOS version, the agent you selected, and what ScreenClip showed in the report. "
            "Do not attach an unredacted screenshot of something you meant to hide."
        )
    return "GitHub issues are not linked yet, because githubUrl is empty in site.config.json."


def download_status(config):
    if config.download_url:
        return (
            f'The Mac app is free. <a href="{esc(config.download_url)}">Download for Mac</a> '
            "tracks the latest notarized disk image on GitHub Releases. The file is attached when a version tag is published."
        )
    return "A direct Mac download is not linked yet. This page will point at the release file when it is published."


def source_html(config):
    if config.github_url:
        return f'The source is <a href="{esc(config.github_url)}">on GitHub</a>.'
    return "The source repository is not linked on this page yet."


def github_button(config):
    if not config.github_url:
        return ""
    return link(config.github_url, "View on GitHub", "button button-secondary")


def faq_items(config):
    if config.download_url:
        download_answer = (
            "Yes. Download for Mac on this page links to the latest notarized disk image on GitHub Releases. "
            "The file is attached when a version tag is published."
        )
        if config.github_url:
            download_answer += " You can also build the source from GitHub."
    elif config.github_url:
        download_answer = "Not yet. This page will link the Mac download when a release is published. The source is on GitHub in the meantime."
    else:
        download_answer = "Not yet. This page will link the Mac download when a release is published."
    cost = price_copy(config)
    if config.github_url:
        cost += " The source is on GitHub."
    return [
        (
            "What does ScreenClip do?",
            "ScreenClip is a macOS menu bar app. Press Command-Shift-2, select a region of a website or a Mac app, add a note or markup if you want, and submit. "
            "The report goes to Codex, Claude Code, or Grok Bot. For Codex and Claude Code, ScreenClip runs your project’s validation command and opens the GitHub pull request. "
            "Grok Bot opens the pull request from the branch ScreenClip pushed, and ScreenClip tracks it. "
            "With automatic merge enabled, ScreenClip merges after validation, checks, and review rules pass. Merged reports move to To retest.",
        ),
        (
            "Which coding agents does it support?",
            "Codex, Claude Code, and Grok Bot. Codex and Claude Code run on your Mac, in an isolated Git worktree, and do not push or open the pull request themselves. "
            "Grok Bot is remote: you save a webhook, and each project has to opt in before screenshots are sent. "
            "Choose a default agent in Settings, or pick one for a new report. A follow-up capture stays with that report’s agent.",
        ),
        (
            "Is it only for bugs?",
            "No. Capture a clipped control, confusing copy, awkward spacing, or an idea for later. A screenshot alone is enough.",
        ),
        (
            "What do I need installed?",
            "macOS 14 or later, a local Git repository, and one agent: Codex CLI with app-server, Claude Code, or a Grok Bot webhook. "
            "The GitHub CLI is required to open pull requests, and to send screenshots to Grok Bot. Grant Screen Recording permission for the region you select. "
            "Leave ScreenClip running, and the Mac awake, while Codex or Claude Code works. Grok Bot keeps working if the Mac sleeps, and the pull request status updates the next time ScreenClip is running. "
            "Building from source also needs Xcode 16 or later.",
        ),
        (
            "What leaves my Mac?",
            "ScreenClip does not upload Codex or Claude Code reports. It hands the approved screenshot and note to the agent on your Mac, and that agent may send them to the account you signed into. "
            "GitHub receives the branch and pull request opened with your GitHub CLI. Screenshots are not attached to that pull request by default. "
            "Grok Bot receives approved screenshots only after you save a webhook and turn on sending for that project. There is no ScreenClip analytics. The privacy policy has the full list.",
        ),
        (
            "How does redaction work?",
            "A redaction is a rectangle you draw with the redact tool. ScreenClip flattens it to opaque black. Arrows, pen strokes, shapes, and text do not hide the pixels underneath. "
            "If a capture has a redaction, the unredacted crop is not kept and is not sent.",
        ),
        (
            "Does a fix merge on its own?",
            "Not unless you enable automatic merge for that project. ScreenClip then merges only after its own validation and the pull request’s checks and review rules pass. "
            "It does not bypass required reviews. A merge is not a deploy. You retest from To retest, and a new capture on the same report continues the work.",
        ),
        (
            "Where do agent questions show up?",
            "Codex and Claude Code questions appear on the report, and you reply there. Grok Bot questions stay in Grok Bot’s chat. "
            "Cancel stops the local record. It does not stop a Grok Bot run that has already been sent.",
        ),
        ("What does it cost?", cost),
        ("Can I download it?", download_answer),
        (
            "Does it work on websites and Mac apps?",
            "Yes. Capture a region of a website or a native Mac app. Register a repository and associate it with website addresses or app bundle IDs. "
            "You can change the project before you submit. If the project is ambiguous, ScreenClip saves the report and waits instead of guessing a repository.",
        ),
    ]


def render_faq(config):
    blocks = []
    for question, answer in faq_items(config):
        blocks.append(
            "<details><summary>"
            + esc(question)
            + "</summary><p>"
            + esc(answer)
            + "</p></details>"
        )
    return "\n        ".join(blocks)


def structured_data(config):
    offers = {"@type": "Offer", "price": "0", "priceCurrency": "USD"}
    if config.download_url:
        offers["url"] = config.download_url
    app = {
        "@type": "SoftwareApplication",
        "name": "ScreenClip",
        "applicationCategory": "DeveloperApplication",
        "operatingSystem": "macOS 14 or later",
        "description": HOME_DESCRIPTION,
        "offers": offers,
        "featureList": [
            "Region screenshots with a configurable global shortcut",
            "Optional notes, drawing, arrows, shapes, text, and opaque redaction",
            "Capture from websites and native Mac apps",
            "Codex, Claude Code, and Grok Bot",
            "Project validation, GitHub pull requests, optional merge, and a retest queue",
        ],
        "isAccessibleForFree": True,
    }
    if config.origin:
        app["url"] = config.page_url("")
        app["image"] = f"{config.origin}/assets/og.png"
    if config.github_url:
        app["codeRepository"] = config.github_url
        app["sameAs"] = config.github_url
    if config.download_url:
        app["downloadUrl"] = config.download_url
    faq = {
        "@type": "FAQPage",
        "mainEntity": [
            {
                "@type": "Question",
                "name": question,
                "acceptedAnswer": {"@type": "Answer", "text": answer},
            }
            for question, answer in faq_items(config)
        ],
    }
    payload = {"@context": "https://schema.org", "@graph": [app, faq]}
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":")).replace("<", "\\u003c")


def nav(current):
    def home_link(fragment):
        return f"/#{fragment}" if current != "home" else f"#{fragment}"

    items = [
        (home_link("loop"), "How it works", None, ""),
        (home_link("agents"), "Coding agents", None, ""),
        (home_link("faq"), "Questions", None, ""),
        (home_link("download"), "Download", None, "nav-download"),
    ]
    parts = []
    for href, label, page, class_name in items:
        current_attr = ' aria-current="page"' if page and page == current else ""
        class_attr = f' class="{class_name}"' if class_name else ""
        parts.append(f'<a href="{href}"{class_attr}{current_attr}>{label}</a>')
    return "".join(parts)


def footer_nav(config):
    items = [
        ("/privacy", "Privacy policy"),
        ("/support", "Support"),
        ("/#faq", "Questions"),
    ]
    if config.github_url:
        items.append((config.github_url, "Source on GitHub"))
    return "".join(f'<a href="{esc(href)}">{esc(label)}</a>' for href, label in items)


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


def layout(config, *, title, description, slug, robots, current, body, json_ld, css_href, preloads):
    canonical = ""
    og_url = ""
    if config.origin and slug != "404":
        url = config.page_url("" if slug == "home" else slug)
        canonical = f'<link rel="canonical" href="{esc(url)}">'
        og_url = f'<meta property="og:url" content="{esc(url)}">'
    image = f"{config.origin}/assets/og.png" if config.origin else "/assets/og.png"
    json_tag = f'<script type="application/ld+json">{json_ld}</script>' if json_ld else ""
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{esc(title)}</title>
  <meta name="description" content="{esc(description)}">
  <meta name="robots" content="{esc(robots)}">
  <meta name="theme-color" content="#f6f3ec" media="(prefers-color-scheme: light)">
  <meta name="theme-color" content="#161411" media="(prefers-color-scheme: dark)">
  <meta property="og:type" content="website">
  <meta property="og:locale" content="en_US">
  <meta property="og:site_name" content="ScreenClip">
  <meta property="og:title" content="{esc(OG_TITLE if slug == "home" else title)}">
  <meta property="og:description" content="{esc(description)}">
  <meta property="og:image" content="{esc(image)}">
  <meta property="og:image:width" content="1200">
  <meta property="og:image:height" content="630">
  <meta property="og:image:type" content="image/png">
  <meta property="og:image:alt" content="{esc(OG_ALT)}">
  <meta name="twitter:card" content="summary_large_image">
  <meta name="twitter:title" content="{esc(OG_TITLE if slug == "home" else title)}">
  <meta name="twitter:description" content="{esc(description)}">
  <meta name="twitter:image" content="{esc(image)}">
  <meta name="twitter:image:alt" content="{esc(OG_ALT)}">
  {canonical}
  {og_url}
  <link rel="icon" href="/favicon.ico" sizes="32x32">
  <link rel="icon" href="/assets/icon.svg" type="image/svg+xml">
  <link rel="icon" href="/assets/favicon-32.png" type="image/png" sizes="32x32">
  <link rel="apple-touch-icon" href="/assets/apple-touch-icon.png">
  <link rel="manifest" href="/manifest.webmanifest">
  {render_preloads(preloads)}
  <link rel="stylesheet" href="{esc(css_href)}">
  {json_tag}
</head>
<body>
  <a class="skip-link" href="#main">Skip to content</a>
  <header class="site-header">
    <div class="wrap header-bar">
      <a class="brand" href="/"><img src="/assets/icon.svg" width="32" height="32" alt=""><span>ScreenClip</span></a>
      <nav aria-label="Primary">{nav(current)}</nav>
      <div class="header-cta">{header_cta(config)}</div>
    </div>
  </header>
  <main id="main">
    {body}
  </main>
  <footer class="site-footer">
    <div class="wrap footer-bar">
      <a class="brand" href="/"><img src="/assets/icon.svg" width="28" height="28" alt=""><span>ScreenClip</span></a>
      <nav class="footer-nav" aria-label="Footer">{footer_nav(config)}</nav>
      <p class="copyright">© {datetime.now().year} ScreenClip</p>
    </div>
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
        if "<html lang=\"en\">" not in page:
            raise SystemExit(f"{path.name} is missing lang")
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
    if '"price":"0"' not in text:
        raise SystemExit("JSON-LD is missing the free offer")
    if '"@type":"FAQPage"' not in text or '"@type":"SoftwareApplication"' not in text:
        raise SystemExit("JSON-LD is missing SoftwareApplication or FAQPage")
    if '"operatingSystem":"macOS 14 or later"' not in text:
        raise SystemExit("JSON-LD operatingSystem must name macOS")
    if config.download_url and '"downloadUrl":' not in text:
        raise SystemExit("JSON-LD is missing downloadUrl")
    home = (DIST / "index.html").read_text()
    lcp = re.search(r"<img[^>]*fetchpriority=\"high\"[^>]*>", home)
    if not lcp or "loading=" in lcp.group(0) or 'alt=""' in lcp.group(0):
        raise SystemExit("The menu bar image must be eager, sized, and described")
    if 'width="' not in lcp.group(0) or 'height="' not in lcp.group(0):
        raise SystemExit("The menu bar image needs explicit width and height")
    if "image/avif" not in home or "image/webp" not in home or "prefers-color-scheme: dark" not in home:
        raise SystemExit("The menu bar picture is missing a dark or modern source")
    for href in re.findall(r'(?:href|src|srcset)="([^"]+)"', text):
        if href.startswith(("https://", "http://", "mailto:")):
            continue
        check_local_ref(href, pages)
    og = (DIST / "assets" / "og.png").read_bytes()
    if og[16:24] != struct.pack(">II", 1200, 630):
        raise SystemExit("og.png must be 1200 by 630")


def check_local_ref(url, pages):
    path, _, fragment = url.partition("#")
    if path in ("", "/"):
        target = "home"
        file_path = DIST / "index.html"
    else:
        rel = path.lstrip("/")
        file_path = DIST / rel
        html_path = DIST / f"{rel}.html"
        if file_path.is_file():
            target = None
        elif html_path.is_file():
            file_path = html_path
            target = rel
        else:
            raise SystemExit(f"Missing local target for {url}")
    if fragment:
        haystack = (DIST / "index.html").read_text() if target == "home" or path in ("", "/") else file_path.read_text()
        if f'id="{fragment}"' not in haystack:
            raise SystemExit(f"Missing fragment #{fragment} for {url}")


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
    popup_width, popup_height = png_size(SRC / "assets" / "popup-light.png")
    popup = {
        "POPUP_LIGHT_AVIF": fingerprinted(SRC / "assets" / "popup-light.avif", hashed),
        "POPUP_LIGHT_WEBP": fingerprinted(SRC / "assets" / "popup-light.webp", hashed),
        "POPUP_LIGHT_PNG": fingerprinted(SRC / "assets" / "popup-light.png", hashed),
        "POPUP_DARK_AVIF": fingerprinted(SRC / "assets" / "popup-dark.avif", hashed),
        "POPUP_DARK_WEBP": fingerprinted(SRC / "assets" / "popup-dark.webp", hashed),
        "POPUP_DARK_PNG": fingerprinted(SRC / "assets" / "popup-dark.png", hashed),
        "POPUP_W": str(popup_width),
        "POPUP_H": str(popup_height),
    }
    home_preloads = [
        (popup["POPUP_LIGHT_AVIF"], "(prefers-color-scheme: light)", "image/avif"),
        (popup["POPUP_DARK_AVIF"], "(prefers-color-scheme: dark)", "image/avif"),
    ]
    print("Drawing icons…")
    write_icons(assets)

    tokens = {
        "ACTIONS": render_actions(config),
        "PRICE": esc(price_copy(config)),
        "FAQ": render_faq(config),
        "SOURCE_LINE": source_line(config),
        "ISSUES_HTML": issues_html(config),
        "DOWNLOAD_STATUS": download_status(config),
        "SOURCE_HTML": source_html(config),
        "GITHUB_BUTTON": github_button(config),
        **popup,
    }
    privacy_description = (
        "What ScreenClip stores on your Mac, what can be sent to Codex, Claude Code, Grok Bot, or GitHub, "
        "and how redaction works."
    )
    pages = [
        ("home", "index.html", HOME_TITLE, HOME_DESCRIPTION, "index, follow, max-image-preview:large", True),
        ("privacy", "privacy.html", "Privacy policy — ScreenClip", privacy_description, "index, follow", False),
        ("support", "support.html", "Support — ScreenClip", "Get ScreenClip help through GitHub issues, plus what you need to run or build the Mac app.", "index, follow", False),
        ("404", "404.html", "Page not found — ScreenClip", "That page is not on the ScreenClip site.", "noindex", False),
    ]
    written = {}
    hashes = []
    for slug, filename, title, description, robots, with_json in pages:
        body = (SRC / "pages" / ("home.html" if slug == "home" else f"{slug}.html")).read_text()
        for key, value in tokens.items():
            body = body.replace(f"@@{key}@@", value)
        json_ld = structured_data(config) if with_json else ""
        document = layout(
            config,
            title=title,
            description=description,
            slug=slug,
            robots=robots,
            current=slug,
            body=body,
            json_ld=json_ld,
            css_href=css_href,
            preloads=home_preloads if slug == "home" else [],
        )
        (DIST / filename).write_text(document)
        written[slug] = document
        hashes.extend(csp_hashes(document))
    if config.origin:
        locs = [config.page_url(slug) for slug in ("", "privacy", "support")]
        body = "".join(f"<url><loc>{esc(loc)}</loc></url>" for loc in locs)
        (DIST / "sitemap.xml").write_text(
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'
            + body
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
    if "0.99" in price_copy(empty) or "App Store" in price_copy(empty):
        raise SystemExit("Pricing copy must stay free of the App Store")
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
