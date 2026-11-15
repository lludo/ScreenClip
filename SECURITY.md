# Security

## Reporting a vulnerability

Please do not open a public issue for a security problem. Use GitHub's private reporting: open the repository's **Security** tab and choose **Report a vulnerability**. Include the macOS and ScreenClip versions, what you did, and what you saw. You can expect an acknowledgement within a few days.

## What ScreenClip stores, and where

- **Captures and reports** stay on your Mac in the ScreenClip queue (a local SQLite database plus image files in the app's data folder). They are sent to a coding agent only when you submit a report.
- **The Grok Bot webhook address and authorization header** are kept in the macOS Keychain under the service `com.screenclip.app.external-assistant`. They are not written to the queue or to logs.
- **Codex and Claude Code** run locally as your own user, each in an isolated Git worktree. ScreenClip uses the sign-ins those tools and the GitHub CLI already hold. It does not read their credentials.
- **No analytics or telemetry** are collected by the app or the website.

## Scope

In scope: the ScreenClip app, its build and release scripts, and the website in this repository. Out of scope: vulnerabilities in Codex, Claude Code, Grok Bot, Git, or the GitHub CLI themselves. Report those to their maintainers.

## Supported versions

Only the latest release receives fixes.
