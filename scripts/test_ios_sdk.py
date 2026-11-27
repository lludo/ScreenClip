#!/usr/bin/env python3
"""Test the SDK inside its demo host and check the built Debug and Release products."""
import json
import os
from pathlib import Path
import plistlib
import subprocess


ROOT = Path(__file__).resolve().parents[1]
DERIVED = ROOT / "build/ScreenClipKitDemo"
NAME = "ScreenClipKitDemo"


def simulator_id():
    if device := os.environ.get("SCREENCLIP_IOS_SIMULATOR_ID"):
        return device
    devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))["devices"]
    phones = [d for runtime, group in devices.items() if ".iOS-" in runtime
              and int(runtime.split(".iOS-")[1].split("-")[0]) >= 17
              for d in group if "iPhone" in d.get("deviceTypeIdentifier", "")
              # The UI tests tap fixed positions in the system photo picker, which sit elsewhere
              # on a foldable iPhone's screens.
              and "Duo" not in d.get("deviceTypeIdentifier", "")]
    if not phones:
        raise SystemExit("Install an iOS 17 or later iPhone simulator runtime in Xcode.")
    return next((d for d in phones if d["state"] == "Booted"), phones[-1])["udid"]


def check_product(configuration, sdk):
    app = DERIVED / f"Build/Products/{configuration}-{sdk}/{NAME}.app"
    info = plistlib.loads((app / "Info.plist").read_bytes())
    debug = configuration == "Debug"
    if debug:
        if "_screenclip._tcp" not in info.get("NSBonjourServices", []) or not info.get("NSLocalNetworkUsageDescription"):
            raise SystemExit("Debug demo is missing its local network declarations.")
    elif "NSBonjourServices" in info or "NSLocalNetworkUsageDescription" in info:
        raise SystemExit("Release demo contains Debug network declarations.")
    binaries = [app / info["CFBundleExecutable"], *app.glob("*.dylib")]
    symbols = b"".join(subprocess.check_output(["xcrun", "nm", "-j", path]) for path in binaries)
    for marker in (b"ShakeHook", b"MacLink", b"KitRuntime", b"AttachmentProviders", b"LinkConnection"):
        if (marker in symbols) != debug:
            raise SystemExit(f"Unexpected {marker.decode()} symbols in the {configuration} demo.")
    if not debug and any(b"_screenclip._tcp" in binary.read_bytes() for binary in binaries):
        raise SystemExit("Release demo contains the SDK Bonjour service.")


def main():
    device = simulator_id()
    # The report sheet's picker shows only screenshots. This PNG carries the EXIF comment Photos
    # uses to file it there, so the UI test has one to pick. Adding it again only adds a duplicate.
    subprocess.run(["xcrun", "simctl", "bootstatus", device, "-b"], check=True)
    subprocess.run(["xcrun", "simctl", "addmedia", device,
                    str(ROOT / f"Examples/{NAME}/Fixtures/picker-screenshot.png")], check=True)
    build = ["xcodebuild", "-project", str(ROOT / f"Examples/{NAME}/{NAME}.xcodeproj"),
             "-scheme", NAME, "-derivedDataPath", str(DERIVED)]
    subprocess.run([*build, "-configuration", "Debug", "-destination", f"platform=iOS Simulator,id={device}",
                    "-parallel-testing-enabled", "NO", "test"], check=True)
    check_product("Debug", "iphonesimulator")
    subprocess.run([*build, "-configuration", "Release", "-destination", "generic/platform=iOS",
                    "CODE_SIGNING_ALLOWED=NO", "build"], check=True)
    check_product("Release", "iphoneos")
    print("iOS SDK tests and Debug/Release product checks passed.")


if __name__ == "__main__":
    main()
