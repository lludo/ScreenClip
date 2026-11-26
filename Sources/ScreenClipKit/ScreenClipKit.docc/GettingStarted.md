# Getting started

Add ScreenClipKit to the Debug build of your app, pair a device with your Mac, and send a first report.

## Overview

You need ScreenClip 1.1 or later on a Mac running macOS 14 or later. You also need an iOS 17 or later app built with Xcode 16 or newer. The device and the Mac must be on the same local network.

> Tip: The quickest install is to let your coding agent do it. In ScreenClip, open **Settings › iOS** and click **Copy agent prompt**. Paste it into Claude Code or Codex in your iOS project. The agent adds the package, the start call, and the Debug-only Info.plist keys, then shows you the diff.

### Add the package

In Xcode, choose **File › Add Package Dependencies…** and enter:

```
https://github.com/lludo/ScreenClip
```

Link the **ScreenClipKit** product to your app target. App extensions and widgets are not supported.

### Start it once

Call ``ScreenClipKit/ScreenClipKit/start(_:)`` as early as possible: in your `App` initializer, or in `application(_:didFinishLaunchingWithOptions:)`.

```swift
import SwiftUI
#if DEBUG
import ScreenClipKit
#endif

@main
struct ShopApp: App {
  init() {
    #if DEBUG
    ScreenClipKit.start()
    #endif
  }
  var body: some Scene { WindowGroup { ContentView() } }
}
```

By default a shake opens the report sheet. After a system screenshot, a small banner offers to report the screen. To choose differently, pass the triggers you want:

```swift
ScreenClipKit.start(triggers: [.screenshot])  // your app already uses shake
```

To open the sheet from your own debug menu, call ``ScreenClipKit/ScreenClipKit/capture()``. ``ScreenClipKit/ScreenClipKit/showSettings()`` opens pairing, saved reports, and trigger settings.

### Declare local network access in Debug only

The SDK finds your Mac with Bonjour, so the **Debug** Info.plist needs two keys:

```xml
<key>NSBonjourServices</key>
<array>
  <string>_screenclip._tcp</string>
</array>
<key>NSLocalNetworkUsageDescription</key>
<string>Send bug reports to ScreenClip on your Mac.</string>
```

With a generated Info.plist, put the keys in a small `ScreenClip-Debug-Info.plist`. Then set `INFOPLIST_FILE` to it for the Debug configuration only, and Xcode merges it with the generated keys. The demo app in `Examples/ScreenClipKitDemo` is set up this way.

### Pair a device

1. On the Mac, open **Settings › iOS** and turn on **Receive reports from iOS devices**, then click **Pair a device…**.
2. Run the Debug build on the device and shake it. Tap the gear in the report sheet, then tap **Pair** next to your Mac.
3. Check that both screens show the same 6-digit code, then click **Confirm** on the Mac.

From then on: shake, mark up, write a note, and tap **Send**. The report appears in ScreenClip's queue with an iPhone icon. ScreenClip routes it to the project whose repository builds your app's bundle ID.

### Next steps

- <doc:HowReportsWork> follows a report from the shake to the fix.
- <doc:AttachingYourOwnFiles> adds your app's own state to every report.
