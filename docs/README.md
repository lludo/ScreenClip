# ScreenClip documentation

ScreenClip is a macOS menu bar app. You capture a region, optionally annotate it, and keep going. Codex, Claude Code, or Grok Bot does the follow-up, and ScreenClip tracks the GitHub pull request.

The [root README](../README.md) is the short introduction. This page is the map.

## Getting started

- [Getting started](getting-started.md) — requirements, a local build, and the first capture.

## User guide

- [User guide](user-guide.md) — capture, the queue, moving a report, privacy, and screen-recording recovery.
- [Product specification](product-spec.md) — the capture-first goal, screens, and status meanings.
- [Roadmap](roadmap.md) — hands-on gates and the engineering backlog.

## Agents

- [Coding agents](agents/README.md) — how an agent is chosen, the shared local contract, and how to add one.
  - [Codex](agents/codex.md) — `codex app-server`, threads, and desktop links.
  - [Claude Code](agents/claude-code.md) — headless `claude -p` turns and the optional plugin.
  - [Grok Bot](agents/external-assistant.md) — the webhook, the `screenclip/<N>-<slug>-<workspace>` evidence branch, pull-request discovery (`ScreenClip: #N`), and the Connect Grok Bot setup code.
- [Optional MCP plugin](../plugins/screenclip/README.md) — read-only queue access for Codex and Claude Code.

## Architecture

- [Architecture](architecture.md) — the app, the store, worktrees, and who owns merge.
- [Validation](validation.md) — what has been verified, and how to reproduce it.

## Development

- [Development](development.md) — local build and tests, the macOS GitHub Actions job, and the contributing workflow.
- [Localization](localization.md) — ten languages, String Catalogs, the catalog check, pseudolocalization, and screenshot rendering.

## Release and distribution

- [Release and distribution](release/README.md) — the tag, the notarized DMG, Homebrew, and why there is no Mac App Store build.
- [Direct distribution](release/direct-distribution.md) — secrets, `scripts/release-dmg.sh`, `SHA256SUMS`, the tip window, and the cask.
- [Mac App Store sandbox](release/app-store-sandbox.md) — the sandbox blocks `git` and `gh`.

## Website

- [Website](website.md) — build, preview, ten locales, browser language detection, SEO, screenshots, and the Vercel deploy.

## Publishing

- [Publishing checklist](open-source.md) — open items before the repository is public. The license is [PolyForm Noncommercial 1.0.0](../LICENSE.md).
- [Secret-scan record](release/open-source-audit.md) — the November 14, 2026 scan. It stops at commit `a1c72c6`.
- [Archived proposals](archive/README.md) — product questions that have since been decided.
