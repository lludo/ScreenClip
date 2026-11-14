# Coding agents

Updated: November 14, 2026.

ScreenClip captures an observation and hands it to a coding agent. Codex and Claude Code investigate and fix it in an isolated Git worktree. Grok Bot is a remote assistant: ScreenClip pushes the approved screenshots to GitHub and wakes the assistant with a webhook, then tracks the pull request. The agent is pluggable.

| Agent | Transport | Conversation identity | Open the conversation | Sign-in | Page |
| --- | --- | --- | --- | --- | --- |
| Codex | `codex app-server` (long-lived JSON-RPC over stdio) | Codex thread ID | `codex://threads/<id>` | ChatGPT or API key through app-server | [codex.md](codex.md) |
| Claude Code | `claude -p` (one stream-json process per turn) | Session UUID chosen by ScreenClip | Copy `cd <worktree> && claude --resume <id>` | `claude auth login` in Terminal | [claude-code.md](claude-code.md) |
| Grok Bot | Webhook `screenclip.external.v1` after a Git push of approved screenshots | Report number and `screenclip/<number>-<slug>-<workspace>` branch | Pull request link, or a note that the chat is in Grok Bot | Webhook URL and Authorization header in the Keychain | [external-assistant.md](external-assistant.md) |

Separately from automatic dispatch, Codex and Claude Code can **read** the queue through the optional MCP plugin. See [the plugin README](../../plugins/screenclip/README.md).

## Choosing an agent

- **Default agent.** Settings → Connections → **AI agent** → **Default agent** sets `AppSettings.defaultAgent`. Missing in older queues means Codex.
- **Per report.** The capture window's **Agent** picker starts at the default and can be changed for a new report or a draft. The choice is stamped on the issue (`Issue.agent`).
- **Follow-ups keep their agent.** Adding a capture to a submitted issue locks the picker to that issue's agent, because conversation IDs are not interchangeable between agents. Switching a submitted issue to another agent is not supported; cancel it and submit a new report.
- **Older issues** have no `agent` field and resolve to Codex (`Issue.resolvedAgent`).

## Detection and readiness

`AgentDetector` (in `ScreenClipCore`) finds each local agent's executable, reads its version, and, where the agent supports it, its sign-in state. For Grok Bot, detected means the webhook URL and Authorization header are in the Keychain. Detection runs at launch, from **Detect agents** in Settings, and every minute while a queued report is held for an agent that is not ready. It searches Homebrew and system folders, common per-user install folders (`~/.local/bin`, `~/.bun/bin`, `~/.volta/bin` and similar), and the PATH your login shell sets up, so npm, nvm, Volta and bun installs are found when ScreenClip is opened from Finder.

- Pickers list installed agents plus the current default, so the default never disappears. Grok Bot is always listed. In the capture window its row is disabled, with a hint, until it is configured and the project has opted in to sending screenshots.
- The queue holds a queued issue whose agent detection reports missing, signed out, or not configured (`AgentDetection.usable == false`), and Codex reports while Codex sign-in is known to be signed out. The once-a-minute check resumes them after you sign in or install the agent; **Detect agents** resumes them at once.
- A run that fails because its agent is signed out goes back to the queue, held, instead of failing. It and the reports queued after it wait for sign-in. Because `claude auth status` can still say signed in (an expired token, for example), the automatic check keeps that agent held for 10 minutes after such a failure; **Detect agents** clears it immediately. The capture window warns when the selected local agent is not ready.
- The queue sidebar shows the default agent's status (`AppModel.agentStatus`).

## The agent contract

Codex and Claude Code follow the same contract, so the rest of ScreenClip stays agent-neutral. Grok Bot is the remote exception described after the usage table.

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

**Every turn ends.** A Claude Code or Codex turn running longer than 45 minutes (`AgentWorker.turnTimeLimit`) is stopped and the report fails with a note; Continue resumes the same conversation. Time a Codex turn spends waiting for your answer does not count. Cancel and the time limit stop the agent and every process it started, and kill whatever ignores SIGTERM after 3 seconds. Only reports ScreenClip is actually dispatching, running or publishing count toward the per-project parallel limit.

## Usage and cost

| Agent | What is recorded |
| --- | --- |
| Claude Code | Each turn appends a `usage` activity such as `Claude Code turn finished · 12,340 in / 890 out tokens · $0.42`, from the stream-json `result` event. |
| Codex | Not recorded yet. |
| Grok Bot | Not recorded. Each revision sends one webhook. |

A planned follow-up aggregates usage per agent and project to help decide which agent to use.

Grok Bot (`AgentKind.external`) is the remote exception: [Grok Bot](external-assistant.md) is its contract. The checklist below is for another local agent.

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
