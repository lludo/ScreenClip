#!/usr/bin/env python3
"""Build ScreenClip's static landing page. Python standard library only."""

import html
import json
import re
import shutil
from datetime import datetime
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent


def configured_url(config, key):
    value = config.get(key, "").strip()
    if not value:
        return ""
    parsed = urlsplit(value)
    if parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password:
        raise ValueError(f"{key} must be an absolute HTTPS URL, or empty for a placeholder")
    if key == "siteUrl" and (parsed.query or parsed.fragment):
        raise ValueError("siteUrl cannot contain a query or fragment")
    return value


def download_option(url, icon, eyebrow, title, status=None):
    tag = "a" if url else "div"
    attributes = f'href="{html.escape(url, quote=True)}"' if url else 'aria-disabled="true"'
    if status is None:
        status = "Get it" if url else "Coming soon"
    return (
        f'<{tag} class="download-button" {attributes}>'
        f'<svg class="icon" aria-hidden="true"><use href="#{icon}"/></svg>'
        f'<span><small>{eyebrow}</small><strong>{title}</strong></span>'
        f'<span class="availability">{status}</span></{tag}>'
    )


def download_options(app_store_url, download_url):
    options = []
    if app_store_url:
        options.append(download_option(app_store_url, "apple", "For your Mac", "Mac App Store"))
    if download_url:
        options.append(
            download_option(
                download_url, "icon-download", "Notarized DMG", "Download for Mac", "Latest release"))
    else:
        options.append(
            download_option("", "icon-download", "Notarized DMG", "Download for Mac"))
    return options


def release_note(app_store_url, download_url):
    if download_url and not app_store_url:
        return "Download for Mac tracks the latest notarized DMG on GitHub Releases."
    if download_url or app_store_url:
        return "Choose an available download above."
    return "Public downloads aren’t available yet. Check back here for release links."


def availability_answer(app_store_url, download_url):
    if download_url and not app_store_url:
        return (
            "Use Download for Mac. It links to the latest GitHub Release of the notarized DMG. "
            "The file is there after a version tag is published."
        )
    if download_url or app_store_url:
        return "Use an available download link above to get ScreenClip for Mac. An option marked ‘Coming soon’ is not available yet."
    return "Not yet. Public downloads are being prepared. Download for Mac will track the latest GitHub Release."


def main():
    config = json.loads((ROOT / "site.config.json").read_text())
    site_url = configured_url(config, "siteUrl").rstrip("/")
    app_store_url = configured_url(config, "appStoreUrl")
    download_url = configured_url(config, "downloadUrl")
    base = f"{site_url}/" if site_url else ""
    available = bool(app_store_url or download_url)
    app = {
        "@context": "https://schema.org",
        "@type": "SoftwareApplication",
        "name": "ScreenClip",
        "applicationCategory": "DeveloperApplication",
        "operatingSystem": "macOS 14 or later",
        "description": "Capture feedback as you notice it without breaking your flow. Save screenshots, optional notes, and context, then keep going.",
        "featureList": [
            "Global shortcut for region screenshots",
            "Optional quick notes, annotations, and redaction",
            "Capture feedback from websites and native Mac apps",
            "Keep related captures and context together",
            "Codex integration and follow-up progress",
        ],
    }
    url_metadata = ""
    if site_url:
        app.update({"url": base, "image": f"{base}assets/social-preview.png"})
        escaped_base = html.escape(base, quote=True)
        url_metadata = f'<link rel="canonical" href="{escaped_base}">\n  <meta property="og:url" content="{escaped_base}">'
    if download_url:
        app["downloadUrl"] = download_url
    if app_store_url:
        app["installUrl"] = app_store_url
    replacements = {
        "SOCIAL_IMAGE": html.escape(f"{base}assets/social-preview.png", quote=True),
        "URL_METADATA": url_metadata,
        "STRUCTURED_DATA": json.dumps(app, ensure_ascii=False).replace("<", "\\u003c"),
        "DOWNLOAD_OPTIONS": "\n        ".join(download_options(app_store_url, download_url)),
        "DOWNLOAD_INTRO": "Get ScreenClip for Mac." if available else "ScreenClip for Mac is on its way.",
        "RELEASE_NOTE": release_note(app_store_url, download_url),
        "AVAILABILITY_ANSWER": availability_answer(app_store_url, download_url),
        "YEAR": str(datetime.now().year),
    }
    document = (ROOT / "src/index.html").read_text()
    for key, value in replacements.items():
        document = document.replace(f"@@{key}@@", value)
    if re.search(r"@@[A-Z_]+@@", document):
        raise ValueError("Unresolved template values in page")
    output = ROOT / "dist"
    if output.is_symlink():
        raise ValueError("Refusing to replace a symlink at dist")
    if output.exists():
        shutil.rmtree(output)
    shutil.copytree(ROOT / "src", output)
    (output / "index.html").write_text(document)
    robots = "User-agent: *\nAllow: /\n"
    if site_url:
        robots += f"\nSitemap: {base}sitemap.xml\n"
        (output / "sitemap.xml").write_text(
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'
            f'<url><loc>{html.escape(base)}</loc></url></urlset>\n'
        )
    (output / "robots.txt").write_text(robots)
    print(f"Built {output}")
    print("Download links: " + ("configured" if available else "coming-soon placeholders"))
    print("Canonical URL and sitemap: " + (base if site_url else "add siteUrl before public launch"))


if __name__ == "__main__":
    main()
