# ``ScreenClipKit``

Report what you see in your own iOS app, straight into ScreenClip on your Mac, where a coding agent fixes it.

@Metadata {
  @PageImage(purpose: icon, source: "screenclip-icon", alt: "The ScreenClip icon")
  @PageColor(orange)
}

## Overview

ScreenClipKit is a small Swift package for the **Debug** build of your iOS app. A tester shakes the device, or takes a screenshot and taps **Report**. They mark up the screen and add a note, then tap **Send**. The report goes over your local network, encrypted, to ScreenClip on the Mac you paired with. There it joins the same queue as captures made on the Mac. Your coding agent (Codex, Claude Code, or Grok Bot) works on it and opens a pull request. If the Mac isn't reachable, the report waits on the device and is sent later.

![The ScreenClipKit report sheet over a demo app, with an arrow and a note.](composer)

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

Release builds contain none of it. Outside Debug the package compiles to an empty stub with the same API, and your `#if DEBUG` guards keep the call out as well. See <doc:PrivacyAndReleaseBuilds>.

New to ScreenClip? [ScreenClip for iPhone and iPad](https://screenclipai.com/ios) shows the whole loop, and you can download ScreenClip for the Mac at [screenclipai.com](https://screenclipai.com).

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:HowReportsWork>
- ``ScreenClipKit/ScreenClipKit/start(_:)``
- ``ScreenClipOptions``

### Triggers and your own debug menu

- ``ScreenClipTrigger``
- ``ScreenClipKit/ScreenClipKit/start(triggers:)``
- ``ScreenClipKit/ScreenClipKit/capture()``
- ``ScreenClipKit/ScreenClipKit/showSettings()``
- ``ScreenClipKit/ScreenClipKit/isActive``

### Attaching your own data

- <doc:AttachingYourOwnFiles>
- ``ScreenClipKit/ScreenClipKit/setAttachmentProvider(_:timeout:_:)``
- ``ScreenClipKit/ScreenClipKit/removeAttachmentProvider(_:)``
- ``ScreenClipAttachmentProvider``
- ``ScreenClipAttachment``
- ``ScreenClipReportContext``

### Diagnostics and privacy

- <doc:Diagnostics>
- <doc:PrivacyAndReleaseBuilds>
