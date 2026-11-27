# ScreenClip next release

Draft notes for the release after 1.2.1. Rename this file when the version is chosen; see the [release checklist](checklist.md).

Pairing an iPhone or iPad is stricter, and several ways a report could get stuck are fixed.

## New

- Pairing an iOS device now has the device commit to its key before the Mac sends its own, so neither side can influence the 6-digit code you compare. **Update ScreenClip on the Mac and the ScreenClipKit package in your app together:** an older SDK does not connect to this ScreenClip, and this SDK does not connect to an older ScreenClip. Devices you already paired stay paired once both sides are updated. When the versions differ, the SDK's settings say which side to update.

## Fixes

- A Codex request that Codex refuses no longer asks you to reconcile a chat that never started.
- The Grok Bot reminder about a missing pull request no longer undoes a cancel made at the same moment.
- An agent's request to close a report waits for GitHub when it cannot be reached, instead of being refused.
- Project settings left open no longer drop an app's bundle ID that ScreenClip learned meanwhile.
- The iOS server restarts by itself after a network failure, and the SDK reconnects after a busy Mac or a pairing that did not happen.

## Install

See [Getting started](../getting-started.md).
