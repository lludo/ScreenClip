# ScreenClip validation

Updated: November 15, 2026. Development host: macOS 27.0.1, Xcode 27.2, Swift 6.4.2, Apple Silicon.

This page records what is verified and how. What is still open is in the [roadmap](roadmap.md#open-gates). The macOS CI job that runs these checks is in [Development](development.md#ci).

## Current status

The checks below describe the coverage and the live verification completed on the development host as of the date above. Run the commands under [Reproduce](#reproduce) for current results. CI runs the catalog check, the Swift and Python suites, the sandbox diagnostic, the website build, and the Xcode Debug and Release builds. The step list is in [Development](development.md#macos-build-and-tests).

| Area | Automated | Hands-on or live | Not yet verified |
| --- | --- | --- | --- |
| Capture and markup | Annotation pixels (orientation, ellipse, pen width, opaque redaction); style round-trip; four permission regressions | Region capture → markup → submit on this Mac, from the signed app in Applications, with permission retained across an installed update | Multiple monitors and scales, Spaces, transient menus, every ScreenClip surface with hiding on and off |
| Queue and store | Persistence, single writer, report numbers (legacy migration, no reuse), drafts, related captures, archive rules, delete rules, feedback search, badge counts, export | Installed updates kept both projects and all reports | Downgrade to an older build (see store versioning in the roadmap) |
| Routing | Ambiguity, URL boundaries, most-specific website rule, case-insensitive schemes | — | Browser URL permission prompts |
| Codex | JSON-RPC correlation and timeouts, questions and replies in one thread, cancellation during project lookup and before turn acknowledgement, authentication (nine regressions) | A synthetic fix through validation, GitHub CI, PR, and confirmed merge in a private fixture; restart and resume in the same chat | Desktop sidebar grouping fails; see below |
| Claude Code | Fake-CLI client and worker tests: arguments, evidence input, progress, structured and fenced results, usage, failures, cancellation, missing sessions, timeouts are wired, detection, holding work while signed out | The installed CLI (2.1.128) has every flag and sandbox setting used; plugin manifests pass `claude plugin validate` | A live fix through PR and merge; permanent plugin installation; an interactive plugin fix |
| Grok Bot | `ExternalAssistantTests`: payload encoding, slug and branch names, always-enabled screenshot sharing, idempotent retry, pull-request matching, the `.screenclip/` merge guard, detection, the Authorization header on a test POST (line breaks rejected, removed on a cross-host redirect), Keychain update in place. `ExternalAssistantAppTests`: stays in the agent list, submit refused until configured, a restart during the POST stays retryable | — | A live webhook, an evidence push to a real repository, pull-request discovery, and auto-merge while `.screenclip/` is still present; see [Grok Bot](agents/external-assistant.md#verification-status) |
| Git and GitHub safety | Changed-source rejection, stale head and revision merge rejection, worktree from `origin/<base>` excludes unpushed commits, worktree cleanup, GitHub remote parsing, PR body redaction | Fixes published and merged through GitHub PRs | — |
| Process handling | A background grandchild holding the pipe cannot hang a command; a timeout terminates the whole process tree; agents get no GitHub tokens | — | — |
| Plugin and scripts | MCP server: approved images only, private fields excluded, invalid arguments and malformed requests answered with errors; queue review: read-only access, searches, archive eligibility | — | Public directory submission |

## Before / After PR evidence

`PRScreenshotEvidenceTests` covers flattened Before image copying, ignored PNG staging, immutable commit URLs and URL encoding, missing/invalid After rejection, revision isolation, and symbolic-link rejection. `PRScreenshotPublishingTests` verifies missing evidence schedules a repair before publication. `PromptEfficiencyTests` checks that first and resumed prompts carry the authorized screenshot contract.

The opt-in live test invokes the native worker's completed-result, validation, publish, follow-up, and auto-merge paths against a dedicated private repository. It renders a real native purchase-button view at 80px and 240px without accessing the screen, verifies Before/After bytes through GitHub's contents API, checks that a follow-up refreshes the same PR's description, and verifies evidence remains accessible after merge. No LLM is called by this test. Run with `SCREENCLIP_SCREENSHOT_LIVE_REPO=/path/to/screenclip-integration-* bash scripts/test.sh --filter PRScreenshotPublishingTests.testLiveWorkerPublishesUpdatesAndMergesScreenshots`. The fixture must have an initial commit and GitHub origin; it must not contain real user data. `SCREENCLIP_SETTINGS_SNAPSHOT=/absolute/output.png` enables the separate project-settings render for visual review.

Live verification on November 15 passed in [synthetic fixture PR #2](https://github.com/lludo/screenclip-integration-screenshots-20261115/pull/2): original and follow-up evidence uploaded, exact hosted bytes matched, the native worker auto-merged, and both images rendered in Safari after branch deletion. GitHub's status recorded the successful local checks; no paid Actions workflow was needed. Final local checks passed: 203 native tests (three optional tests skipped), 14 plugin tests, five queue tests, webhook checks, localization catalogs, and Debug/Release builds with signature verification. The project-settings comparison uses synthetic data: [Before](screenshots/pr-screenshots-settings-before.png) / [After](screenshots/pr-screenshots-settings-after.png).

## Code and documentation review — November 15

The review covered the queue/store, agent protocols and scheduling, publication and merge guards, capture/UI paths, plugin and build scripts, website build, and documentation links. Fixes reject fractional or out-of-range protocol integers, require a real boolean before the plugin includes screenshots, preserve SQLite read failures, and enforce the store's read-only mode for capture deletion. Codex request classification is shared by response handling, recovery, and the question UI. Relaunch also reconciles acknowledged interrupted Codex work in automatic mode, without replaying uncertain dispatches or answering genuine questions. Regressions cover these failure cases and retain the typed user-input answer format. Permission, recovery, routing, provider-data handling, and release documentation now reflect the owning code; the implemented per-project agent default was removed from the feature backlog. Local verification passed: 196 Swift tests with zero failures (two optional rendering tests skipped), 14 plugin tests, queue and webhook checks, website build and locale checks, localization catalogs, documentation link targets, and Xcode Debug and signed Release builds.

## Repository association review

The reviewed Release app was installed in Applications, its signature and executable were checked against the build, and the relaunched queue was inspected. Existing reports whose chats were held by other live Codex clients remained blocked by runtime writer ownership. Process-parent inspection distinguished those clients from ScreenClip's own server; no foreign client was stopped. This handoff limitation is tracked in the [maintenance backlog](roadmap.md#maintenance-backlog).

November 15 follow-up: the desktop's supported `move_thread_to_project` tool was attempted for report #36, whose thread is visible in Recents and whose prompt identifies the Genealogy repository. It refused with “The task's source project could not be safely determined.” The desktop also disallows computer-use access to its own UI. No assignment or migration state was edited. The permission-mode change is independent of this unresolved sidebar defect: project-specific permissions are sent directly on each worker turn, and repository instructions are read from its worktree.

Permission-mode verification on November 15 used the installed runtime with a fresh temporary `CODEX_HOME`, a synthetic directory, and ephemeral threads. All three modes read back with the expected approval policy, reviewer, and sandbox; no model turns or live queue/Codex state were used. Worker regressions cover the live one-click action, unsupported runtimes, switching from full access back to manual approval in an owned chat, recovery of stale approval requests, preserving real questions, refusing active chats, and cancellation during reconciliation. The complete standard Swift suite and Python checks passed locally, native permission controls were rendered for inspection, and a signed Release build passed code-signature verification. This does not establish that every command requiring extra access will be allowed: automatic review can refuse an operation, and managed policies still apply.

A synthetic run confirmed repository context, worktree isolation, and runtime project association, but the chat appeared ungrouped in the desktop sidebar on the tested Codex version. Runtime association and desktop sidebar placement are separate checks; a successful app-server response does not establish the latter. **Open in Codex** provides an exact chat link.

A follow-up probe started a read-only chat with the repository as its initial directory, then used app-server's per-turn `cwd` override to work in a separate directory. The desktop listed the chat without a project and recorded the turn directory as its `cwd`. Continuing the same chat from the repository did not assign it to the desktop project, and the desktop move operation reported that the test chat was not available in the sidebar. The test chat was archived. This does not establish a reliable project association or justify changing worktree isolation.

An additional read-only inspection of the installed Codex desktop found an incomplete project-assignment migration: at the time, 85 pending entries comprised 79 archived and 6 active chats, all with the `vscode` source. Of those, 64 referenced missing rollout files. Codex doctor reported healthy databases and warned about missing or unusable rollout files. The desktop's migration code scans non-archived chats; these observations suggest possible reasons for the backlog but do not prove why the migration is incomplete. Sample ScreenClip chats had runtime project IDs but no desktop assignment, and were not in that pending set. No supported repair was identified, and neither migration state nor Codex databases were edited.

A subsequent read-only app-server probe found all six then-pending active chats in the default interactive thread list, and `thread/read` returned each of them. Their legacy project registrations and legacy-to-runtime mappings were present. Thus the earlier missing-rollout warning alone does not explain why the active entries remain pending. The pending count changed while observing it, so a snapshot-based checkpoint rewrite could discard concurrent updates. This probe did not run the desktop migration against a copied state or establish a repair.

An isolated follow-up executed the installed desktop migration class against synthetic data and an anonymized snapshot of local assignment metadata, with a mocked app-server and no changes to live Codex state. Under simulated successful responses, the checkpoint completed even with archived entries remaining; when an update was made to fail, the checkpoint stayed incomplete while other operations in the concurrent batch could already have applied. This shows that archived pending entries alone do not necessarily block completion, and that a failed run can be partially applied. The mock assumed successful responses and did not run an actual desktop or validate a live repair.

A later probe used an isolated SQLite backup and copies of available rollout files with the installed real Codex app-server, with every rollout path redirected to the temporary copy. Ten active desktop assignments, including all seven then-pending active assignments, accepted `thread/metadata/update` and read back with the expected runtime project ID. The test did not run the desktop migration or access the live database for writes. It does not identify why the desktop migration remains incomplete or establish a live repair.

A current-runtime probe (November 14, 2026) used the `codex-cli` 0.169.0-alpha.11.1 bundled in ChatGPT.app, which now hosts the desktop, with a throwaway `CODEX_HOME` and synthetic repositories only. With `--experimental`, its app-server schema lists `project/list`, `project/read`, `project/create`, `project/import` (with an optional thread list and an idempotency key), `project/update`, `project/move`, `project/delete`, and a `thread/project/updated` notification. `project/create` for a repository root followed by `thread/start` with that `projectId` and a separate worktree `cwd` returned a thread whose `projectId` matched; a thread started without `projectId` had `projectId: null`, so the runtime does not infer a project from the root. This confirms runtime association on the current runtime only. It does not show that the desktop sidebar reads these projects, and the live Codex state and migration checkpoint were not touched.

A read-only look at a scratch copy of the desktop's bundled JavaScript (ChatGPT.app 26.1111.21308; the live app and its state were not touched) found how the desktop picks up chats that something else assigned to a runtime project. Legacy projects are imported with `project/import`, using the legacy ID as the idempotency key, and the mapping is kept in desktop state. The desktop learns of a chat's project by reading `thread.projectId` (`thread/read`), mapping it back to a local project, and recording it in its own `THREAD_PROJECT_ASSIGNMENTS`. For threads it sees live, that step is skipped unless the saved migration state has `threadAssignmentsMigrated` set to true and the thread is not in `pendingThreadAssignmentIds`. The migration pass that does read every listed chat (`thread/list`, then `thread/read`) uses `Promise.allSettled` and rethrows the first rejection, which would stop it before later pages and leave the checkpoint incomplete. So the code is consistent with the observed behaviour: ScreenClip's runtime assignment is correct, but while the checkpoint is incomplete (or a pass fails), the desktop never adopts it. This is a reading of the code, not a reproduction. The desktop logs show only "project migration completed" lines and no thread-assignment errors, so I did not see the failing step. The supported route would be the desktop finishing its own migration, for example after an app update. Nothing available from ScreenClip changes the desktop's state, and the checkpoint was deliberately not edited.

To repeat it (creates a synthetic Codex chat and uses normal account usage):

```sh
/Applications/ScreenClip.app/Contents/MacOS/ScreenClip \
  --integration-project-link \
  --data-dir "$PWD/.local/project-link-check-NEW" \
  --integration-repo "$PWD" \
  --integration-image "$PWD/docs/screenshots/composer-preview.png"
```

Inspect `integration-result.json`, the runtime's `thread/read`, and the desktop sidebar listing separately. The test stops at a question; publishing is disabled by its empty validation command and automatic merge is off.

## Reproduce

Run the suites listed under [Development](development.md#build-and-test-locally). To render native previews with synthetic data:

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
