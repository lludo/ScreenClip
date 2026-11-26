# Diagnostics

The optional files ScreenClipKit attaches, and how the tester controls them.

## Overview

**Attach logs and diagnostics**, under the note, is on by default. The tester can turn it off for a sensitive report. Adding a redaction turns it off for that capture, because logs and the view tree can contain text the tester just covered. The tester can turn it back on if that text is safe to share.

Agents don't receive the files up front. The prompt lists each file with a one-line summary and says where it is. An agent opens a file only when the screenshot and note aren't enough.

| File | What it holds |
| --- | --- |
| `logs.txt` | The app's unified-log entries (`Logger`, `os_log`, `NSLog`) from the 2 minutes before the capture, at most 500 lines. `com.apple.*` entries are kept only at error or fault level, and repeated lines are collapsed. Read in the background while the tester marks up the screen. |
| `view-tree.json` | UIKit views, and the accessibility elements SwiftUI exposes, with identifiers, labels, values, traits, and frames in points. Secure text fields leave out their values. Left out when the tester picks a screenshot from Photos, because it would describe the live screen instead. |
| `device-state.json` | Memory, CPU, thermal state, Low Power Mode, battery, free disk, network type, color scheme, Dynamic Type, accessibility settings, time zone, and languages. |
| `console.txt` | The last 300 lines printed to stdout and stderr. Only with ``ScreenClipOptions/captureConsoleOutput``. |
| Your own files | Whatever your attachment providers return. See <doc:AttachingYourOwnFiles>. |

On the Mac, only plain `.txt` and `.json` names are accepted, up to 4 MB per report. Token-like strings in text files are hidden. Each report's files are kept in their own folder and deleted with the report.
