# ScreenClip

A macOS menu bar utility for capturing feedback as you notice it, without interrupting what you are doing.

The main value is keeping your flow: notice a tiny layout issue, confusing label, missing detail, or improvement; capture it in a few moments; then keep going. ScreenClip should make it practical to collect dozens or hundreds of small observations across a session, rather than stopping to write a formal bug report or losing the details before you finish.

Press a global shortcut, select a screen region, optionally write a short note or annotate the image, and submit. ScreenClip preserves the context so you do not have to reconstruct it later. Codex pickup and progress, questions, pull requests, and results extend that capture workflow; an automatic fix is a downstream benefit, not the primary product promise.

## Agreed direction

- macOS only; support testing both websites and native Mac apps.
- Lead with quick, low-friction feedback capture and returning to the task at hand. Support many small observations in one session; do not require every capture to become a formal bug report.
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

Copy `Config/LocalSigning.xcconfig.example` to `Config/LocalSigning.xcconfig` and set your Apple Development certificate and team. This ignored file configures both Xcode and Terminal builds. Ad-hoc signing changes the application's identity when its executable changes and can invalidate a previous permission grant. A checkout can build ad-hoc for CI, but local installation requires a certificate.

Open **ScreenClip.xcodeproj**, select **ScreenClip → My Mac**, then press **⌘R**. The shared scheme builds the native app, installs it at **`/Applications/ScreenClip.app`**, and runs/debugs that installed copy. Its Run pre-action stages and verifies the signed app, asks existing copies to quit, and replaces the installed bundle only after they exit. Save an open capture and finish or cancel active work before installing an update. Command-B builds without installing or launching.

Normal use always launches the Applications copy. The bundle ID and signing certificate stay stable, while the queue remains in Application Support. The core library and command-line tests remain a local Swift package.

### From Terminal

```sh
bash scripts/run.sh
```

This uses the same Xcode project, installs the app in Applications, and opens it. `bash scripts/build.sh [debug|release]` only builds; the product is under `build/DerivedData/Build/Products/Debug` or `Release`. The initial global shortcut is **⌘⇧2**. Configure another shortcut in Settings if that combination is taken.

1. Open Settings → Projects. Add a Git repository, its base branch, website URLs or native bundle IDs, and a validation command.
2. In Connections, check Codex and GitHub sign-in. ScreenClip checks for an existing Codex session automatically and reuses it. Sign in opens a browser only when a new login is needed; Other sign-in options offers a code-based flow. Pending logins can be canceled and failures are shown directly in Settings. A working desktop-bundled Codex runtime is detected as a development fallback; a separately installed supported CLI is preferred for distribution.
3. Enable browser URL context if desired. Safari/Chrome Automation access is optional; without it, choose the project when inference is unavailable.
4. Press the shortcut. Grant macOS Screen Recording permission on first capture, select a region, annotate or describe it, and Submit.

The editor appears immediately after selection. Draw freehand, add an arrow, rectangle, circle/ellipse or text, choose a color and thin/medium/bold stroke, and undo/redo before submitting. Redaction always produces an opaque black block.

**Settings → General → Capture → Hide ScreenClip during capture** controls whether the shortcut hides ScreenClip's windows/popover and excludes them from the captured image. It is off by default, so you can report bugs in ScreenClip itself. Turn it on and Save settings when you want ScreenClip hidden. Capturing its open menu bar popover identifies ScreenClip as the source app.

If System Settings shows access enabled but capture still fails, use **Check screen access** in General settings. ScreenClip tries ScreenCaptureKit even when the older preflight check says no, and rechecks after returning from System Settings following a denial. The permission banner also offers Settings, Check again, and Reopen app. If a previous ad-hoc build left an unusable permission entry, quit ScreenClip, run `tccutil reset ScreenCapture com.screenclip.app`, reopen `/Applications/ScreenClip.app`, invoke capture and grant access again. This targeted reset affects only ScreenClip's screen-capture approval and is a repair step, not part of ordinary installation. Capture diagnostics are written to `~/Library/Application Support/ScreenClip/capture-diagnostics.log` and include build/API error metadata, without screenshots, notes, browser URLs, or window titles.

Captures save locally before dispatch. Related images share an issue and Codex chat. A fix runs in its own worktree, passes the configured validation, and opens a GitHub PR. Automatic merge requires passing CI, satisfied host policies, the validated PR head, and the current input revision. ScreenClip makes up to two repair attempts for failing checks, then requests input. Merged fixes appear under **To retest**.

Keep ScreenClip running and the Mac awake for local work. Use ScreenClip's reply controls for active jobs. Cancel an issue before taking over its worktree in another coding client; simultaneous editing from separate Codex processes is not coordinated automatically.

After an interrupted run, **Reconcile chat** recovers a completed structured fix and independently validates it before publication. Continue reuses a chat already owned by ScreenClip and restores an archived chat when necessary. `--recover-reports` reconciles the saved reports and continues those without unanswered questions. PR details retain the link and confirmed merge commit; **Refresh PR status** updates checks immediately.

## Validation and delivery

```sh
bash scripts/test.sh
python3 scripts/test_plugin.py
bash scripts/package.sh
```

Packaging uses the Xcode Release build and writes `build/ScreenClip-macOS.zip`. The built bundle is `build/DerivedData/Build/Products/Release/ScreenClip.app`. Local builds use the ignored local signing configuration when provided, otherwise ad-hoc signing for build-only checks. `SCREENCLIP_SIGNING_IDENTITY` overrides the local configuration. For a public release, supply a Developer ID signing identity and a preconfigured Keychain `SCREENCLIP_NOTARY_PROFILE` before running the packaging script. An Apple Development signature is for local testing and does not replace public notarization. No third-party runtime is redistributed.

The optional [Codex MCP plugin](plugins/screenclip/README.md) exposes the local queue and approved images for inspection. It is not needed for automatic pickup.

See [validation evidence and current limits](docs/validation.md) for the live Codex and GitHub checks, native previews, and remaining manual verification. This is a working local app, not yet a publicly notarized release.
