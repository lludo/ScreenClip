# ScreenClip validation

November 13, 2026. Development host: macOS 27.0.1, Xcode 27.2, Swift 6.4.2, Apple Silicon.

## Verified

The final run passed **20 Swift tests and 4 Python plugin tests**. The release app's ad-hoc signature and Info.plist also passed verification.

- Native Swift executable and app bundle build without third-party package dependencies.
- Automated tests cover persistence and asset export, single-writer ownership, project ambiguity and URL boundaries, badge counts, grouped input revisions, draft submission, worktree recovery and preservation of dirty source checkouts, JSON-RPC correlation/timeouts, changed-source validation rejection, stale-head/revision merge rejection, and native worker questions/replies.
- Pixel tests verify image orientation and opaque redaction in the exported PNG.
- Synthetic native queue/composer/settings previews are rendered and inspected; no user screen content is used in those previews.
- Optional MCP bridge tests cover approved-image retrieval, status filtering, excluded private fields, and rejection of image paths outside the asset directory.
- Codex `initialize`, account and model discovery passed with runtime `0.169.0-alpha.11.1` using the existing ChatGPT sign-in. No credentials were copied into this repository.
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
build/ScreenClip.app/Contents/MacOS/ScreenClip --render-preview --data-dir "$PWD/.local/preview-new"
```

Use a new preview data directory for clean fixtures. Preview mode pauses processing and does not send images to AI. The native app needs access to the WindowServer to render; a restricted terminal sandbox may require running it normally from Finder.

For a live read-only handshake, use `scripts/probe_codex.py --codex /path/to/codex`. The `ScreenClipProbe` executable exercises two model turns with a supplied synthetic image and disposable repository. It creates one local Codex chat and consumes normal account usage.

The GitHub fixture setup helper requires an explicit `OWNER/screenclip-integration-*` name and creates a private repository. `ScreenClip --integration-run` also requires a dedicated fixture path, synthetic image path, and fresh data directory. It intentionally performs real PR and merge operations in that fixture. See the helper's `--help`; do not use production repositories for this diagnostic mode.

## Remaining hands-on and distribution checks

- Screen Recording must be granted to ScreenClip by macOS. The user-driven drag/selection flow has not yet been exercised with that grant on this Mac.
- Verify capture on each physical monitor, mixed scales, negative display origins, full-screen Spaces, transient menus, Escape, and return-to-source focus. Selection currently stays on the display where dragging starts; a rectangle spanning two displays is not implemented.
- Browser URL access, denied/revoked permissions, notifications, login-item registration, and keyboard conflicts need a hands-on check under the app's permissions.
- The desktop app recognizes external chats, but bidirectional handoff while independent Codex processes are simultaneously active has not been established. Use one agent owner per worktree; cancel native work before taking over in another client. The app checks saved history during explicit reconciliation.
- Only the development runtime and host above have been exercised. A separately installed supported Codex CLI, older macOS versions, Intel, and clean second-machine installation remain compatibility checks.
- Local builds are ad-hoc signed. Developer ID signing and notarization were not performed because no signing identity is installed. Packaging supports supplied signing/notary credentials. Automatic app updates are not implemented.
- The plugin's stdio behavior is tested; public-directory submission and install eligibility are not established. The core app does not depend on that plugin.

## Useful implementation locations

- `Sources/ScreenClip/`: native app, capture, annotation editor, queue/settings, and worker.
- `Sources/ScreenClipCore/`: durable model/store, routing, transport, Git and GitHub integration, and merge policy.
- `plugins/screenclip/`: optional local read-only MCP bridge.
- `scripts/`: app builds, packaging, probes, fixtures, and plugin tests.
