# ScreenClip

**File bugs as you go, without breaking your flow.**

[![Source-available under PolyForm Noncommercial 1.0.0, free for noncommercial use. Commercial licensing on request.](https://img.shields.io/badge/source--available-PolyForm%20Noncommercial%201.0.0-blue)](LICENSE.md)

A native macOS menu bar app for the small things you notice: a clipped button, confusing copy, a missing detail, or an idea. Grab a screenshot, add a note if you want one, and keep going. ScreenClip keeps the image and the context together. Codex, Claude Code, or Grok Bot does the follow-up.

<p align="center">
  <img src="docs/screenshots/app-queue.png" width="1000" alt="ScreenClip's report queue, showing projects, an annotated capture, and agent activity.">
</p>

<p align="center"><em>Keep reports, captures, and agent conversations together.</em></p>

<table>
  <tr>
    <th>From the menu bar</th>
    <th>Clip and annotate</th>
  </tr>
  <tr>
    <td><img src="docs/screenshots/menu-preview.png" alt="ScreenClip menu bar popover showing report status and the new capture button."></td>
    <td><img src="docs/screenshots/composer-preview.png" alt="ScreenClip capture editor with annotations, a note, and project and agent selectors."></td>
  </tr>
</table>

*The menu-bar surroundings have been simplified; the capture editor uses sample data.*

## Download

The public download is a notarized disk image on GitHub Releases:

[Download for Mac](https://github.com/lludo/ScreenClip/releases/latest/download/ScreenClip.dmg)

That file exists after a `vX.Y.Z` tag is published. Until then, build from source. The app is free. An optional tip is separate from the download. There is no Mac App Store build: the sandbox blocks `git` and `gh`, which the app has to run. Details are in [Release and distribution](docs/release/README.md).

Requires **macOS 14 or later**, a local Git repository, GitHub CLI, and one of Codex, Claude Code, or Grok Bot.

## Quick start

1. **Build and install** with Xcode, or `bash scripts/run.sh`. The shared scheme installs `/Applications/ScreenClip.app`. Signing setup and the first-run checklist are in [Getting started](docs/getting-started.md).
2. **Add a project** (repository, base branch, routing, validation command) and **connect an agent** in Settings. For Grok Bot, ask the assistant **Connect ScreenClip** and paste the setup code, then turn the project switch on.
3. Press **⌘⇧2**, select a region, and submit. ScreenClip suggests a project. You can correct it before the report is sent.

Each report keeps its own agent conversation and an isolated Git worktree. ScreenClip opens a GitHub pull request. Automatic merge runs only when the project allows it and the checks pass. Merged fixes show up under **To retest**.

## Documentation

The full map is the [documentation index](docs/README.md).

- [Getting started](docs/getting-started.md) — requirements, build, first capture
- [User guide](docs/user-guide.md) — the queue, moving a report, privacy, screen recording
- [Coding agents](docs/agents/README.md) — Codex, Claude Code, and Grok Bot
- [Development](docs/development.md) — tests, CI, contributing
- [Website](docs/website.md) — [screenclipai.com](https://screenclipai.com)

Items still open before a public release (support email, Sponsors, release secrets) are listed in one place: [Publishing checklist](docs/open-source.md).

## License

ScreenClip is source-available under the [PolyForm Noncommercial License 1.0.0](LICENSE.md). It is free for noncommercial use. Commercial licensing is available on request.
