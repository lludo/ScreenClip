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

Requires macOS 14+, Xcode with Swift 6, a working Codex CLI with `app-server`, and GitHub CLI for PR automation. The build has no external Swift package dependencies.

```sh
bash scripts/build.sh
open build/ScreenClip.app
```

The app lives in the menu bar. The initial global shortcut is **⌘⇧2**. Configure another shortcut in Settings if that combination is taken.

1. Open Settings → Projects. Add a Git repository, its base branch, website URLs or native bundle IDs, and a validation command.
2. In Connections, check Codex and GitHub sign-in. A working desktop-bundled Codex runtime is detected as a development fallback; a separately installed supported CLI is preferred for distribution.
3. Enable browser URL context if desired. Safari/Chrome Automation access is optional; without it, choose the project when inference is unavailable.
4. Press the shortcut. Grant macOS Screen Recording permission on first capture, select a region, annotate or describe it, and Submit.

Captures save locally before dispatch. Related images share an issue and Codex chat. A fix runs in its own worktree, passes the configured validation, and opens a GitHub PR. Automatic merge requires passing CI, satisfied host policies, the validated PR head, and the current input revision. ScreenClip makes up to two repair attempts for failing checks, then requests input. Merged fixes appear under **To retest**.

Keep ScreenClip running and the Mac awake for local work. Use ScreenClip's reply controls for active jobs. Cancel an issue before taking over its worktree in another coding client; simultaneous editing from separate Codex processes is not coordinated automatically.

## Validation and delivery

```sh
bash scripts/test.sh
python3 scripts/test_plugin.py
bash scripts/package.sh
```

The ZIP and app bundle are written to `build/`. Local builds are ad-hoc signed. To produce a signed/notarized release, set `SCREENCLIP_SIGNING_IDENTITY` and a preconfigured Keychain `SCREENCLIP_NOTARY_PROFILE` before running the packaging script. No third-party runtime is redistributed.

The optional [Codex MCP plugin](plugins/screenclip/README.md) exposes the local queue and approved images for inspection. It is not needed for automatic pickup.

See [validation evidence and current limits](docs/validation.md) for the live Codex and GitHub checks, native previews, and remaining manual verification. This is a working local app, not yet a publicly notarized release.
