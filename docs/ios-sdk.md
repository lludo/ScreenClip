# ScreenClip for iOS (ScreenClipKit)

> The public overview is [screenclipai.com/ios](https://screenclipai.com/ios), and the API reference is [screenclipai.com/sdk](https://screenclipai.com/sdk/documentation/screenclipkit). The reference is generated from `Sources/ScreenClipKit/ScreenClipKit.docc` and the SDK's doc comments; see [Website](website.md#ios-page-and-sdk-documentation). This page is the maintainer's reference.

ScreenClip captures anything on a Mac screen, but it cannot see a physical iPhone. ScreenClipKit is a small Swift package you add to the **Debug** build of your own iOS app. A tester shakes the device (or takes a screenshot), annotates the app's screen, adds a note, and taps **Send**. The report goes straight into ScreenClip on the Mac. If the Mac is not reachable, the report is saved on the device and sent later.

## Install

The fastest way is to let your coding agent do it. In ScreenClip, open **Settings > iOS** and click **Copy agent prompt**, then paste it into Claude Code or Codex in your iOS project. The agent follows the [install skill](../plugins/screenclip/skills/install-ios-sdk/SKILL.md). The skill also ships in the ScreenClip plugin.

By hand:

1. Add the package `https://github.com/lludo/ScreenClip` and link the product **ScreenClipKit** to your app target. It needs iOS 17 or later and a Swift 6 toolchain (Xcode 16 or newer). Select a version whose tag includes the SDK, or use the `main` branch until such a tag is published. On the Mac, use a ScreenClip build that includes **Settings > iOS**.
2. Start it once:
   ```swift
   #if DEBUG
   import ScreenClipKit
   #endif

   // In your App init, or application(_:didFinishLaunchingWithOptions:)
   #if DEBUG
   ScreenClipKit.start()
   #endif
   ```
3. Add two keys to the **Debug** Info.plist only: `NSBonjourServices` = `["_screenclip._tcp"]` and `NSLocalNetworkUsageDescription`. With a generated Info.plist, put them in a small `ScreenClip-Debug-Info.plist` and set `INFOPLIST_FILE` for the Debug configuration only. Xcode merges it with the generated keys. With a file-based plist, point Debug at a complete Debug variant and preserve the host’s existing Bonjour services and usage description. [`Examples/ScreenClipKitDemo`](../Examples/ScreenClipKitDemo) is a complete project set up this way.

### Nothing ships in Release

There are two layers. Your `#if DEBUG` guards keep the call out, and the package compiles to an empty stub outside Debug, so even an unguarded call does nothing. In a Release build of the demo app, `nm` finds no capture, pairing, or network symbols, `strings` finds no `_screenclip._tcp`, and the Info.plist has no Bonjour or Local Network keys. The public API remains available as a no-op for callers that link it. Run `python3 scripts/test_ios_sdk.py` in this repository to verify both built products.

## Use

1. On the Mac, open **Settings > iOS**, turn on **Receive reports from iOS devices**, and click **Pair a device…**.
2. On the device, run the Debug build and shake. Tap the gear in the report sheet, then tap **Pair** next to your Mac. Confirm that both screens show the same 6-digit code, then click **Confirm** on the Mac.
3. From then on: shake, draw (arrow, rectangle, ellipse, pen, text, redact), write a note, and tap **Send**. The report gets the iPhone icon in the queue.

### Which project gets the report

1. A project whose **App bundle IDs** list the app's bundle ID.
2. Otherwise, the one project whose source declares that bundle ID. ScreenClip reads `PRODUCT_BUNDLE_IDENTIFIER` in every target and configuration of each Xcode project, plus `.xcconfig` files, Info.plists, XcodeGen `project.yml`, Tuist `Project.swift`, and `Package.swift` app products. It resolves build-setting variables from the same settings or any xcconfig; `.git`, `build`, `DerivedData`, `Pods`, and `node_modules` are skipped. A source match beats a match by app name.
3. Otherwise, the one project whose name or folder matches the app's display name.
4. Otherwise **Needs project**. Choosing a project saves the bundle ID on it, so the next report routes itself.

When ScreenClip finds bundle IDs in a project's repository, the project editor shows them under **App bundle IDs (Mac and iOS)** with an **Add** button.

Reports from iOS use the **Agent for iOS reports** chosen in Settings > iOS (agent, model, and effort), or each project's default. Choosing it there never changes the agent a project remembers for Mac captures.

| Situation | What happens |
| --- | --- |
| Mac reachable | Sent at once. The toast says "Sent to *Mac*". |
| Mac asleep, server off, other network | Saved on the device. It is sent automatically when the app is open and finds the Mac again. |
| Mac wants it now | **Fetch** in Settings > iOS asks every connected device to send its saved reports. iOS apps cannot listen in the background, so this reaches devices with the app open. |
| No network at all | In the SDK's settings, **Export or AirDrop to your Mac** shares `.screenclipreport` files. Open one on the Mac, or use **Import report file…**. Each report imports once. |

**Triggers.** By default the SDK listens for shake, and after a system screenshot it shows a small "Report this screen?" banner. Both can be turned off in the SDK's settings, or chosen in code: `ScreenClipKit.start(triggers: [.screenshot])`. To use your own debug menu, call `ScreenClipKit.capture()` or `ScreenClipKit.showSettings()`.

**Other tools that use shake.** ScreenClipKit doesn't take the gesture over. It wraps `-[UIWindow motionEnded:withEvent:]` and always calls the previous implementation first, so the app's own handling, shake-to-undo, and other debugging tools still receive it. Tools that install the same kind of hook later chain to it. A shake doesn't open the report sheet while an alert or another tool's overlay window is on screen. If the app already uses shake, the cleanest setup is `triggers: [.screenshot]` plus `capture()` from your existing menu.

## The loop: file from the couch, install the fix tomorrow

1. **Mac, once:**
   - Turn on **Open at login** (General) and **Receive reports from iOS devices** (iOS).
   - Leave **Keep this Mac awake while receiving iOS reports** on.
   - Pick the **Agent for iOS reports** (agent, model, effort), or keep **Project default**.
   - Turn on the project's automatic merge if you want fixes merged without you. Its validation command (for example `xcodebuild test`) and GitHub checks still have to pass.
2. **Phone, while testing:** shake, annotate, send.
   - Choose a color on the left of the screenshot and a drawing tool on the right. Undo and Redo are below the note. While writing, tap **Done** to return to the screenshot with your note intact.
   - On iOS 26 and later, builds made with Xcode 26 or later show the captured window’s corner rounding in the preview. The report includes the full rectangular image.
   - **Mac reachable:** the report goes straight into the queue, routed by bundle ID, and the agent starts.
   - **Mac not reachable:** the report waits on the phone and goes out as soon as the app is open and finds the Mac.
   - **Leaving the app right after Send:** the SDK asks iOS for a little background time to finish sending.
3. **Phone, any time:** the SDK's settings show **Waiting to send** and **Sent to Mac**. Each sent report shows its number, project, agent, and live status: Queued, Agent working, Needs you, PR open, Merged, Verified, Failed. A merged report links its pull request. With several Macs paired, tap **Connect** beside the one you want. Status, verification, and follow-ups belong to the Mac that received the original report.
4. **Next day:** pull and install the new build from Xcode, retest, and on each merged report tap:
   - **Looks fixed:** marks it Verified on the Mac.
   - **Still broken:** your next capture is added to the same report and goes back to its agent in a fresh worktree.
5. **Mac, at any time:** the iOS tab shows each paired device, what is still waiting on it, and **Fetch**.

**What keeps the Mac working.** ScreenClip prevents idle sleep while the iOS server is on (this can be turned off), and always while a report is queued, an agent is working, or a pull request is waiting to merge automatically. The display can still sleep. A laptop with its lid closed sleeps unless it is on power with an external display.

**What still needs you:**
- Installing the new build on the phone.
- Answering a report that stops at **Needs you**. The phone shows the status; you answer on the Mac.

## Diagnostics

**Attach logs and diagnostics**, under the note, is on by default and can be turned off for a sensitive report. Adding a redaction switches diagnostics off for that capture. You can explicitly include them again if the logs and view tree are safe to share. The files are attached to the report, but agents don't receive them up front. The prompt lists them with a one-line summary each and says where they are. An agent opens them only when the screenshot and note aren't enough.

| File | What | How |
| --- | --- | --- |
| `logs.txt` | The app's unified-log entries (`Logger`, `os_log`, `NSLog`) from the 2 minutes before the capture, at most 500 lines. `com.apple.*` entries are kept only at error or fault level, and repeated lines are collapsed | `OSLogStore` scoped to the app's own process, read in the background while you annotate. If reading takes more than 8 seconds after you tap Send, the report goes without it |
| `view-tree.json` | UIKit views and the accessibility elements the host exposes at capture time, with identifiers, labels, values, traits, and frames in points | Uses public APIs and preserves the device’s accessibility settings. The detail available for SwiftUI depends on which elements the app currently exposes. Secure text fields omit their values. |
| `device-state.json` | Memory footprint, CPU, thermal state, Low Power Mode, battery, free disk, network type, color scheme, Dynamic Type, Reduce Motion, Bold Text, Increase Contrast, VoiceOver, time zone, languages | Read at the moment of capture |
| `console.txt` | The last 300 lines printed to stdout and stderr (`print`) | Only with `ScreenClipKit.start(ScreenClipOptions(captureConsoleOutput: true))`. Output still reaches Xcode's console |
| Your own files | Whatever your app attaches | Only with a provider; see [Attach your own files](#attach-your-own-files) |

### Attach your own files

Your app knows things ScreenClip can't see: the signed-in account, what's in the cart, which feature flags are on, the last request the backend answered. Register a provider and its files ride along with every report, next to the built-in ones.

```swift
#if DEBUG
ScreenClipKit.setAttachmentProvider("cart") { context in
  let cart = await MainActor.run { CartStore.shared.snapshot }   // any Encodable
  let flags = try await FeatureFlags.shared.current()             // can be async work
  return [
    try .json(cart, name: "cart", summary: "the cart's \(cart.items.count) items and applied promo codes"),
    .text(flags.description, name: "feature-flags", summary: "remote feature flags in effect"),
  ]
}
#endif
```

| Question | Answer |
| --- | --- |
| When does it run? | When the report sheet opens, so its data matches the screen the tester captured, and it has all the time the tester spends annotating. After **Send**, ScreenClip waits up to `timeout` more (default 5 seconds, at most 30), with "Saving report…" on screen, then sends the report without whatever hasn't arrived. |
| On which thread? | Off the main actor. Read main-actor state with `await MainActor.run { … }`, and keep heavy work out of it. |
| What does it return? | `[ScreenClipAttachment]`, each built with `.text(_:name:summary:)`, `.json(_ data: Data, name:summary:)`, or `.json(_ value: some Encodable, name:summary:)` (pretty-printed, sorted keys, ISO 8601 dates). Return `[]` to add nothing this time. |
| What is `context`? | `reportID` (log it next to your own records, such as a backend request id, to tie them to the report), `capturedAt`, `screenTitle`, and `screenPath`. |
| Can it be stopped? | It is cancelled when the tester cancels the report or turns off **Attach logs and diagnostics**, so honor `Task.isCancelled` or use cancellable APIs. |
| What if it fails? | A thrown error or a missed timeout leaves only that provider's files out and logs a line under the `ScreenClipKit` subsystem. The report is still sent. |
| Registering several times? | Each `id` holds one provider. Registering the same `id` again replaces it, so calling this from `init` or `onAppear` is safe. `ScreenClipKit.removeAttachmentProvider("cart")` removes it. Providers run concurrently, and their files are listed in registration order. |
| File names | `name` becomes a file name the Mac accepts: lowercased, anything other than letters, digits, and `-` turned into `-`, at most 32 characters, plus `.txt` or `.json`. A name already taken (by `logs.txt`, say, or another provider) gets `-2`, `-3`, and so on. |
| Size | Each attachment can be up to 1 MB (`ScreenClipAttachment.maximumBytes`). Larger ones are left out. All files in a report share the 4 MB limit below, and the largest are dropped first. |
| Release builds | `setAttachmentProvider` is a no-op and the closure is never called. Keep the call inside `#if DEBUG` anyway, so the code that gathers the data stays out of Release. |

The summary is what the agent reads in its prompt, so say what is in the file. Don't attach secrets: text files have token-like strings hidden on the Mac, but JSON files are stored as sent, and any file can reach an agent. The demo app registers a `session` provider in [`ScreenClipKitDemoApp.swift`](../Examples/ScreenClipKitDemo/ScreenClipKitDemo/ScreenClipKitDemoApp.swift).

On the Mac:
- **Storage:** each report's files go in their own folder under `diagnostics/` in ScreenClip's data folder, deleted along with the report.
- **Limits:** only plain `.txt` and `.json` names are accepted, 4 MB in total.
- **Redaction:** token-like strings in text files are replaced with `…`.
- **Viewing:** the report's **Captured context** lists the files and has **Show diagnostics in Finder**.
- **Agents:** Claude Code gets the folder with `--add-dir`, so it can read it without a permission prompt.
- **MCP:** `get_issue` lists the files by name and summary, and returns their contents only with `include_diagnostics: true`.

Grok Bot does not receive diagnostics.

## What the Mac receives

Only the approved image leaves the device: the screenshot with annotations and redactions burned in, at full pixel size. The device keeps no unredacted original. Each report carries:

- app name, bundle ID, version, build, and an optional git SHA (Info.plist key `ScreenClipGitSHA`)
- device model, OS version, locale, orientation, screen size and scale
- the visible view-controller chain and the innermost screen title
- optional diagnostics, described above

The issue detail shows the device and screen. Agents get them in the prompt, and the MCP `get_issue` returns them as `context.device`.

## How it works

```mermaid
flowchart LR
    A[Shake or screenshot] --> B[Snapshot of the app's windows]
    B --> C[Composer overlay window]
    C --> D[On-device outbox]
    D -- Bonjour _screenclip._tcp, paired and encrypted --> E[IOSReceiver on the Mac]
    E --> F[Same queue as Mac captures]
    D -. .screenclipreport file .-> F
```

- **Targets.** `ScreenClipWire` holds the shared annotation model, the Core Graphics renderer (the Mac app draws with the same code), the report and device types, and the protocol. `ScreenClipKit` is the iOS SDK. `IOSReceiver` in `ScreenClipCore` is the Mac listener. On iOS outside Debug, the wire implementation is excluded and the SDK exposes its no-op API.
- **Isolation.** The SDK draws in its own `UIWindow` above the app, so the app's view hierarchy, navigation, and SwiftUI state are never touched. Preferences live in their own defaults suite. Pairings are kept in the Keychain on this device only. Saved reports are kept in Application Support, excluded from backups.
- **Pairing is required.** Reports become prompts for agents that can write to your repositories, so an unpaired device can never deliver one. The Mac accepts pairing only while the **Pair a device** sheet is open. Pairing is an ephemeral P-256 key agreement. Both sides derive a 32-byte key and a 6-digit comparison code from the shared secret, both public keys, and both nonces. A relay that swaps keys would show different codes. The Mac sends its welcome only after you confirm.
- **Transport.** Length-prefixed JSON frames over TCP. After the clear `hello` / `challenge` handshake, every frame is sealed with ChaCha20-Poly1305 under per-direction keys derived from the pairing key and both nonces, with counter nonces, so frames can't be read, forged, replayed, or reordered. A device that claims a paired id without the key fails at the first sealed frame, and nothing is imported.
- **Delivery.** The device removes a report only after the Mac's `ack`, which comes after the store commit. The capture keeps the report's id, so a resend after a lost ack is recognized as a duplicate.
- **Arrival.** Reports go through the same path as a Mac submit: queued for the project's agent, or **Needs project**. **Save iOS reports as drafts** holds them as drafts instead.

## Limits

- iPhone and Mac must be on the same network, and Bonjour must not be blocked. A firewall prompt may appear on the Mac the first time the server starts.
- Only the app's own windows are captured: no status bar, system alerts, or other apps.
- App extensions and widgets are not supported. iOS 17 or later.
- TestFlight builds are Release builds, so the SDK is off there. Importing TestFlight feedback is a planned follow-up.
