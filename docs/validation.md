# ScreenClip validation

November 13, 2026. Development host: macOS 27.0.1, Xcode 27.2, Swift 6.4.2, Apple Silicon.

## Verified

The reviewed combined source passed **80 Swift tests**, **7 Python plugin tests**, and **4 Python queue-review tests**. Xcode Debug and Release builds and strict signature verification passed for **0.1.7 (8)**. Native synthetic previews confirm the report filter, visible archive/restore action, clear queue header, and updated composer layout. SwiftPM supplies the core library and command-line tests. The earlier installed 0.1.6 check retained both registered projects and all six existing reports and assigned their stable numbers. Public Developer ID signing and notarization remain separate. The live desktop project-grouping check failed; see [repository association review](#repository-association-review).

- Native Swift executable and app bundle build without third-party package dependencies.
- The native `ScreenClip.xcodeproj` shared scheme builds and development-signs the app for My Mac (Apple Silicon). Run has an install pre-action and launches `/Applications/ScreenClip.app`; the XML wiring and installer were checked, while clicking Command-R in Xcode remains a manual check. `scripts/run.sh` uses the same Xcode project and installer. Installation rejects ad-hoc builds, stages/verifies before quitting existing copies, and does not touch Application Support. A checkout without the ignored local signing file still builds ad-hoc for CI. The core library remains a local package dependency; the command-line test suite uses Swift Package Manager.
- Automated tests cover persistence and asset export, single-writer ownership, project ambiguity and URL boundaries, badge counts, grouped input revisions, draft submission, worktree recovery and preservation of dirty source checkouts, JSON-RPC correlation/timeouts, changed-source validation rejection, stale-head/revision merge rejection, and native worker questions/replies.
- Pixel tests verify image orientation, ellipse color and clear interior, pen thickness, and opaque redaction regardless of selected color in the exported PNG. Style fields round-trip, and captures saved before those fields were introduced still decode.
- Four permission regressions cover successful real capture despite a false preflight hint, preserving actual denial and recovering on recheck, requiring reopen after executable replacement, and retaining non-permission errors accurately. Diagnostic events distinguish shortcut, access check, selection overlay, selected region, cancellation, and failure.
- Installation preserved two registered projects and the existing empty queue. Process inspection confirmed exactly one copy running, from Applications. The old hand-assembled bundle and previous diagnostic Xcode bundle were unregistered and removed. Future builds produce the ordinary Xcode product; normal runs use the installed copy.
- The initial signed development copy still received actual ScreenCaptureKit denial `-3801`. After installing in Applications and resetting only `ScreenCapture` for `com.screenclip.app` with `tccutil`, the user regranted access and reopened the app. The log recorded access available, one display's selection overlay, and a selected 270 × 247 region. The user confirmed the selector and supplied a screenshot of an annotated test report submitted and marked Working in the menu bar. Basic capture → markup → submit is now verified on this Mac.
- The overflow menu now hides its native chevron and gives the ellipsis a 28 × 24 point label; a synthetic native preview confirmed no collision. Preview rendering no longer registers the global capture shortcut while the installed app is running.
- **Hide ScreenClip during capture** is on by default and available in General settings. Both window hiding and the screenshot filter follow the setting; turn it off to capture ScreenClip itself, including its open popover. Regressions check new stores, older settings without the preference, and preservation of both explicit choices through SQLite. Installation of 0.1.5 preserved all queue contents, including the user's submitted test report. The self-capture path still needs a hands-on capture of every ScreenClip surface.
- After installing 0.1.5 without resetting permissions, live diagnostics recorded two successful selections with `hideScreenClip=false`, sizes 1439 × 115 and 1038 × 957. Preflight and actual access both succeeded. This confirms permission retention after the installed update and successful selection with self-capture enabled; visual coverage of every ScreenClip surface remains a manual check.
- Synthetic native queue/composer/settings previews are rendered and inspected; no user screen content is used in those previews.
- Report-numbering regressions are included in the latest run. They cover legacy decoding and numbering without queue reordering, persistence, deleted-number retirement, draft submission and related captures retaining their number, exact reference search across project/status/archive filters, references in Codex names/prompts, exports, and plugin lookup by number. Synthetic native queue and menu previews visibly show the report numbers, with the selected report's copy control beside its status. The installed 0.1.6 build assigned numbers to all six existing reports on opening the queue.
- Optional MCP bridge tests cover approved-image retrieval, status filtering, excluded private fields, and rejection of image paths outside the asset directory.
- Codex `initialize`, account and model discovery passed with runtime `0.169.0-alpha.11.1` using the existing ChatGPT sign-in. No credentials were copied into this repository.
- Repository context and runtime assignment are implemented and tested. The installed-app association check found a desktop sidebar compatibility failure; details and review fixes are below.
- Authentication checks reuse existing ChatGPT/API-key sessions and providers that do not require OpenAI authentication. Nine regressions cover avoiding redundant browser login, missing account data, reported passkey failure, cancellation and stale callbacks, code-based fallback, missing callback timeout, failed browser launch, and recovering a session while a login is pending. Browser errors that never return to the local callback are bounded by a five-minute timeout; the user can cancel sooner. The fallback is tested against the runtime's generated contract, without signing the user out to test it live.
- A synthetic screenshot produced a question, then a reply after process restart/resume in the same chat. The desktop app's chat reader independently recognized the saved conversation and both completed turns. Test chat ID: `01a1d7aa-7bbc-7620-987b-f497c14f91e1`.
- The actual native worker completed a synthetic CSS bug through isolated editing, local validation, PR creation, passing GitHub CI, guarded merge, and confirmed merged state. [Private fixture PR](https://github.com/lludo/screenclip-integration-20261113/pull/1). Its Codex chat ID is `01a1d7b6-c810-7213-879d-51dd0dc111b6`.

The private fixture contains synthetic HTML/CSS and a regression test. It is retained as inspectable test evidence and contains no user screenshots. The ScreenClip source repository has `https://github.com/lludo/ScreenClip.git` configured as its origin.

The source review added a regression that reproduced two chats and turns being created when canceling and immediately retrying during project lookup. Outstanding dispatches now stay serialized until their requests return, and their tasks retain the model through cleanup. Claude process-client regressions cover evidence input, progress and structured output, usage, final records without a newline, unsuccessful process exits, malformed JSON text, and shell-quoted resume commands. Local Claude selection and dispatch are now implemented; the additional worker and layout checks are described below. Queue-review tests cover read-only database access, exact report-number searches, archive eligibility, missing project configuration, and agent-specific session output. CI runs the new Python tests and website build.


## Feedback report completion

- Recovery [PR #1](https://github.com/lludo/ScreenClip/pull/1), capture-default [PR #3](https://github.com/lludo/ScreenClip/pull/3), authentication-timeout [PR #4](https://github.com/lludo/ScreenClip/pull/4), and composer-layout [PR #2](https://github.com/lludo/ScreenClip/pull/2) passed CI and merged. The local queue retains the report PR links, validated heads, merge commits, and captures. Merged reports remain available for retesting until verified.
- Reports #4–#6 remove the composer's duplicate close control, expose archive/restore and a status filter at the top of the queue, search capture notes plus questions/replies/results/activity, and replace automatic navigation chrome with ordinary resizable queue panes. Synthetic Release previews show readable header controls without the reported blurred strip. The native window close/discard guard remains in place.
- Three new regressions cover feedback search, durable archive/restore with capture and PR evidence retained, and rejection of archiving while work or an agent permission request is outstanding. A canceled or verified report can be archived without deleting its screenshots or changing its outcome.
- Both projects have validation commands and automatic merge configured. Genealogy's CI [PR #1424](https://github.com/lludo/Genealogy/pull/1424) merged; its configured Core validation passed 1,225 tests with 25 skips and no failures. Live ScreenClip queue recovery is coordinated by one native queue writer.

## Local agent and queue review

November 13, 2026: the combined agent selection, worker, plugin, queue layout, and README changes passed **80 Swift tests** (41 core and 39 app), **7 Python plugin tests**, and **4 Python queue-review tests**. Xcode Debug and Release builds and strict signature verification passed. The website build and installed Claude CLI's plugin manifest validation passed. The refreshed README screenshots use synthetic data and were visually inspected.

The review corrected an obsolete disabled-Claude dispatch test, preserved Claude jobs across Codex disconnects, and added coverage for missing resumed sessions reported only on stderr, active external Claude sessions, and complete stderr draining. Existing native layout regressions cover empty and populated queues at normal and minimum sizes, including a scrolling project list with reserved footer space. Both local agents are now selectable; submitted issues retain their agent through follow-ups.

Claude worker tests use fake CLIs and isolated Git fixtures. A live Claude fix through validation, PR publication, and merge, permanent Claude plugin installation, and an interactive plugin fix remain unverified. Claude reconciliation checks for active processes but does not read completed results from Claude history. The review builds were not installed as part of this review.

A follow-up fixed a Claude client defect: after `claude` exited, the stderr readability handler kept firing at end-of-file and spun a CPU core, which could also stall waiting for exit. The client now drains stderr to EOF on a dedicated reader, waits for that reader before reporting errors, and waits for process exit through the termination handler. The full Swift suite passed afterwards, along with the 7 plugin tests. Agent documentation moved to [docs/agents/](agents/README.md).

## Repository association review

ScreenClip **0.1.6 (7)** was installed at `/Applications/ScreenClip.app` with the existing development signature. Its native worker ran `--integration-project-link` with a separate test queue, the registered ScreenClip repository, and a synthetic image. It created chat `01a1d833-aeda-7623-92c8-38e4c5f37953`, returned a structured question, and left the isolated worktree clean. The user subsequently moved that test chat to Trash. The clean test worktree and its fully merged branch were removed; `.local/project-link-check-1/integration-result.json` remains as local evidence.

The runtime's `thread/read` reported canonical project `01a1d709-ddcf-7822-baf5-32d587d4ea5e`, whose root was the ScreenClip repository. The desktop's saved ScreenClip project was `74741be5-2042-4af7-829a-68e0a3f2f2af`. Its sidebar listing still reported the synthetic chat with `projectId: null`, in the ungrouped Tasks section. The supported desktop move tool returned **"The task's source project could not be safely determined."** Direct computer-control inspection of the Codex window was unavailable; the desktop's connected sidebar listing supplied the membership evidence.

Result: **repository context, worktree isolation, and runtime association pass; automatic desktop sidebar grouping fails on this installed Codex combination.** A schema field or successful app-server response alone is insufficient evidence of sidebar placement. The worktree remains the execution directory. The exact chat link is the working navigation route until the desktop and runtime project identities are reconciled through a supported integration.

The source review also fixed cancellation during project lookup and before turn acknowledgement, superseded draft image retention, approved-image cleanup after a failed original write, repository-root symlink handling, and validation fingerprints for leading-space filenames, executable permissions, and dangling symlinks. Project-link diagnostics are consolidated and deduplicated. Codex client version metadata follows the app bundle version. Both integration modes now require an explicit, previously nonexistent test directory before opening a store. Python syntax checks, shell syntax checks, and `git diff --check` also passed.

To repeat the installed native check (creates a synthetic Codex chat and consumes normal account usage):

```sh
/Applications/ScreenClip.app/Contents/MacOS/ScreenClip \
  --integration-project-link \
  --data-dir "$PWD/.local/project-link-check-NEW" \
  --integration-repo "$PWD" \
  --integration-image "$PWD/docs/screenshots/composer-preview.png"
```

Inspect `integration-result.json`, the runtime's `thread/read`, and the desktop sidebar listing separately. The test stops at a question; publishing is disabled by its empty validation command and automatic merge is off.

## Native previews

These use synthetic sample observations, not user screen content.

![Capture and annotation editor](screenshots/composer-preview.png)

[Queue preview](screenshots/queue-preview.png)

## Reproduce

```sh
bash scripts/test.sh
python3 scripts/test_plugin.py
bash scripts/build.sh
build/DerivedData/Build/Products/Debug/ScreenClip.app/Contents/MacOS/ScreenClip --render-preview --data-dir "$PWD/.local/preview-new"
```

Use a new preview data directory for clean fixtures. Preview mode pauses processing and does not send images to AI. The native app needs access to the WindowServer to render; a restricted terminal sandbox may require running it normally from Finder.

For a live read-only handshake, use `scripts/probe_codex.py --codex /path/to/codex`. The `ScreenClipProbe` executable exercises two model turns with a supplied synthetic image and disposable repository. It creates one local Codex chat and consumes normal account usage.

The GitHub fixture setup helper requires an explicit `OWNER/screenclip-integration-*` name and creates a private repository. `ScreenClip --integration-run` also requires a dedicated fixture path, synthetic image path, and fresh data directory. It intentionally performs real PR and merge operations in that fixture. See the helper's `--help`; do not use production repositories for this diagnostic mode.

## Remaining hands-on and distribution checks

- Basic screen permission, region selection, annotation, submission, and grant retention after the installed update are confirmed. Debug/Release designated requirements also match. Verify the intended crop of each ScreenClip surface with hiding both on and off.
- Verify capture on each physical monitor, mixed scales, negative display origins, full-screen Spaces, transient menus, Escape, and return-to-source focus. Selection currently stays on the display where dragging starts; a rectangle spanning two displays is not implemented.
- Browser URL access, denied/revoked permissions, notifications, login-item registration, and keyboard conflicts need a hands-on check under the app's permissions.
- The desktop app recognizes external chats, but bidirectional handoff while independent Codex processes are simultaneously active has not been established. Use one agent owner per worktree; cancel native work before taking over in another client. The app checks saved history during explicit reconciliation.
- Only the development runtime and host above have been exercised. A separately installed supported Codex CLI, older macOS versions, Intel, and clean second-machine installation remain compatibility checks.
- Local builds can use an ignored certificate configuration; this Mac has an installed Apple Development identity. Developer ID release signing and notarization were not performed. Packaging supports supplied signing/notary credentials. Automatic app updates are not implemented.
- The plugin's stdio behavior is tested; public-directory submission and install eligibility are not established. The core app does not depend on that plugin.

## Useful implementation locations

- `Sources/ScreenClip/`: native app, capture, annotation editor, queue/settings, and worker.
- `Sources/ScreenClipCore/`: durable model/store, routing, transport, Git and GitHub integration, and merge policy.
- `Sources/ScreenClipCore/CodexClient.swift`, `ClaudeCodeClient.swift`, `AgentDetector.swift`: agent transports and detection. See [Coding agents](agents/README.md).
- `plugins/screenclip/`: optional local read-only MCP bridge, packaged for Codex and Claude Code.
- `scripts/`: app builds, packaging, probes, fixtures, and plugin tests.
