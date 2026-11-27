# ScreenClip documentation

ScreenClip is a macOS menu bar app, with an SDK for reporting from your own iOS apps. You capture a region, optionally annotate it, and keep going. Codex, Claude Code, or Grok Bot does the follow-up, and ScreenClip tracks the GitHub pull request.

The [root README](../README.md) is the short introduction. This page is the map.

## Use ScreenClip

- [Getting started](getting-started.md) — requirements, installing the release or building from source, and the first capture.
- [User guide](user-guide.md) — capture, the queue, moving a report, agent permissions, what each agent can see, and screen-recording recovery.
- [ScreenClip for iOS](ios-sdk.md) — ScreenClipKit in your app's Debug build: shake to report, pairing, the local server, Fetch, and AirDrop.
- [Release checklist](release/checklist.md) — every step for cutting a release.
- [1.2.2 release notes](release/v1.2.2.md) — pairing an iPhone or iPad commits to its key before the code is derived and is confirmed on both screens (update the Mac app, then the SDK), the queue no longer holds full-size screenshots in memory, and fixes for stuck reports.
- [1.2.1 release notes](release/v1.2.1.md) — reports no longer fail on usage limits: Claude Code switches to a lower model and reports move to your other agent with the work so far; longer turns, and agents can close reports they fixed themselves.
- [1.2.0 release notes](release/v1.2.0.md) — report an existing iPhone or iPad screenshot, attach your app's own files, and let agents suggest project settings; pull request evidence stays off the base branch.
- [1.1.0 release notes](release/v1.1.0.md) — ScreenClip for iOS: ScreenClipKit in your app's Debug build, shake to report, live status and retest from the phone; new projects use the repository's default branch.
- [1.0.5 release notes](release/v1.0.5.md) — Claude Code and Codex can check each project's reports, installed from Settings, and reports merged by hand are detected.
- [1.0.4 release notes](release/v1.0.4.md) — the popover lists the reports behind each count, review fixes, and the first automatic update.
- [1.0.3 release notes](release/v1.0.3.md) — automatic updates, instant pull request previews, and fixes.
- [1.0.2 release notes](release/v1.0.2.md) — text notes, merging from the report, and fixes.
- [1.0.1 release notes](release/v1.0.1.md) — fixes and improvements since 1.0.0.
- [1.0.0 release notes](release/v1.0.0.md) — what the first release includes, and its limits.

## Agents

- [Coding agents](agents/README.md) — how an agent is chosen, the shared local contract, the Before / After screenshot contract, and how to add an agent.
  - [Codex](agents/codex.md) — `codex app-server`, threads, permissions, and desktop links.
  - [Claude Code](agents/claude-code.md) — headless `claude -p` turns, sessions, and the Claude Desktop hand-off.
  - [Grok Bot](agents/external-assistant.md) — the webhook, the `screenclip/<N>-<slug>-<workspace>` evidence branch, pull-request discovery (`ScreenClip: #N`), and Connect Grok Bot (**POST to** and **key**).
- [Optional MCP plugin](../plugins/screenclip/README.md) — queue access for Codex and Claude Code: read reports, suggest project settings for you to accept, and close reports they fixed themselves.

## How it works

- [Product specification](product-spec.md) — the capture-first goal, screens, status meanings, and the product decisions.
- [Architecture](architecture.md) — the app, the store, routing, worktrees, and who owns merge.
- [Validation](validation.md) — what has been verified, and how to reproduce it.

## Develop

- [Development](development.md) — local build and tests, the macOS GitHub Actions job, and the contributing workflow. The short version is the root [CONTRIBUTING.md](../CONTRIBUTING.md).
- [Localization](localization.md) — ten languages, String Catalogs, the catalog check, and screenshot rendering.
- [Website](website.md) — build, preview, ten locales, browser language detection, SEO, screenshots, and the Vercel deploy.

## Release and distribution

- [Release and distribution](release/README.md) — the index for this section, and why there is no Mac App Store build.
- [v1.0.0 readiness](release/v1.0.0-status.md) — the validation record of the first release.
- [Direct distribution](release/direct-distribution.md) — the tag workflow, secrets, `scripts/release-dmg.sh`, `SHA256SUMS`, the Homebrew cask, and updates.
- [Mac App Store sandbox](release/app-store-sandbox.md) — the sandbox blocks `git` and `gh`.
- [Publishing checklist](release/publishing-checklist.md) — open items: support channel, Sponsors, and release secrets.
- [Publication audit](release/publication-audit.md) — the November 15, 2026 history cleanup, and the pull-request refs GitHub still has to purge.

## Project

- [Roadmap](roadmap.md) — open verification gates, the next feature, and the maintenance backlog.
- [Security policy](../SECURITY.md) — reporting a vulnerability, and what ScreenClip stores and publishes.
- [License](../LICENSE.md) — PolyForm Noncommercial 1.0.0.
- [Archive](archive/README.md) — closed product questions and one-off hand-off prompts, kept for history.
