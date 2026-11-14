# Coding agents

Updated: November 14, 2026.

ScreenClip captures an observation and hands it to a **local coding agent** that investigates and fixes it in an isolated Git worktree. The agent is pluggable. Today there are two:

| Agent | Transport | Conversation identity | Open the conversation | Sign-in | Page |
| --- | --- | --- | --- | --- | --- |
| Codex | `codex app-server` (long-lived JSON-RPC over stdio) | Codex thread ID | `codex://threads/<id>` | ChatGPT or API key through app-server | [codex.md](codex.md) |
| Claude Code | `claude -p` (one stream-json process per turn) | Session UUID chosen by ScreenClip | Copy `cd <worktree> && claude --resume <id>` | `claude auth login` in Terminal | [claude-code.md](claude-code.md) |

There is also a design proposal for handing reports to a remote assistant instead of a local agent: [proposals/external-assistant.md](proposals/external-assistant.md).

Separately from automatic dispatch, both agents can **read** the queue through the optional MCP plugin. See [the plugin README](../../plugins/screenclip/README.md).

## Choosing an agent

- **Default agent.** Settings → Connections → AI agent sets `AppSettings.defaultAgent`. Missing in older queues means Codex.
- **Per report.** The capture window's **Agent** picker starts at the default and can be changed for a new report or a draft. The choice is stamped on the issue (`Issue.agent`).
- **Follow-ups keep their agent.** Adding a capture to a submitted issue locks the picker to that issue's agent, because conversation IDs are not interchangeable between agents. Switching a submitted issue to another agent is not supported; cancel it and submit a new report.
- **Older issues** have no `agent` field and resolve to Codex (`Issue.resolvedAgent`).

## Detection and readiness

`AgentDetector` (in `ScreenClipCore`) finds each agent's executable, reads its version, and, where the agent supports it, its sign-in state. Detection runs at launch and from **Detect agents** in Settings.

- Pickers list installed agents plus the current default, so the default never disappears.
- The queue holds a queued issue whose agent detection reports missing or signed out (`AgentDetection.usable == false`). Detecting again resumes it. The capture window warns when the selected agent is not ready.
- The queue sidebar shows the default agent's status (`AppModel.agentStatus`).

## The agent contract

Every agent integration follows the same contract, so the rest of ScreenClip stays agent-neutral.

**ScreenClip provides**
- An isolated worktree and `screenclip/<id>` branch (`GitWorkspace.prepare`), started from `origin/<base>`, as the agent's working directory. The tester's checkout is never the working directory.
- One prompt per turn (`AgentPrompt.text`) with the issue, project, worktree, branch, validation command, capture context, user replies, and previous validation feedback. Notes, screenshot contents, titles, and URLs are labeled as untrusted evidence.
- The approved screenshots only (annotated, with redactions flattened), never unredacted originals.
- A JSON Schema for the result (`AgentPrompt.resultSchema`).
- An environment without GitHub tokens or git redirect variables (`ProcessEnvironment.agent`). Agents cannot push or open PRs with ScreenClip's credentials.

**The agent returns** one structured result per turn:

```json
{ "outcome": "implemented | question | blocked", "summary": "…", "question": "…" }
```

**ScreenClip owns everything after the result.** `finish` in [AgentWorker+Publishing.swift](../../Sources/ScreenClip/AgentWorker+Publishing.swift) turns `question` and `blocked` into **Needs you**. For `implemented`, it runs the project's validation, commits, pushes, opens the PR, watches checks, schedules up to two repair turns, and merges only after independently verifying the PR head, checks, reviews, and input revision. Agents are told not to commit, push, open PRs, or merge. Each integration also blocks those operations where the agent supports it.

**Conversation identity.** `Issue.threadID` holds the agent's conversation ID (a Codex thread or a Claude session UUID). Replies and new evidence continue the same conversation. `Issue.turnID` is non-nil while a turn runs.

**Lifecycle hooks every agent implements:** dispatch (start or resume a turn), progress messages into the activity log, cancel, and reconcile after a restart or interruption.

## Usage and cost

| Agent | What is recorded |
| --- | --- |
| Claude Code | Each turn appends a `usage` activity such as `Claude Code turn finished · 12,340 in / 890 out tokens · $0.42`, from the stream-json `result` event. |
| Codex | Not recorded yet. |

A planned follow-up aggregates usage per agent and project to help decide which agent to use.

## Adding another agent

Adding a case to `AgentKind` makes the compiler point at most switch statements that need it. Work through these in order:

1. **Model.** Add the case and its `title` to `AgentKind` in [Models.swift](../../Sources/ScreenClipCore/Models.swift). Add any settings (executable path, model) to `AppSettings` as **optional** properties, so older queues still decode.
2. **Detection.** Add a default-path search and a `detect…` function to [AgentDetector.swift](../../Sources/ScreenClipCore/AgentDetector.swift), and include it in `detectAll`. Report `signedIn` when the agent exposes it, otherwise `nil`.
3. **Client.** Add a client in `Sources/ScreenClipCore` that can start or resume a conversation by ID, send the prompt and PNG images, stream progress text, return the structured result, and cancel. Prefer the agent's own schema or structured-output support, and its own sandbox, with edits limited to the worktree.
4. **Worker.** Add an `AgentWorker+<Agent>.swift` extension, like [AgentWorker+Claude.swift](../../Sources/ScreenClip/AgentWorker+Claude.swift), with a `run<Agent>(_:project:path:)` that sets `threadID` and `turnID`, records progress, puts the result JSON in `texts[id]`, then calls `finish(id)`. Route to it from `dispatch` in [AgentWorker.swift](../../Sources/ScreenClip/AgentWorker.swift), and add the agent's branch to `cancel` and `reconcile`. Clear `turnID` on every exit path, and keep disconnects scoped to that agent's jobs. Launch the agent with `ProcessEnvironment.agent()`.
5. **App model and UI.**
   - `AppModel.agentStatus`: add the status line.
   - A sign-in action, if the agent needs one.
   - An "open conversation" affordance on `Issue` (like `codexURL` or `claudeResumeCommand`), surfaced in `QueueView`.
   - The link-existing-conversation alert text in `QueueView`.
   - A Settings section for the agent's path and model. `AgentDetectionRow` and the pickers pick up the new case automatically.
6. **Plugin.** `server.py` already reports `agent`. Package the plugin for the agent if it supports MCP plugins.
7. **Tests.**
   - Client tests against a fake CLI (arguments, input, result parsing, cancel, failure output).
   - Detector tests.
   - A worker test that goes from capture to question to reply and resumes the same conversation in the worktree.
   - Decoding of older settings.
   - See [AgentTests.swift](../../Tests/ScreenClipCoreTests/AgentTests.swift) and the Claude tests in [WorkerTests.swift](../../Tests/ScreenClipAppTests/WorkerTests.swift).
8. **Docs.**
   - Add a page in this folder using the same sections as [claude-code.md](claude-code.md): how it runs, sessions, permissions and sandbox, sign-in, recovery, usage, limitations, and verification status.
   - Add a row to the table at the top of this page.
   - Record verification in [validation.md](../validation.md).
