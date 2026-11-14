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


def download_option(url, icon, eyebrow, title):
    tag = "a" if url else "div"
    attributes = f'href="{html.escape(url, quote=True)}"' if url else 'aria-disabled="true"'
    status = "Get it" if url else "Coming soon"
    return (
        f'<{tag} class="download-button" {attributes}>'
        f'<svg class="icon" aria-hidden="true"><use href="#{icon}"/></svg>'
        f'<span><small>{eyebrow}</small><strong>{title}</strong></span>'
        f'<span class="availability">{status}</span></{tag}>'
    )


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
        "DOWNLOAD_OPTIONS": "\n        ".join([
            download_option(app_store_url, "apple", "For your Mac", "Mac App Store"),
            download_option(download_url, "icon-download", "Direct from ScreenClip", "Download for Mac"),
        ]),
        "DOWNLOAD_INTRO": "Get ScreenClip for Mac." if available else "ScreenClip for Mac is on its way.",
        "RELEASE_NOTE": "Choose an available download above." if available else "Public downloads aren’t available yet. Check back here for release links.",
        "AVAILABILITY_ANSWER": "Use an available download link above to get ScreenClip for Mac. An option marked ‘Coming soon’ is not available yet." if available else "Not yet. ScreenClip is in development and public downloads are being prepared. The App Store and direct-download options above are placeholders until release links are available.",
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
