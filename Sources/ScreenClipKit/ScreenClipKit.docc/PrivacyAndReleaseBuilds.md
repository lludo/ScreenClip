# Privacy and Release builds

What ScreenClipKit sends, where it goes, and why none of it ships to your users.

## Overview

### Nothing ships in Release

There are two layers:

- Your `#if DEBUG` guards keep the calls out of Release builds.
- The package compiles to an empty stub outside Debug, so even an unguarded call does nothing.

The stub keeps the public API so callers still compile. In a Release build of the demo app, `nm` finds no capture, pairing, or network symbols, and `strings` finds no Bonjour service. The Info.plist has no local network keys either, because they live in the Debug configuration only. ``ScreenClipKit/ScreenClipKit/isActive`` tells you at run time which build you're in.

TestFlight builds are Release builds, so the SDK is off there.

### What leaves the device

Reports go only to a Mac this device has paired with, over your local network:

- **Pairing** is an ephemeral P-256 key agreement confirmed by a 6-digit code shown on both screens. The device commits to its key before the Mac sends its own, so neither side can steer the code, and a relay that swapped keys would show different codes.
- **Encryption.** After the opening handshake messages, which are sent in clear and carry the device and app names and ids, every message is sealed with ChaCha20-Poly1305, so it can't be read, forged, replayed, or reordered.

Each report carries:

- the approved image, with annotations and redactions burned in
- the note
- app name, bundle ID, version, build, and an optional git SHA (Info.plist key `ScreenClipGitSHA`)
- device name (iOS gives apps the generic name, such as "iPhone") and model, OS version, locale, orientation, and screen size
- for a screenshot picked from Photos, that it was picked and its capture date when the file has one
- the visible view-controller chain and the innermost screen title
- optional <doc:Diagnostics> and your own attachments

### What stays on the device

The SDK draws in its own window and keeps its preferences in its own defaults suite. Pairings and the device's id live in the Keychain, on this device only. Reports waiting to be sent are kept in Application Support and excluded from backups. A report is removed once the Mac confirms it has saved it.
