#!/usr/bin/env python3
"""Build the ScreenClipKit DocC documentation into website/sdk for screenclipai.com/sdk.

Vercel cannot run Swift, so the output is committed. Run this after changing the SDK's public API,
its doc comments, or Sources/ScreenClipKit/ScreenClipKit.docc, then rebuild the website.
Needs Xcode 16 or later on a Mac.
"""
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / "build/sdk-docs"
OUTPUT = ROOT / "website/sdk"
BASE = "/sdk/"


def run(*command):
    subprocess.run(command, check=True, cwd=ROOT)


def main():
    if WORK.exists():
        shutil.rmtree(WORK)
    symbols = WORK / "symbols"
    # The real API exists only in Debug builds for iOS, so document exactly that build.
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"], text=True).strip()
    run("swift", "build", "--target", "ScreenClipKit", "--triple", "arm64-apple-ios17.0-simulator", "--sdk", sdk,
        "--scratch-path", str(WORK / "swiftpm"), "-Xswiftc", "-emit-symbol-graph",
        "-Xswiftc", "-emit-symbol-graph-dir", "-Xswiftc", str(symbols))
    kit = WORK / "kit-symbols"
    kit.mkdir()
    shutil.copyfile(symbols / "ScreenClipKit.symbols.json", kit / "ScreenClipKit.symbols.json")
    converted = WORK / "out"
    run("xcrun", "docc", "convert", "Sources/ScreenClipKit/ScreenClipKit.docc", "--additional-symbol-graph-dir", str(kit),
        "--fallback-display-name", "ScreenClipKit", "--fallback-bundle-identifier", "com.mirageteam.screenclip.kit",
        "--output-path", str(converted), "--transform-for-static-hosting", "--hosting-base-path", BASE.strip("/"),
        "--warnings-as-errors")
    for name in ("indexing-records.json", "linkable-entities.json", "assets.json", "metadata.json"):
        (converted / name).unlink(missing_ok=True)
    # The site's Content-Security-Policy allows no inline scripts. DocC's only one sets baseUrl.
    inline = f'<script>var baseUrl = "{BASE.replace("/", chr(92) + "/")}"</script>'
    plain = f'<script>var baseUrl = "{BASE}"</script>'
    (converted / "base-url.js").write_text(f'var baseUrl = "{BASE}";\n')
    pages = 0
    for page in converted.rglob("*.html"):
        text = page.read_text()
        replaced = text.replace(inline, "").replace(plain, "")
        if replaced == text:
            raise SystemExit(f"DocC changed its baseUrl script; update {Path(__file__).name} ({page})")
        replaced = replaced.replace("<head>", f'<head><script src="{BASE}base-url.js"></script>', 1)
        page.write_text(replaced)
        pages += 1
    if OUTPUT.exists():
        shutil.rmtree(OUTPUT)
    shutil.copytree(converted, OUTPUT)
    print(f"Wrote {pages} pages to {OUTPUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
