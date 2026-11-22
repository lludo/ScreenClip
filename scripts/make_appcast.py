#!/usr/bin/env python3
"""Write the Sparkle appcast for one release.

Usage: make_appcast.py APP DMG SIGNATURE OUTPUT

APP is the released ScreenClip.app (for its version and build number), DMG the final stapled disk
image, SIGNATURE the EdDSA signature `sign_update -p` printed for that DMG. The feed has one item:
Sparkle only needs the newest release. The app reads it from
https://github.com/lludo/ScreenClip/releases/latest/download/appcast.xml.
"""
import email.utils
import os
import pathlib
import plistlib
import sys
from xml.sax.saxutils import escape, quoteattr

REPO = "https://github.com/lludo/ScreenClip"
ROOT = pathlib.Path(__file__).resolve().parents[1]


def release_notes(version: str) -> str:
    """The release notes file without its title and install section, as Markdown for Sparkle."""
    path = ROOT / "docs" / "release" / f"v{version}.md"
    if not path.exists():
        return f"[Release notes]({REPO}/releases/tag/v{version})"
    kept = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("# "):
            continue
        if line.startswith("## Install"):
            break
        kept.append(line)
    return "\n".join(kept).strip().replace("]]>", "]]]]><![CDATA[>")


def main() -> int:
    if len(sys.argv) != 5:
        print(__doc__, file=sys.stderr)
        return 2
    app, dmg, signature, output = sys.argv[1:]
    info = plistlib.loads((pathlib.Path(app) / "Contents" / "Info.plist").read_bytes())
    version = info["CFBundleShortVersionString"]
    build = info["CFBundleVersion"]
    minimum = info.get("LSMinimumSystemVersion", "14.0")
    url = f"{REPO}/releases/download/v{version}/ScreenClip.dmg"
    length = os.path.getsize(dmg)
    feed = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>ScreenClip</title>
    <link>{REPO}</link>
    <item>
      <title>{escape(version)}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{escape(build)}</sparkle:version>
      <sparkle:shortVersionString>{escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{escape(minimum)}</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>{REPO}/releases/tag/v{escape(version)}</sparkle:fullReleaseNotesLink>
      <description sparkle:format="markdown"><![CDATA[{release_notes(version)}]]></description>
      <enclosure url={quoteattr(url)} length="{length}" type="application/octet-stream" sparkle:edSignature={quoteattr(signature.strip())}/>
    </item>
  </channel>
</rss>
"""
    pathlib.Path(output).write_text(feed, encoding="utf-8")
    print(f"Wrote {output} for {version} ({build})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
