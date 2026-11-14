# ScreenClip validation

Updated: November 14, 2026. Development host: macOS 27.0.1, Xcode 27.2, Swift 6.4.2, Apple Silicon.

This page records what is verified and how. What is still open is in the [roadmap](roadmap.md#open-gates).

## Current status

Latest run: **111 Swift tests** (61 core, 50 app), **10 Python plugin tests**, **5 Python queue-review tests**, and the external assistant webhook script tests passed, along with the website build and an Xcode Debug build. CI runs the same suites, a shell syntax check, the website build, and Xcode Debug and Release builds.

| Area | Automated | Hands-on or live | Not yet verified |
| --- | --- | --- | --- |
| Capture and markup | Annotation pixels (orientation, ellipse, pen width, opaque redaction); style round-trip; four permission regressions | Region capture → markup → submit on this Mac, from the signed app in Applications, with permission retained across an installed update | Multiple monitors and scales, Spaces, transient menus, every ScreenClip surface with hiding on and off |
| Queue and store | Persistence, single writer, report numbers (legacy migration, no reuse), drafts, related captures, archive rules, delete rules, feedback search, badge counts, export | Installed updates kept both projects and all reports | Downgrade to an older build (see store versioning in the roadmap) |
| Routing | Ambiguity, URL boundaries, most-specific website rule, case-insensitive schemes | — | Browser URL permission prompts |
| Codex | JSON-RPC correlation and timeouts, questions and replies in one thread, cancellation during project lookup and before turn acknowledgement, authentication (nine regressions) | A synthetic fix through validation, GitHub CI, PR, and confirmed merge in a private fixture; restart and resume in the same chat | Desktop sidebar grouping fails; see below |
| Claude Code | Fake-CLI client and worker tests: arguments, evidence input, progress, structured and fenced results, usage, failures, cancellation, missing sessions, timeouts are wired, detection, holding work while signed out | The installed CLI (2.1.128) has every flag and sandbox setting used; plugin manifests pass `claude plugin validate` | A live fix through PR and merge; permanent plugin installation; an interactive plugin fix |
| Grok Bot | `ExternalAssistantTests`: payload encoding, slug and branch names, opt-in, idempotent retry, pull-request matching, the `.screenclip/` merge guard, detection, the Authorization header on a test POST (line breaks rejected, removed on a cross-host redirect), Keychain update in place. `ExternalAssistantAppTests`: stays in the agent list, submit refused until configured and the project opts in, a restart during the POST stays retryable | — | A live webhook, an evidence push to a real repository, pull-request discovery, and auto-merge while `.screenclip/` is still present; see [Grok Bot](#grok-bot-external-assistant) |
| Git and GitHub safety | Changed-source rejection, stale head and revision merge rejection, worktree from `origin/<base>` excludes unpushed commits, worktree cleanup, GitHub remote parsing, PR body redaction | Four ScreenClip reports fixed and merged through PRs #1–#4 | — |
| Process handling | A background grandchild holding the pipe cannot hang a command; a timeout terminates the whole process tree; agents get no GitHub tokens | — | — |
| Plugin and scripts | MCP server: approved images only, private fields excluded, invalid arguments and malformed requests answered with errors; queue review: read-only access, searches, archive eligibility | — | Public directory submission |

## Grok Bot (external assistant)

November 14, 2026. Grok Bot is implemented as `AgentKind.external` and documented in [external-assistant.md](agents/external-assistant.md). Approved screenshots are pushed to `screenclip/<reportNumber>-<slug>-<workspace>`; the webhook schema `screenclip.external.v1` does not carry image bytes. `report.json` uses the same fields, with `evidence.commit` null because that file cannot contain its own commit id.

The change was written on Linux, which has no Swift toolchain. GitHub Actions then ran the suite on macos-15 (arm64). After a slug-length fix, the macOS workflow passed `bash scripts/test.sh`, the Python tests (`test_plugin.py`, `test_review_queue.py`, `test_external_assistant.py`), and the Xcode Debug and Release builds.

`bash scripts/test.sh` covers `ExternalAssistantTests` (payload encoding, slug and branch names, opt-in, idempotent retry, pull-request matching, the `.screenclip/` merge guard, detection, and the Authorization header on a test POST) and `ExternalAssistantAppTests` (Grok Bot stays in the agent list, submit refuses it until the webhook is configured and the project opts in, and a restart during the POST stays retryable). One slug-length failure on the first green-compile run was fixed before the passing run.

A later review fixed three hand-off bugs and added tests for them: a retry commits leftover `.screenclip/` files before fast-forwarding, the Keychain item is updated in place, and the Authorization header is rejected when it contains a line break and is removed on a cross-host redirect. Those tests ride with the next macOS workflow run.

A second review before merge fixed four more: each workspace gets its own `screenclip/` branch, so a follow-up after a merge no longer collides with the merged branch or rediscovers the merged pull request; a restart while evidence was still being prepared or pushed now offers Retry instead of waiting for a pull request that was never requested; a rejected push after a base update rolls back the local merge; and the Authorization header survives a redirect only when scheme, host and port all match.

After merging the November 14 worker and view reorganization from `main`, the Grok Bot worker code moved to `AgentWorker+External.swift` and the `.screenclip/` gate to `MergeGuard.swift`. `bash scripts/test.sh` passed locally on the development host, including both Grok Bot suites.

**Still not exercised**

A live webhook, an evidence push to a real repository, pull-request discovery, and auto-merge while `.screenclip/` is still present. Those need a configured assistant and a GitHub repository.

## Repository association review

This is the open Codex desktop gap. ScreenClip **0.1.6 (7)** ran `--integration-project-link` from `/Applications` with a separate test queue, the registered ScreenClip repository, and a synthetic image. It created chat `01a1d833-aeda-7623-92c8-38e4c5f37953`, returned a structured question, and left the isolated worktree clean.

The runtime's `thread/read` reported canonical project `01a1d709-ddcf-7822-baf5-32d587d4ea5e`, rooted at the ScreenClip repository. The desktop's saved ScreenClip project was `74741be5-2042-4af7-829a-68e0a3f2f2af`. The sidebar listed the chat with `projectId: null`, in the ungrouped Tasks section, and the desktop move tool refused because the source project could not be determined.

Result: **repository context, worktree isolation, and runtime association pass; automatic desktop sidebar grouping fails on this Codex version.** A successful app-server response alone is not evidence of sidebar placement. The exact chat link is the working navigation route.

To repeat it (creates a synthetic Codex chat and uses normal account usage):

```sh
/Applications/ScreenClip.app/Contents/MacOS/ScreenClip \
  --integration-project-link \
  --data-dir "$PWD/.local/project-link-check-NEW" \
  --integration-repo "$PWD" \
  --integration-image "$PWD/docs/screenshots/composer-preview.png"
```

Inspect `integration-result.json`, the runtime's `thread/read`, and the desktop sidebar listing separately. The test stops at a question; publishing is disabled by its empty validation command and automatic merge is off.

## Evidence log

Key live results, newest first. Commit history and PRs have the details.

- **November 14, 2026, report #11.** **Add context** saves text-only notes after filing, including on queued reports, and agents receive them in an `additional_context` prompt section. Regressions cover persistence, legacy reports, search, pending questions, reopening completed reports, and context arriving during an agent turn. A synthetic native preview confirmed the control, the focused editor, empty-save prevention, Cancel discarding the draft, and saved timestamped context.
- **November 14, 2026, full review.** Four parallel reviews (agent worker, core store and Git, app UI, scripts and docs) led to these fixes:
  - **Worker:** a crash when an issue was deleted mid-dispatch, a Codex disconnect interrupting a validated publish, approval requests reviving canceled issues, new evidence during publication leaving issues stuck, and stale turn IDs.
  - **Claude client:** stdin written off the actor, a 45-minute turn limit.
  - **Processes:** command hangs on inherited pipes, process-tree termination on timeout.
  - **Git and GitHub:** submodule fingerprints, worktrees from the remote base, worktree cleanup after merge, an aborted conflicting base merge, GitHub remote parsing, PR body redaction, most-specific routing.
  - **App UI:** drafts attached to submitted issues, Settings reverting the pause state, losing the shortcut on a conflict, delete rules, dialogs acting on the wrong report after a selection change, double-sent replies.
  - **Plugin:** robustness of the MCP server.

  The agent worker and the large views were split into focused files.
- **November 13, 2026, Claude Code.** Claude Code was added as a selectable agent, with a Claude Code plugin and the `fix-report` skill. A client defect, a stderr reader spinning a CPU core after exit, was fixed.
- **November 13, 2026, feedback reports.** Recovery ([PR #1](https://github.com/lludo/ScreenClip/pull/1)), composer layout ([#2](https://github.com/lludo/ScreenClip/pull/2)), the capture default ([#3](https://github.com/lludo/ScreenClip/pull/3)), and the authentication timeout ([#4](https://github.com/lludo/ScreenClip/pull/4)) passed CI and merged through ScreenClip. Archive controls, feedback search, and the queue header shipped in [#5](https://github.com/lludo/ScreenClip/pull/5).
- **Codex live fix.** The native worker fixed a synthetic CSS bug through isolated editing, local validation, PR creation, passing GitHub CI, a guarded merge, and confirmed merged state ([private fixture PR](https://github.com/lludo/screenclip-integration-20261113/pull/1), chat `01a1d7b6-c810-7213-879d-51dd0dc111b6`). Earlier, a synthetic screenshot produced a question, then a reply after process restart and resume in the same chat (`01a1d7aa-7bbc-7620-987b-f497c14f91e1`).
- **Permissions.** An ad-hoc development copy received ScreenCaptureKit denial `-3801`. After installing to Applications and resetting only `ScreenCapture` for the app's bundle ID with `tccutil`, the user regranted access. Later installed updates kept the permission, and self-capture selections succeeded with hiding off.
- **Codex runtime.** `initialize`, account, and model discovery passed with runtime `0.169.0-alpha.11.1` and the existing ChatGPT sign-in. The npm launcher at `/opt/homebrew/bin/codex` lacked its native binary, so development used the ChatGPT app's bundled runtime.

## Reproduce

Run the suites listed under [Development in the README](../README.md#development). To render native previews with synthetic data:

```sh
bash scripts/build.sh
build/DerivedData/Build/Products/Debug/ScreenClip.app/Contents/MacOS/ScreenClip --render-preview --data-dir "$PWD/.local/preview-new"
```

Use a new preview data directory each time. Preview mode pauses processing and does not send images to an agent. Rendering needs WindowServer access, so run it outside a restricted terminal sandbox.

Live diagnostics, which create real agent conversations and use account usage:

- `scripts/probe_codex.py --codex /path/to/codex` performs a read-only Codex handshake.
- The `ScreenClipProbe` executable runs two Codex model turns with a synthetic image and a disposable repository.
- `scripts/create_integration_fixture.py` creates a private `OWNER/screenclip-integration-*` repository. `ScreenClip --integration-run` then performs real PR and merge operations in that fixture only. Never point it at a production repository.

## Native previews

These use synthetic sample observations, not user screen content.

![Capture and annotation editor](screenshots/composer-preview.png)

[Queue preview](screenshots/queue-preview.png)
