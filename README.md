# ScreenClip

A macOS menu bar utility for turning observations made while testing an app into actionable AI work.

Press a global shortcut, select a screen region, write a short note or annotate the image, and submit. ScreenClip preserves the testing context, starts Codex on the issue, and shows progress, questions, pull requests, and results from the menu bar.

## Agreed direction

- macOS only; support testing both websites and native Mac apps.
- Start work immediately after submission.
- Keep one Codex chat per issue; attach related screenshots and follow-ups to that issue.
- Infer the project from the app or browser context, with a visible correction control.
- Implement, test, open a PR, and merge automatically when the project's checks and policies pass.
- Design for eventual public distribution, beginning with a working version on the developer's Mac.
- Investigate a Codex plugin as a companion to the native app.

## Documentation

- [Product specification](docs/product-spec.md): workflow, screens, status meanings, scope, and remaining questions.
- [Technical design](docs/technical-design.md): native components, Codex integration, plugin options, storage, and constraints.
- [Implementation plan](docs/implementation-plan.md): feasibility gates, build sequence, and acceptance criteria.

## Build and run

Requires macOS 14+, Xcode 16 or newer with Swift 6, a working Codex CLI with `app-server`, and GitHub CLI for PR automation. The build has no external Swift package dependencies.

### In Xcode

Open **ScreenClip.xcodeproj**, select the **ScreenClip** scheme and **My Mac**, then press **⌘R**. The shared scheme builds a real macOS app with its Info.plist, permission descriptions, entitlements, and icon. It uses local ad-hoc signing, so no paid developer account is required for local development.

Quit an already running copy of ScreenClip before Run; both copies use the same local queue. The app appears in the menu bar and opens its queue when run from Xcode. Its core library is a local Swift package shared with the command-line tests.

For stable Screen Recording permissions across rebuilds, copy `Config/LocalSigning.xcconfig.example` to `Config/LocalSigning.xcconfig` and set your Apple Development certificate and team. This ignored local file configures both Xcode and the Terminal build. Ad-hoc signing changes the application's identity when its executable changes and can invalidate a previous permission grant.

### From Terminal

```sh
bash scripts/build.sh
open build/ScreenClip.app
```

The app lives in the menu bar. The initial global shortcut is **⌘⇧2**. Configure another shortcut in Settings if that combination is taken.

**Hide ScreenClip during capture** is enabled by default in Settings → General. Turn it off to include ScreenClip's own windows in a capture.

1. Open Settings → Projects. Add a Git repository, its base branch, website URLs or native bundle IDs, and a validation command.
2. In Connections, check Codex and GitHub sign-in. ScreenClip checks for an existing Codex session automatically and reuses it. Sign in opens a browser only when a new login is needed; Other sign-in options offers a code-based flow. Pending logins can be canceled and failures are shown directly in Settings. A working desktop-bundled Codex runtime is detected as a development fallback; a separately installed supported CLI is preferred for distribution.
3. Enable browser URL context if desired. Safari/Chrome Automation access is optional; without it, choose the project when inference is unavailable.
4. Press the shortcut. Grant macOS Screen Recording permission on first capture, select a region, annotate or describe it, and Submit.

The editor appears immediately after selection. Draw freehand, add an arrow, rectangle, circle/ellipse or text, choose a color and thin/medium/bold stroke, and undo/redo before submitting. Redaction always produces an opaque black block.

If System Settings shows access enabled but capture still fails, use **Check screen access** in General settings. ScreenClip tries ScreenCaptureKit even when the older preflight check says no, and rechecks after returning from System Settings following a denial. The permission banner also offers Settings, Check again, and Reopen app. Reopen after rebuilding a running copy; the Terminal build refuses to replace its running app. Capture diagnostics are written to `~/Library/Application Support/ScreenClip/capture-diagnostics.log` and include build/API error metadata, without screenshots, notes, browser URLs, or window titles.

Captures save locally before dispatch. Related images share an issue and Codex chat. A fix runs in its own worktree, passes the configured validation, and opens a GitHub PR. Automatic merge requires passing CI, satisfied host policies, the validated PR head, and the current input revision. ScreenClip makes up to two repair attempts for failing checks, then requests input. Merged fixes appear under **To retest**.

Keep ScreenClip running and the Mac awake for local work. Use ScreenClip's reply controls for active jobs. Cancel an issue before taking over its worktree in another coding client; simultaneous editing from separate Codex processes is not coordinated automatically.

## Validation and delivery

```sh
bash scripts/test.sh
python3 scripts/test_plugin.py
bash scripts/package.sh
```

The ZIP and app bundle are written to `build/`. Local builds use the ignored local signing configuration when provided, otherwise ad-hoc signing. `SCREENCLIP_SIGNING_IDENTITY` overrides the local configuration. For a public release, supply a Developer ID signing identity and a preconfigured Keychain `SCREENCLIP_NOTARY_PROFILE` before running the packaging script. An Apple Development signature is for local testing and does not replace public notarization. No third-party runtime is redistributed.

The optional [Codex MCP plugin](plugins/screenclip/README.md) exposes the local queue and approved images for inspection. It is not needed for automatic pickup.

See [validation evidence and current limits](docs/validation.md) for the live Codex and GitHub checks, native previews, and remaining manual verification. This is a working local app, not yet a publicly notarized release.
