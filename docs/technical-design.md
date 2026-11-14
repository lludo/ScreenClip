# ScreenClip technical design

Updated: November 14, 2026. The native app and local worker are implemented. The design below retains future options where identified; [validation evidence](validation.md) distinguishes verified behavior from remaining work.

## Implemented choices

The native app is built through the shared Xcode project/scheme, including from Terminal and CI. Swift Package Manager supplies its local core library and command-line tests. Normal runs install and launch `/Applications/ScreenClip.app`, preserving the bundle ID and development certificate across builds. Xcode Run and `scripts/run.sh` use the same installer: verify a certificate-signed staging bundle, ask running copies to quit, then replace the installed bundle with rollback on failure. Build-only output stays in DerivedData. A local ignored certificate configuration supplies development signing. The SQLite store persists a versioned snapshot containing projects, issues, ordered captures, activity, questions, and settings. Queued state acts as the durable outbox; dispatch uncertainty is persisted before external creation. A process file lock enforces a single writer, and recovery pauses interrupted work for reconciliation.

Each issue goes to a local coding agent, Codex or Claude Code, through the shared contract in [Coding agents](agents/README.md). Both have been exercised end to end with synthetic CLIs; a live Codex fix also completed through GitHub CI and a confirmed merge. Agent-specific behavior and known gaps, such as Codex desktop sidebar grouping, are on each agent's page.

The optional plugin is read-only (`list_issues`, `get_issue`), requires Python 3.9+, and is packaged for both Codex and Claude Code. Native dispatch and status writes have one owner. Plugin mutations/leases and shared desktop-process ownership remain future integrations. Reply in ScreenClip for app-owned runs; cancel before manually editing the same worktree in another client.

Each issue has an optional-on-decode `reportNumber`, assigned on store save and displayed as `#234`. A snapshot-level `nextReportNumber` is committed with the issues, so deletions cannot recycle a number. Legacy reads assign missing numbers in creation order with a UUID tie-breaker, retaining array order; the next writable save persists the migration. Saves preserve existing ID-to-number bindings and the stored high-water mark even if the caller passes a stale counter. The app publishes the numbered snapshot only after a successful save. Report numbers span all projects and include drafts; UUIDs remain the internal identity. Exact number searches include archived reports and bypass project/status filters. The read-only plugin exposes the number and accepts it in `get_issue.issue_id` alongside UUIDs.

## Recommended structure

The architecture serves the primary product goal: capture feedback as it is noticed and return the user to their current task. Capture persistence and return-to-app focus must not wait for agent work, a clarification, or PR automation. Repeated small captures should stay lightweight even while earlier observations are being processed. See the [product specification](product-spec.md#problem-and-intended-outcome) for the capture-first value proposition.

Build a native Swift application with SwiftUI for the composer and queue, AppKit for selection windows and focus behavior, a durable local store, and agent adapters. Keep the native capture experience independent of the particular agent handoff mechanism.

```mermaid
flowchart LR
    A[Global shortcut] --> B[Select screen region]
    B --> C[Note and annotation overlay]
    C --> D[Local issue store and outbox]
    D --> E[Dispatcher and agent adapter]
    E --> F[Isolated project worktree]
    F --> G[Tests and pull request]
    G --> H[Checks and merge]
    E --> I[Questions and progress]
    H --> I
    I --> J[Menu bar and issue detail]
    J --> K[Exact agent conversation]
    D -. read-only .-> L[Optional MCP plugin]
```

The diagram shows ownership: ScreenClip is the only writer of the store, and the plugin reads it.

## Native components

| Component | Responsibility |
| --- | --- |
| Menu bar | SwiftUI `MenuBarExtra`, with a queue window for longer interactions |
| Shortcut registration | System global hotkey registration, conflict detection, and a user-editable shortcut |
| Capture coordinator | AppKit overlays plus ScreenCaptureKit still-image capture |
| Composer | SwiftUI note/project controls and an annotation canvas; retain original image and editable marks |
| Context adapters | Source app/window identity; optional browser and build-context adapters |
| Issue store | SQLite metadata/event history and image files in Application Support |
| Dispatcher | Outbox delivery, issue ownership, retry, capacity, and worktree allocation |
| Agent adapters | Codex and Claude Code transport, conversation identity, progress, questions, cancellation, and recovery ([details](agents/README.md)) |
| Git provider adapter | PR identity, checks, mergeability, and confirmed merge state |

Apple documents menu bar utility support through [MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra) and still-image capture through [SCScreenshotManager](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager). The latter is available from macOS 14. Use the content-filter/configuration capture path for that baseline; availability-check newer convenience APIs.

Request screen-capture permission when the user first invokes capture, and provide a useful denied/revoked-permission state. Test full-screen Spaces, multiple displays with different scales and coordinate origins, keyboard cancellation, focus restoration, and exclusion of ScreenClip's own overlays from the result. Prototype frozen-frame selection so menus and transient UI do not change while the tester drags.

Permission availability is decided by the actual ScreenCaptureKit operation, rather than gating it on `CGPreflightScreenCaptureAccess`. A monitor distinguishes an actual macOS denial, an executable replaced since launch, and other capture errors. It can recheck on return from System Settings or on demand. Capture diagnostics record API error codes and build/event metadata in a bounded local log, without image content or captured source context. The bottom banner has a subtle border/shadow and permission recovery actions. Rebuilding a running bundle is refused by the Terminal builder. Use a stable development certificate for repeated local builds; [Apple DTS confirms](https://developer.apple.com/forums/thread/819406) that ad-hoc signatures change identity across rebuilds and can invalidate screen-capture permission.

The immediate composer supports freehand, arrows, rectangles, ellipses, text, and redaction, with per-mark color and normalized stroke width. Optional style fields preserve compatibility with previously saved captures. The same renderer draws the editing preview and exported image; redactions ignore the selected color and remain opaque black.

The **Hide ScreenClip during capture** preference is on by default. When off, capture keeps the queue/settings/popover visible and includes the app's windows in ScreenCaptureKit's filter, allowing reports about ScreenClip itself. Capturing its visible popover records ScreenClip as the source. When on, the shortcut closes/hides those surfaces and excludes ScreenClip windows. Selection overlays are created only after the frozen display images exist, so they never appear in either mode. The optional persisted preference also decodes older queues without a migration: missing values use the default, while explicit choices are preserved.

Capture only user-selected evidence. Hold temporary full-display selection backdrops in memory and discard them after capture/cancel. Never forward those backdrops as hidden context. Flatten opaque redactions into the submitted derivative before annotations. For a redacted capture, do not persist the unredacted crop at all. Unredacted captures can retain a local original for editing; submitted image inputs use the approved derivative. This avoids relying on read-root isolation that is unavailable in the development runtime's generated protocol.

## Project and context inference

Store explicit routing rules per registered project: native bundle IDs/build paths, web origins and path prefixes, local ports, and session overrides. Route from evidence captured before opening the overlay, then present the destination to the user.

Browser URL access needs an adapter and consent; it is not implied by having a screenshot. Evaluate browser automation permissions versus a small browser extension. Treat unavailable URLs and window titles as missing/weak evidence. OCR can suggest a destination but cannot authorize repository access. Use a session override until enough context exists for a reliable switch.

Use an explicit confidence/reason field rather than an unobservable guess. Never infer the repository from a generic browser bundle ID alone. A **Needs project** issue is a valid durable outcome when routing is ambiguous.

## Agent integrations

The capture pipeline is agent-neutral. The dispatcher prepares a worktree, sends one prompt with approved screenshots to the issue's agent, and receives a structured `implemented` / `question` / `blocked` result. ScreenClip then validates, publishes, and verifies merges itself. The shared contract, agent selection, readiness gating, and the checklist for adding an agent are in [Coding agents](agents/README.md). Each agent has its own page:

- [Codex](agents/codex.md): app-server transport, thread identity, desktop deep links, and project association.
- [Claude Code](agents/claude-code.md): headless stream-json turns, session identity, sandbox, sign-in, and the Claude Code plugin.
- Proposals: [Codex plugin research](agents/proposals/codex-plugin.md) and an [external assistant](agents/proposals/external-assistant.md) hand-off.

Serialize work on an individual issue. Append new evidence as a later turn. When the user continues work in the agent's own client, reconcile that activity; do not let two clients independently start competing turns. Separate transport progress from product outcomes, and verify PR, check, and merge claims with the source-control host before promoting the state. A normal successful agent response alone is insufficient.

## Local model and durable delivery

| Record | Key fields |
| --- | --- |
| Project | Local repo identity/path, Git remote, routing rules, target branch, validation/merge policy |
| TestingSession | Project, label, start/end, shared notes, tested build evidence |
| Issue | UUID, permanent local report number, project/session, title, lifecycle state, input revision, archive/read flags |
| Capture | Issue ID, sequence, note, asset references, immutable context snapshot |
| Asset | Original/approved derivative/thumbnail, hashes, dimensions, annotation document |
| AgentRun | Issue/revision, attempt ID, worker/chat/turn bindings, stage, timestamps, lease |
| QuestionReply | Issue/run, correlation ID, message, delivery/answer state |
| PullRequest | Run, host/repository, PR number/URL, head SHA, checks, merge commit |
| Event / Outbox | Event ID, issue revision, durable operation, attempt/acknowledgment state |

Write assets atomically before committing their references and outbox entry. Acknowledged submissions must survive app failure; clean up orphan assets on recovery. Preserve an editable annotation document alongside the flattened approved image.

Use at-least-once delivery with idempotent consumers. Persist an operation ID before starting external work; if a response is lost, reconcile against the external operation/chat/PR before retrying. When the external interface cannot prove whether creation succeeded, surface an uncertain operation instead of blindly creating another chat or PR.

The current in-app worker uses an exclusive process lock and one active job per issue, with revision checks. Recovery proceeds only after reconciling existing activity. It allows one active editing job per repository and parallelism across repositories; CI waits release editing capacity. New input invalidates completion for earlier revisions. Renewable leases and fencing would be required before introducing external queue writers or independent worker processes.

## Worktrees, checks, and automatic merge

Record the tested revision separately from the agent's base revision. Each issue run gets one worktree under Application Support and a `screenclip/<id>` branch (older issues keep their `codex/screenclip-<id>` branch). The branch starts from `origin/<base>` after a fetch when the repository has an origin, so a tester's unpushed or work-in-progress commits never enter a PR; without an origin it starts from the local base. The tester's checkout is never the working directory. After a confirmed merge, ScreenClip removes the worktree and local branch; a worktree with uncommitted changes is kept.

Validation runs the project's command in the worktree with a 10-minute limit, and the source fingerprint must be unchanged by it. Initialized submodules are fingerprinted by their checked-out commit; uninitialized ones by a fixed marker. All child processes run with git redirect variables (`GIT_DIR`, `GIT_WORK_TREE`, …) removed. A timed-out command has its whole process tree terminated, and output reading stops shortly after the command exits even if a background grandchild still holds the pipes. Coding agents additionally run without GitHub tokens in their environment; ScreenClip pushes and opens PRs itself. PR bodies redact `NAME=value` assignments and token-like strings from the validation command.

The user's chosen default authorizes automatic implementation, PR creation, and merge. Store that policy per project during onboarding. Merge only the current PR head after relevant validation and required host checks pass, required reviews are satisfied, no unresolved question blocks the fix, and no new capture revision is pending. Missing validation configuration is not equivalent to passing checks.

Serialize merges per repository. If the base branch changes, ScreenClip merges the latest base into the issue branch and revalidates before merging; a conflicting base merge is aborted and reported, so the worktree is never left mid-merge. Confirm the merge with the host, record the merge commit, and notify with retest instructions. Keep CI and deployment as distinct facts. Do not force-update the tester's checkout or restart their running app automatically.

## Distribution and lifecycle

Proposed first delivery is a signed, notarized direct-download app. Evaluate sandbox restrictions and child-process execution before choosing an App Store route. For public release, keep requiring an installed agent (Codex CLI or Claude Code) rather than bundling one; verify licensing, redistribution, updates, signatures, and a supported version range. Avoid depending on an undocumented binary inside another app's bundle.

The app must explain when work runs: the proposed local worker operates while ScreenClip is running and the Mac is awake. Closing the popover does not stop it; quitting and sleep have explicit recovery behavior. A login item is optional. A permanent launch agent or hosted worker is a later choice.

Keep captures in per-user Application Support, outside source repositories. Use Keychain for ScreenClip's own secrets and supported source-control authentication. Public PR content must not inherit private screenshots automatically. Deleting an issue locally must explain any independent retained agent history or PR; stop an active run before removing its working evidence.

## Source layout

| Path | Contents |
| --- | --- |
| `Sources/ScreenClip/` | The app: `AppModel`, capture (`CaptureCoordinator`, `Annotations`, `ComposerView`), queue (`QueueView`, `IssueDetailView`, `IssueRowViews`, `QuestionCard`, `WelcomeView`, `MenuPopover`), settings (`SettingsView`, `ConnectionControls`, `ProjectEditor`, `ShortcutRecorder`) |
| `Sources/ScreenClip/AgentWorker*.swift` | Scheduling and dispatch (`AgentWorker`), Codex (`+Codex`), Claude Code (`+Claude`), and validation, publication, PR monitoring, and merge (`+Publishing`) |
| `Sources/ScreenClip/AgentPrompt.swift` | The prompt and result schema every agent receives |
| `Sources/ScreenClipCore/` | Model (`Models`, `JSONValue`, `Errors`), store (`IssueStore`), routing (`Routing`), agent transports (`CodexClient`, `ClaudeCodeClient`, `AgentDetector`), processes (`CommandRunner`, `ProcessEnvironment`), Git (`GitWorkspace`), GitHub (`GitHubService`), and merge evidence (`MergeGuard`) |
| `plugins/screenclip/` | Read-only MCP server with Codex and Claude Code manifests |
| `scripts/` | Build, install, package, test, probes, fixtures, and the read-only queue review |
| `website/` | Static promotional site |
