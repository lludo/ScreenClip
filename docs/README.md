# ScreenClip documentation

ScreenClip is a macOS menu bar app. You capture a region, optionally annotate it, and keep going. Codex, Claude Code, or Grok Bot does the follow-up, and ScreenClip tracks the GitHub pull request.

The [root README](../README.md) is the short introduction. This page is the map.

## Use ScreenClip

- [Getting started](getting-started.md) — requirements, installing the release or building from source, and the first capture.
- [User guide](user-guide.md) — capture, the queue, moving a report, agent permissions, what each agent can see, and screen-recording recovery.
- [1.0.0 release notes](release/v1.0.0.md) — what the first release includes, and its limits.

## Agents

- [Coding agents](agents/README.md) — how an agent is chosen, the shared local contract, the Before / After screenshot contract, and how to add an agent.
  - [Codex](agents/codex.md) — `codex app-server`, threads, permissions, and desktop links.
  - [Claude Code](agents/claude-code.md) — headless `claude -p` turns, sessions, and the Claude Desktop hand-off.
  - [Grok Bot](agents/external-assistant.md) — the webhook, the `screenclip/<N>-<slug>-<workspace>` evidence branch, pull-request discovery (`ScreenClip: #N`), and Connect Grok Bot (**POST to** and **key**).
- [Optional MCP plugin](../plugins/screenclip/README.md) — read-only queue access for Codex and Claude Code.

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
- [v1.0.0 readiness](release/v1.0.0-status.md) — what is done for the first release and what is left before it is published.
- [Direct distribution](release/direct-distribution.md) — the tag workflow, secrets, `scripts/release-dmg.sh`, `SHA256SUMS`, the Homebrew cask, and updates.
- [Mac App Store sandbox](release/app-store-sandbox.md) — the sandbox blocks `git` and `gh`.
- [Publishing checklist](release/publishing-checklist.md) — open items before the repository is public: support channel, Sponsors, and release secrets.
- [Publication audit](release/publication-audit.md) — the November 15, 2026 history cleanup, and what GitHub still has to purge.

## Project

- [Roadmap](roadmap.md) — open verification gates, the next feature, and the maintenance backlog.
- [Security policy](../SECURITY.md) — reporting a vulnerability, and what ScreenClip stores and publishes.
- [License](../LICENSE.md) — PolyForm Noncommercial 1.0.0.
- [Archive](archive/README.md) — closed product questions and one-off hand-off prompts, kept for history.
