# ScreenClip

**File bugs as you go, without breaking your flow.**

A native macOS menu bar app for capturing the little things you notice: a clipped button, confusing copy, a missing detail, or an idea for improvement. Grab a screenshot, add a note if you need one, and keep going. ScreenClip keeps the image and context together, with Codex or Claude Code handling the follow-up work.

<p align="center">
  <img src="docs/screenshots/composer-preview.png" width="780" alt="ScreenClip capture editor with annotation tools, an optional note, and project, issue, and agent selectors.">
</p>

*The native capture editor, shown with sample data. [See the report queue →](docs/screenshots/queue-preview.png)*

## How it works

1. **Notice something.** Press **⌘⇧2** and select a region of a website or native Mac app.
2. **Capture the thought.** Add an optional note, draw an arrow, or redact sensitive details. A screenshot alone works too. ScreenClip suggests a project from the app or browser context; you can correct it before submitting.
3. **Keep going.** Submit a new report or add evidence to an existing one. Follow progress and answer questions from the menu bar or report queue.

Each issue keeps its own agent conversation and isolated Git worktree. ScreenClip validates the changes and opens a GitHub PR. Automatic merge runs when enabled for the project and its checks and policies pass; merged fixes appear under **To retest**.

## What’s included

- **Quick capture and markup.** A configurable global shortcut, freehand drawing, arrows, shapes, text, opaque redaction, and undo/redo.
- **Context that stays attached.** Source app, optional browser URL, project routing, related captures, and drafts.
- **Your choice of local agent.** Codex or Claude Code, with a default in Settings and an override for each new report. Follow-up captures keep the issue’s original agent and session. See [Coding agents](docs/agents/README.md).
- **A searchable feedback queue.** Permanent report numbers such as **#234**, status and project filters, inline replies, and archive/restore without losing evidence. Search a report number across projects, statuses, and archived reports.
- **The rest of the fix.** Validation, PR checks, merge tracking, recovery after interruptions, and a retest queue.

## Get started

Requires **macOS 14+**, **Xcode 16+ with Swift 6**, and a local Git repository. Install and sign in to at least one supported agent: **Codex CLI** with `app-server`, or **Claude Code**. **GitHub CLI** is required for PR automation. There are no external Swift package dependencies.

### Build and run

```sh
cp Config/LocalSigning.xcconfig.example Config/LocalSigning.xcconfig
open ScreenClip.xcodeproj
```

Set your Apple Development certificate and team in `Config/LocalSigning.xcconfig` before running. This file is ignored by Git. Select **ScreenClip → My Mac** and press **⌘R**. The shared scheme builds, installs, and runs **`/Applications/ScreenClip.app`**. Save any open capture and finish or cancel active work before installing an update. **⌘B** builds without installing or launching.

For the same build-and-install flow from Terminal:

```sh
bash scripts/run.sh
```

Local installation requires a signing certificate to keep macOS permissions stable across updates. Build-only checks can use ad-hoc signing. `bash scripts/build.sh [debug|release]` builds without installing; products are under `build/DerivedData/Build/Products/`.

### First capture

1. **Add a project** in **Settings → Projects**: its Git repository, base branch, website URLs or native app bundle IDs, and validation command.
2. **Connect an agent** in **Settings → Connections**. Use **Detect agents**, choose the default, and check sign-in. Codex reuses an existing session when available; **Sign in to Claude** opens Terminal for Claude Code’s login flow. You can also set a Claude executable path and model.
3. **Press ⌘⇧2**, grant macOS Screen Recording permission, select a region, and submit. Change the shortcut in Settings if needed.

Browser URL context is optional and may request Safari or Chrome Automation access. Without it, select the project yourself when routing is unavailable.

ScreenClip hides its own windows during capture by default. To report a bug in ScreenClip itself, turn off **Settings → General → Capture → Hide ScreenClip during capture** and save.

## Working with reports

Captures save locally before dispatch, under `~/Library/Application Support/ScreenClip`. Keep ScreenClip running and the Mac awake while an agent works. Use the report’s reply controls to answer questions; click its number to copy a reference.

**Open in Codex** takes you to the exact issue chat. Claude reports offer **Copy Claude resume command**. Cancel active work before taking over the worktree in another coding client. Codex chats may still appear in Recents instead of the expected desktop project; the [repository association review](docs/validation.md#repository-association-review) documents that limitation.

After an interruption, **Reconcile chat** can recover a saved Codex result and independently validate it before publication. For Claude Code, reconciliation checks for an active session process before allowing Continue; it does not recover completed results from Claude history. **Refresh PR status** updates checks immediately. Archive a report to retain its screenshots and outcome while clearing it from the active queue.

Claude session handling and dispatch are covered by synthetic CLI tests. A live Claude fix through validation, PR publication, and merge remains unverified.

The optional [local MCP plugin](plugins/screenclip/README.md) lets an assistant inspect reports, notes, approved screenshots, and status. Automatic pickup is handled by the native app and needs no plugin. For a quick read-only queue review:

```sh
python3 scripts/review_queue.py --project ScreenClip --details
```

<details>
<summary>Screen Recording troubleshooting</summary>

If capture fails even though access is enabled, use **Check screen access** in General settings. After changing access in System Settings, choose **Check again** or **Reopen app** from the permission banner.

If an older ad-hoc build left an unusable permission entry, quit ScreenClip, reset its screen-capture approval, then reopen the Applications copy and capture again:

```sh
tccutil reset ScreenCapture com.screenclip.app
open /Applications/ScreenClip.app
```

Diagnostics are saved to `~/Library/Application Support/ScreenClip/capture-diagnostics.log`. They contain build and API error metadata, without screenshots, notes, browser URLs, or window titles.

</details>

## Development

```sh
bash scripts/test.sh
python3 scripts/test_plugin.py
python3 scripts/test_review_queue.py
python3 website/build.py
```

`bash scripts/package.sh` creates the Release bundle and `build/ScreenClip-macOS.zip`. Public distribution requires a Developer ID identity through `SCREENCLIP_SIGNING_IDENTITY` and a configured Keychain `SCREENCLIP_NOTARY_PROFILE`. No third-party agent runtime is redistributed.

ScreenClip is a working local app; public downloads and notarized distribution are still being prepared. See [validation evidence and remaining checks](docs/validation.md) for what has been tested.

## Documentation

- [Product specification](docs/product-spec.md) — workflow, scope, screens, and status meanings.
- [Technical design](docs/technical-design.md) — native components, storage, agent integration, and constraints.
- [Implementation plan](docs/implementation-plan.md) — feasibility gates and acceptance criteria.
- [Coding agents](docs/agents/README.md) — how agents plug in, choosing one, and adding a new agent.
  - [Codex](docs/agents/codex.md) · [Claude Code](docs/agents/claude-code.md) · [External assistant proposal](docs/agents/proposals/external-assistant.md)
- [Promotional website](website/README.md) — local preview, SEO, and release links.
