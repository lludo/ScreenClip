# ScreenClip validation

November 13, 2026. Development host: macOS 27.0.1, Xcode 27.2, Swift 6.4.2, Apple Silicon.

## Verified

The current run passed **37 Swift tests**; the unchanged plugin's **4 Python tests** passed in the preceding run. Xcode is now the app build path for development, Terminal and CI; SwiftPM runs the tests and supplies the core library. Xcode Debug and Release builds passed for 0.1.5. The app is installed at `/Applications/ScreenClip.app`, and the Release ZIP was regenerated. Both signatures passed strict verification and have matching designated requirements using the installed Apple Development certificate. Public Developer ID signing and notarization remain separate.

- Native Swift executable and app bundle build without third-party package dependencies.
- The native `ScreenClip.xcodeproj` shared scheme builds and development-signs the app for My Mac (Apple Silicon). Run has an install pre-action and launches `/Applications/ScreenClip.app`; the XML wiring and installer were checked, while clicking Command-R in Xcode remains a manual check. `scripts/run.sh` uses the same Xcode project and installer. Installation rejects ad-hoc builds, stages/verifies before quitting existing copies, and does not touch Application Support. A checkout without the ignored local signing file still builds ad-hoc for CI. The core library remains a local package dependency; the command-line test suite uses Swift Package Manager.
- Automated tests cover persistence and asset export, single-writer ownership, project ambiguity and URL boundaries, badge counts, grouped input revisions, draft submission, worktree recovery and preservation of dirty source checkouts, JSON-RPC correlation/timeouts, changed-source validation rejection, stale-head/revision merge rejection, and native worker questions/replies.
- Pixel tests verify image orientation, ellipse color and clear interior, pen thickness, and opaque redaction regardless of selected color in the exported PNG. Style fields round-trip, and captures saved before those fields were introduced still decode.
- Four permission regressions cover successful real capture despite a false preflight hint, preserving actual denial and recovering on recheck, requiring reopen after executable replacement, and retaining non-permission errors accurately. Diagnostic events distinguish shortcut, access check, selection overlay, selected region, cancellation, and failure.
- Installation preserved two registered projects and the existing empty queue. Process inspection confirmed exactly one copy running, from Applications. The old hand-assembled bundle and previous diagnostic Xcode bundle were unregistered and removed. Future builds produce the ordinary Xcode product; normal runs use the installed copy.
- The initial signed development copy still received actual ScreenCaptureKit denial `-3801`. After installing in Applications and resetting only `ScreenCapture` for `com.screenclip.app` with `tccutil`, the user regranted access and reopened the app. The log recorded access available, one display's selection overlay, and a selected 270 × 247 region. The user confirmed the selector and supplied a screenshot of an annotated test report submitted and marked Working in the menu bar. Basic capture → markup → submit is now verified on this Mac.
- The overflow menu now hides its native chevron and gives the ellipsis a 28 × 24 point label; a synthetic native preview confirmed no collision. Preview rendering no longer registers the global capture shortcut while the installed app is running.
- **Hide ScreenClip during capture** is now off by default and available in General settings. Both window hiding and the screenshot filter follow the setting; the source app is ScreenClip when capturing its open popover. A regression checks older settings decode and both choices persist through SQLite. Installation of 0.1.5 preserved all queue contents, including the user's submitted test report. The new self-capture path still needs a hands-on capture of ScreenClip's own windows/popover.
- After installing 0.1.5 without resetting permissions, live diagnostics recorded two successful selections with `hideScreenClip=false`, sizes 1439 × 115 and 1038 × 957. Preflight and actual access both succeeded. This confirms permission retention after the installed update and successful selection with self-capture enabled; visual coverage of every ScreenClip surface remains a manual check.
- Synthetic native queue/composer/settings previews are rendered and inspected; no user screen content is used in those previews.
- Optional MCP bridge tests cover approved-image retrieval, status filtering, excluded private fields, and rejection of image paths outside the asset directory.
- Codex `initialize`, account and model discovery passed with runtime `0.169.0-alpha.11.1` using the existing ChatGPT sign-in. No credentials were copied into this repository.
- Authentication checks reuse existing ChatGPT/API-key sessions and providers that do not require OpenAI authentication. Nine regressions cover avoiding redundant browser login, missing account data, reported passkey failure, cancellation and stale callbacks, code-based fallback, missing callback timeout, failed browser launch, and recovering a session while a login is pending. Browser errors that never return to the local callback are bounded by a five-minute timeout; the user can cancel sooner. The fallback is tested against the runtime's generated contract, without signing the user out to test it live.
- A synthetic screenshot produced a question, then a reply after process restart/resume in the same chat. The desktop app's chat reader independently recognized the saved conversation and both completed turns. Test chat ID: `01a1d7aa-7bbc-7620-987b-f497c14f91e1`.
- The actual native worker completed a synthetic CSS bug through isolated editing, local validation, PR creation, passing GitHub CI, guarded merge, and confirmed merged state. [Private fixture PR](https://github.com/lludo/screenclip-integration-20261113/pull/1). Its Codex chat ID is `01a1d7b6-c810-7213-879d-51dd0dc111b6`.

The private fixture contains synthetic HTML/CSS and a regression test. It is retained as inspectable test evidence and contains no user screenshots. The ScreenClip source repository itself has no configured remote.

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
- `plugins/screenclip/`: optional local read-only MCP bridge.
- `scripts/`: app builds, packaging, probes, fixtures, and plugin tests.
