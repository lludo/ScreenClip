# Security

## Reporting a vulnerability

Please do not open a public issue for a security problem. Use GitHub's private reporting: open the repository's **Security** tab and choose **Report a vulnerability**. Include the macOS and ScreenClip versions (and the iOS and ScreenClipKit versions for the SDK), what you did, and what you saw. You can expect an acknowledgement within a few days.

## What ScreenClip stores, and where

- **Captures and reports** stay on your Mac in the ScreenClip queue (a local SQLite database plus image files in the app's data folder). They are sent to a coding agent only when you submit a report.
- **Submitted screenshots are published to the project's GitHub repository.** For Codex and Claude Code, the flattened report screenshots and the retested After images are committed with the fix and embedded in the pull request, unless the project's **Commit screenshots to the repository** setting is off; then nothing is committed under `.screenclip/` and the pull request describes Before / After in words. Committed screenshots stay on the base branch after the merge. For Grok Bot, the approved screenshots and report fields are pushed to a `screenclip/` branch before the webhook is sent. Anyone who can read the repository can read them, and a later deletion does not remove them from Git history. Only the annotated, redacted derivative is published. Details are in the [user guide](docs/user-guide.md#what-each-agent-can-see).
- **The Grok Bot webhook address and authorization header** are kept in the macOS Keychain under the service `com.screenclip.app.external-assistant`. They are not written to the queue or to logs.
- **Reports from iOS** arrive only while **Receive reports from iOS devices** is on, over the local network, from devices you paired by comparing a 6-digit code and confirming it on the device and on the Mac. They are encrypted for this Mac. Pairing keys are kept in the Keychain on both sides. ScreenClipKit exists only in Debug builds of your app. Details are in the [iOS guide](docs/ios-sdk.md).
- **Codex and Claude Code** run locally as your own user, each in an isolated Git worktree. ScreenClip uses the sign-ins those tools and the GitHub CLI already hold. It does not read their credentials.
- **No analytics or telemetry** are collected by the app. The website counts visitors and page views with cookieless Vercel Web Analytics; see its [privacy page](https://screenclipai.com/privacy).

## Scope

In scope: the ScreenClip app, ScreenClipKit, the MCP plugin, the build and release scripts, and the website in this repository. Out of scope: vulnerabilities in Codex, Claude Code, Grok Bot, Git, or the GitHub CLI themselves. Report those to their maintainers.

## Supported versions

Only the latest release receives fixes.
