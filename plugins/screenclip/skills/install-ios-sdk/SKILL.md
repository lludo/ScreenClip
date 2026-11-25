---
name: install-ios-sdk
description: Install ScreenClipKit, the ScreenClip in-app reporting SDK, into an iOS app for Debug builds only. Use when the user asks to add ScreenClip, ScreenClipKit, shake-to-report, or in-app bug reporting to an iOS project, or pastes the ScreenClip agent prompt.
---

# Install ScreenClipKit in an iOS app

ScreenClipKit lets a tester shake the device (or take a screenshot), annotate the app's screen, add a note, and send it to ScreenClip on their Mac, where it becomes a report for a coding agent. Reports are saved on the device until the Mac is reachable.

The goal is a Debug-only install: one Swift package product, one guarded `start()` call, and two Info.plist keys present only in Debug. Release builds must not contain the SDK's capture or network code or its Info.plist keys. The package itself already compiles to an empty stub outside Debug, so the guards below are a second layer.

Work in the user's iOS project. Do not change unrelated settings, signing, or targets. Show the user the diff at the end.

## 1. Inspect the project

1. Find how the project is defined, in this order:
   - `project.yml` (XcodeGen) or `Project.swift` (Tuist): edit the manifest, then regenerate. Never hand-edit the generated `.xcodeproj`.
   - A `.xcodeproj` (possibly inside a `.xcworkspace`): edit `project.pbxproj` as described below.
   - A `Package.swift` app (Swift Playgrounds style): add the dependency there.
2. Pick the app target. If there are several iOS application targets, ask the user which ones should get ScreenClipKit (usually the main app, not extensions, widgets, or test targets; extensions are not supported).
3. Find the entry point: a SwiftUI `@main struct …: App`, or a `UIApplicationDelegate` with `application(_:didFinishLaunchingWithOptions:)`.
4. Check the deployment target. ScreenClipKit needs iOS 17 or later. If the app targets an older iOS, stop and tell the user.
5. Note whether the target uses a generated Info.plist (`GENERATE_INFOPLIST_FILE = YES`) and whether `INFOPLIST_FILE` is set, per configuration.

## 2. Add the package

Package URL: `https://github.com/lludo/ScreenClip`, product `ScreenClipKit`.

Choose the version: run `git ls-remote --tags https://github.com/lludo/ScreenClip` and use the newest `vX.Y.Z` tag whose repository contains `Sources/ScreenClipKit` (check with `git ls-remote` plus a shallow clone, or the GitHub API). Use `upToNextMajorVersion` from that version. If no tag has it yet, use `branch = main` and tell the user to pin a version once one is released.

### Xcode project (`project.pbxproj`)

Generate fresh object IDs: 24 uppercase hex characters each, not already present in the file (`grep` to confirm). Use one ID per placeholder below.

1. In the `PBXProject` object, add to `packageReferences = ( … );` (create the list if missing):
   ```
   <PKG> /* XCRemoteSwiftPackageReference "ScreenClip" */,
   ```
2. Add the reference object (create the section if missing, sections are sorted alphabetically by isa):
   ```
   /* Begin XCRemoteSwiftPackageReference section */
   		<PKG> /* XCRemoteSwiftPackageReference "ScreenClip" */ = {
   			isa = XCRemoteSwiftPackageReference;
   			repositoryURL = "https://github.com/lludo/ScreenClip";
   			requirement = {
   				kind = upToNextMajorVersion;
   				minimumVersion = <X.Y.Z>;
   			};
   		};
   /* End XCRemoteSwiftPackageReference section */
   ```
   For a branch: `requirement = { branch = main; kind = branch; };`
3. Add the product dependency:
   ```
   /* Begin XCSwiftPackageProductDependency section */
   		<PROD> /* ScreenClipKit */ = {
   			isa = XCSwiftPackageProductDependency;
   			package = <PKG> /* XCRemoteSwiftPackageReference "ScreenClip" */;
   			productName = ScreenClipKit;
   		};
   /* End XCSwiftPackageProductDependency section */
   ```
4. In the app's `PBXNativeTarget`, add `<PROD> /* ScreenClipKit */,` to `packageProductDependencies = ( … );`.
5. Add a build file and put it in that target's `PBXFrameworksBuildPhase` `files` list:
   ```
   		<BUILD> /* ScreenClipKit in Frameworks */ = {isa = PBXBuildFile; productRef = <PROD> /* ScreenClipKit */; };
   ```
6. Validate: `plutil -lint <project>.xcodeproj/project.pbxproj` must pass, then `xcodebuild -resolvePackageDependencies -project <project>.xcodeproj` (or `-workspace … -scheme …`) must resolve `ScreenClip`.

A working example lives in the ScreenClip repository at `Examples/ScreenClipKitDemo/ScreenClipKitDemo.xcodeproj/project.pbxproj` (it uses a local package reference instead of the remote one).

### XcodeGen

```yaml
packages:
  ScreenClip:
    url: https://github.com/lludo/ScreenClip
    from: X.Y.Z
targets:
  YourApp:
    dependencies:
      - package: ScreenClip
        product: ScreenClipKit
```
Then run `xcodegen generate`.

### Tuist

Add `.remote(url: "https://github.com/lludo/ScreenClip", requirement: .upToNextMajor(from: "X.Y.Z"))` to the packages, and `.package(product: "ScreenClipKit")` to the app target's dependencies. Then run `tuist install` and `tuist generate`.

### Package.swift app

Add `.package(url: "https://github.com/lludo/ScreenClip", from: "X.Y.Z")` and `.product(name: "ScreenClipKit", package: "ScreenClip")` to the app target.

## 3. Start the SDK

Add the guarded import at the top of the entry-point file, and the guarded start call, exactly once.

SwiftUI:
```swift
#if DEBUG
import ScreenClipKit
#endif

@main
struct MyApp: App {
  init() {
    #if DEBUG
    ScreenClipKit.start()
    #endif
  }
  // existing body unchanged
}
```
If the `App` already has an `init()`, add the `#if DEBUG` block at its start.

UIKit app delegate: put the same `#if DEBUG ScreenClipKit.start() #endif` block at the top of `application(_:didFinishLaunchingWithOptions:)`.

Triggers: by default both shake and "offer after a system screenshot" are on. If the app already uses shake (search for `motionEnded`, `motionShake`, `onShake`, FLEX, or another debug menu), use `ScreenClipKit.start(triggers: [.screenshot])` and tell the user they can call `ScreenClipKit.capture()` from their own debug menu. ScreenClipKit chains to existing shake handling and never consumes the event, so leaving shake on is also safe; the only cost is two sheets wanting the same gesture.

Diagnostics: reports include recent app logs, the screen's view tree, and device state by default (testers can untick them per report). If the app logs mostly with `print`, use `ScreenClipKit.start(ScreenClipOptions(captureConsoleOutput: true))` to also attach the last printed lines; mention this to the user rather than turning it on silently, because it redirects stdout and stderr through a pipe (output still reaches Xcode's console).

If the project uses a custom compilation condition instead of `DEBUG` for internal builds (check `SWIFT_ACTIVE_COMPILATION_CONDITIONS`), keep `DEBUG`; ScreenClipKit itself only activates under `DEBUG`.

## 4. Debug-only Info.plist keys

The SDK finds the Mac with Bonjour, which needs these keys in **Debug only**:

- `NSBonjourServices` = `["_screenclip._tcp"]`
- `NSLocalNetworkUsageDescription` = `ScreenClip sends the reports you capture in this debug build to ScreenClip on your Mac.`

Pick the case that matches the target, per configuration:

- **Generated Info.plist and no `INFOPLIST_FILE` in Debug** (most new projects): create `ScreenClip-Debug-Info.plist` next to the project (outside any synchronized source folder, or excluded from the target's membership so it is not copied as a resource) with only those two keys, and set `INFOPLIST_FILE = "<relative path>/ScreenClip-Debug-Info.plist";` in the app target's **Debug** build configuration only. Xcode merges it with the generated keys. Example: `Examples/ScreenClipKitDemo/Config/ScreenClip-Debug-Info.plist` in the ScreenClip repository.
- **A file-based Info.plist shared by all configurations**: do not add the keys to it. Add a Run Script build phase to the app target, after "Copy Bundle Resources", named "ScreenClip Debug Info.plist keys":
  ```sh
  [ "${CONFIGURATION}" = "Debug" ] || exit 0
  PLIST="${TARGET_BUILD_DIR}/${INFOPLIST_PATH}"
  /usr/libexec/PlistBuddy -c "Delete :NSBonjourServices" "$PLIST" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :NSBonjourServices array" -c "Add :NSBonjourServices:0 string _screenclip._tcp" "$PLIST"
  /usr/libexec/PlistBuddy -c "Add :NSLocalNetworkUsageDescription string 'ScreenClip sends the reports you capture in this debug build to ScreenClip on your Mac.'" "$PLIST" 2>/dev/null || true
  ```
  Set `inputPaths`/`outputPaths` empty and `alwaysOutOfDate = 1`; if `ENABLE_USER_SCRIPT_SANDBOXING = YES`, add `$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)` to both input and output files.
- **Already has `NSBonjourServices` or `NSLocalNetworkUsageDescription`** (the app uses the local network itself): add `_screenclip._tcp` to the existing array for Debug only using the script above (append instead of delete), and keep the app's own description.

If the keys are missing, the SDK still saves reports on the device and logs a console message naming the missing keys.

## 5. Verify

1. `xcodebuild -resolvePackageDependencies …` resolves ScreenClip.
2. Build Debug for a simulator: `xcodebuild -scheme <Scheme> -configuration Debug -destination 'generic/platform=iOS Simulator' build`. It must succeed.
3. Check the Debug Info.plist: `plutil -p <DerivedData>/…/Debug-iphonesimulator/<App>.app/Info.plist | grep -E "Bonjour|_screenclip|LocalNetwork"` shows both keys.
4. Build Release: `xcodebuild -scheme <Scheme> -configuration Release -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`. Then confirm nothing shipped:
   - `plutil -p …/Release-iphonesimulator/<App>.app/Info.plist | grep -cE "Bonjour|LocalNetwork"` prints the same count as before the change (0 unless the app already had them).
   - `strings …/Release-iphonesimulator/<App>.app/<App> | grep -c _screenclip._tcp` prints 0.
   - `nm …/<App> | grep -cE "MacLink|ShakeHook|LinkConnection"` prints 0. Only an empty `ScreenClipKit` stub may remain.
5. If a simulator is available, run the Debug app and confirm the console shows `ScreenClipKit started`.

Fix anything that fails before reporting success. Do not claim a check you did not run.

## 6. Tell the user how to use it

- On the Mac: open ScreenClip > Settings > iOS, turn on **Receive reports from iOS devices**, and click **Pair a device…**.
- On the device: run the Debug build, shake (or take a screenshot), tap the gear in the report sheet, tap **Pair** next to the Mac, and confirm the same 6-digit code on the Mac.
- After that, shake, annotate, add a note, and tap **Send**. If the Mac is not reachable the report is saved and sent automatically later; **Fetch** on the Mac asks connected devices to send saved reports, and saved reports can also be exported and AirDropped to the Mac.
- iPhone and Mac must be on the same network. iOS asks once for Local Network access.
- Reports are routed to a ScreenClip project by the app's bundle ID. If the project is already in ScreenClip, the first report usually routes itself: ScreenClip finds the bundle ID in the repository's Xcode project. Otherwise the user picks the project once and ScreenClip remembers it.
