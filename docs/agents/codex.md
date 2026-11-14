# Codex

Updated: November 14, 2026. Part of [Coding agents](README.md), which describes the shared agent contract.

Codex was ScreenClip's first agent and is the default when no agent is chosen. ScreenClip keeps one long-lived `codex app-server --listen stdio://` process ([CodexClient.swift](../../Sources/ScreenClipCore/CodexClient.swift)) and one Codex thread per issue.

## At a glance

| Topic | Behavior |
| --- | --- |
| Executable | Settings → Connections → Codex. Detected from `/usr/local/bin/codex`, `/opt/homebrew/bin/codex`, or the ChatGPT app's bundled runtime (development fallback only, never redistributed). |
| Sign-in | Checked and started through app-server (`CodexAuthentication`). An existing Codex session is reused. |
| Turn | `thread/start` or `thread/resume` with `cwd` set to the worktree, `approvalPolicy: on-request`, `sandbox: workspace-write`, then `turn/start` with the prompt, images as data URLs, and `outputSchema`. |
| Questions | Typed user-input and approval requests from app-server appear under **Needs you** and are answered in ScreenClip. A structured `question` or `blocked` result also becomes **Needs you**. |
| Open the conversation | **Open in Codex** uses `codex://threads/<id>`. |
| Time limit | A turn still running after 45 minutes, not counting time waiting for your answer, is interrupted and the report fails. Continue resumes the same chat. |
| Recovery | **Reconcile chat** reads the thread and its latest turn, and can recover a completed `implemented` result, which is validated again before publication. **Link existing chat…** binds a thread whose `cwd` matches the worktree. |
| Usage | Not recorded yet. |
| Known gap | Desktop sidebar project membership. See [repository association review](../validation.md#repository-association-review). |


## What is documented

[Codex app-server](https://learn.chatgpt.com/docs/app-server) provides a local process interface with JSON-RPC messages over stdio. It supports starting/resuming threads and turns, local-image input, streamed events, interruption, and approval handling. Use stable capabilities first; typed user-question support must be checked against the chosen version because parts of that surface are experimental.

[Desktop deep links](https://learn.chatgpt.com/docs/app/commands#deep-links) include `codex://threads/<thread-id>` and new-chat links with a prompt and workspace path. A new-chat link prefills the composer; it is not documented as an automatic submit operation.

[Codex authentication](https://learn.chatgpt.com/docs/auth) supports ChatGPT sign-in and API-key access for local clients. Verify the intended worker's login and account capabilities; running the desktop app alone does not establish that another process is authenticated. Keep credentials under Codex's supported authentication flow.

## Adapter behavior

ScreenClip owns a long-lived local worker connection and an outbox. Each issue gets one persistent chat binding and a versioned input bundle containing the approved image, note, routing decision, relevant session context, tested-version evidence, and validation instructions.

The adapter keeps the issue worktree as `cwd` and separately assigns the chat to a saved Codex runtime project. It pages through `project/list`, matches the registered repository to canonical project root paths (including symlink resolution), and passes the unique matching `projectId` to `thread/start`. Resumed issue chats use `thread/metadata/update` to refresh that association. Names alone never select a project. Missing matches, unsupported APIs, ambiguous matches, and update failures record a deduplicated activity and allow work to continue. Every issue prompt identifies the original repository, isolated working directory, issue branch, and base branch. The installed runtime saves this assignment, but its project IDs currently differ from the desktop's saved-project IDs. Treat runtime association and desktop sidebar membership as separate checks; a successful API response does not establish the latter. The desktop move tool also rejected the synthetic worktree chat because its source project could not be safely determined.

Cancellation is checked again after project lookup before creating or resuming a chat. A canceled dispatch retains its issue/project slot until outstanding requests return, so an immediate retry cannot create a second chat or turn alongside it. If cancellation arrives while `turn/start` is awaiting acknowledgement, ScreenClip interrupts the returned turn as soon as its ID is known. Integration modes require an explicit fresh data directory. `--integration-project-link` runs the installed native worker with a synthetic observation that requests a question, empty publication validation, and automatic merge disabled, so project-association checks can use a real registered repository without requesting a code fix.

Serialize work on an individual issue. Append new evidence as a later turn, or use steering only after its semantics are tested. When the user continues work in Codex, observe and reconcile that activity; do not let two clients independently start competing turns.

Separate transport progress from product outcomes. Require a structured result containing the covered input revision, summary, validations, unresolved questions, branch, PR reference, and proposed next status. Verify PR/check/merge claims with the source-control host before promoting the state. A normal successful agent response alone is insufficient.

## Research and proposals

Pre-build research on desktop handoff requirements and Codex plugin options is kept in [proposals/codex-plugin.md](proposals/codex-plugin.md).
