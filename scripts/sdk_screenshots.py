#!/usr/bin/env python3
"""Capture the ScreenClipKit demo screenshots used by the website and the SDK documentation.

Runs WebsiteScreenshotTests in the demo's UI test target on an iPhone simulator, in light mode
with a clean status bar, and copies its screenshots to:
  website/src/assets/ios/<name>.png (750 pixels wide)
  Sources/ScreenClipKit/ScreenClipKit.docc/Resources/<name>@3x.png (full size)
Set SCREENCLIP_IOS_SIMULATOR_ID to choose the simulator.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_ios_sdk import ROOT, NAME, simulator_id  # noqa: E402

NAMES = ("composer",)
DESTINATIONS = (ROOT / "website/src/assets/ios", ROOT / "Sources/ScreenClipKit/ScreenClipKit.docc/Resources")


def main():
    device = simulator_id()
    subprocess.run(["xcrun", "simctl", "bootstatus", device, "-b"], check=True)
    subprocess.run(["xcrun", "simctl", "ui", device, "appearance", "light"], check=True)
    subprocess.run(["xcrun", "simctl", "status_bar", device, "override", "--time", "9:41", "--batteryState", "charged",
                    "--batteryLevel", "100", "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4",
                    "--operatorName", ""], check=True)
    with tempfile.TemporaryDirectory() as temp:
        result = Path(temp) / "screenshots.xcresult"
        exported = Path(temp) / "exported"
        try:
            subprocess.run(
                ["xcodebuild", "-project", str(ROOT / f"Examples/{NAME}/{NAME}.xcodeproj"), "-scheme", NAME,
                 "-derivedDataPath", str(ROOT / "build/ScreenClipKitDemo"), "-configuration", "Debug",
                 "-destination", f"platform=iOS Simulator,id={device}", "-resultBundlePath", str(result),
                 "-only-testing:ScreenClipKitDemoUITests/WebsiteScreenshotTests", "test"],
                check=True, env={**os.environ, "TEST_RUNNER_SCREENCLIP_SCREENSHOTS": "1"})
        finally:
            subprocess.run(["xcrun", "simctl", "status_bar", device, "clear"], capture_output=True)
        subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(result),
                        "--output-path", str(exported)], check=True)
        files = {}
        for test in json.loads((exported / "manifest.json").read_text()):
            for attachment in test.get("attachments", []):
                name = attachment.get("suggestedHumanReadableName", "").split("_")[0]
                if name in NAMES:
                    files[name] = exported / attachment["exportedFileName"]
        missing = [name for name in NAMES if name not in files]
        if missing:
            raise SystemExit(f"Missing screenshots: {', '.join(missing)}")
        website, docc = DESTINATIONS
        for name, source in files.items():
            shutil.copyfile(source, website / f"{name}.png")
            shutil.copyfile(source, docc / f"{name}@3x.png")
        # The website shows the phone at about 375 points wide; 2x is plenty.
        for name in NAMES:
            subprocess.run(["sips", "--resampleWidth", "750", str(DESTINATIONS[0] / f"{name}.png")],
                           check=True, capture_output=True)
    print("Saved " + ", ".join(f"{name}.png" for name in NAMES))


if __name__ == "__main__":
    main()
