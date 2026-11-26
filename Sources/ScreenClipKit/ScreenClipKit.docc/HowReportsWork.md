# How reports work

Follow a report from the shake on the device to the fix you install the next day.

## Overview

ScreenClipKit only captures. Routing, the agent, the pull request, and merging all happen in ScreenClip on the Mac, the same way they do for a capture made on the Mac.

### Capture

A shake, or **Report** on the banner after a system screenshot, takes a snapshot of your app's own windows. The status bar, system alerts, and other apps are not included. The report sheet opens in its own window above your app, so your view hierarchy, navigation, and SwiftUI state are never touched.

The tester can draw arrows, rectangles, ellipses, freehand lines, and text, and redact anything private. Then they write a note and tap **Send**. Only the marked-up image leaves the device: annotations and redactions are burned in, and no unredacted copy is kept.

To report something seen earlier, the tester can tap the photo button and pick one of the device's screenshots instead of the live capture. It keeps the device's rounded corners when its size matches this screen and is otherwise scaled to fit it, and the report tells the agent it was picked from Photos, when it was taken, and that it may show an older build than the one installed. No photo library permission is needed: the system picker only shares the image the tester chooses.

### Delivery

| Situation | What happens |
| --- | --- |
| Mac reachable | Sent at once. The toast says "Sent to *your Mac*". |
| Mac asleep, server off, or on another network | Saved on the device, then sent automatically when the app is open and finds the Mac again. |
| The tester leaves the app right after Send | The SDK asks iOS for a little background time to finish sending. |
| No network at all | ScreenClip settings on the device can export or AirDrop `.screenclipreport` files to the Mac. |

Reports are sent only to a Mac the device has paired with. Pairing compares a 6-digit code on both screens, and every report is encrypted for that Mac.

### On the Mac

ScreenClip files the report in the project whose **App bundle IDs** list your app. If no project lists it, ScreenClip looks for the bundle ID in each project's Xcode settings. The report carries the device, OS, app version and build, and the visible screen. It also carries any <doc:Diagnostics> the tester chose to attach. The **Agent for iOS reports** setting chooses which agent works on it.

### Status and retest on the device

ScreenClip settings on the device list **Waiting to send** and **Sent to Mac**. Each sent report shows its number, project, agent, and live status: Queued, Agent working, Needs you, PR open, Merged, Verified, or Failed. After a fix merges, install the new build and retest:

- **Looks fixed** marks the report Verified on the Mac.
- **Still broken** adds your next capture to the same report and sends it back to its agent.
