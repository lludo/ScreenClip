# Coding agents

Updated: November 15, 2026.

ScreenClip captures an observation and hands it to a coding agent. Codex and Claude Code investigate and fix it in an isolated Git worktree. Grok Bot is a remote assistant: ScreenClip pushes the approved screenshots to GitHub and wakes the assistant with a webhook, then tracks the pull request. The agent is pluggable.

| Agent | Transport | Conversation identity | Open the conversation | Sign-in | Page |
| --- | --- | --- | --- | --- | --- |
| Codex | `codex app-server` (long-lived JSON-RPC over stdio) | Codex thread ID | `codex://threads/<id>` | ChatGPT or API key through app-server | [codex.md](codex.md) |
| Claude Code | `claude -p` (one stream-json process per turn) | Session UUID chosen by ScreenClip | Copy `cd <worktree> && claude --resume <id>` | `claude auth login` in Terminal | [claude-code.md](claude-code.md) |
| Grok Bot | Webhook `screenclip.external.v1` after a Git push of approved screenshots | Report number and `screenclip/<number>-<slug>-<workspace>` branch | Pull request link, or a note that the chat is in Grok Bot | **Connect Grok Bot** with **POST to** and **key** (or **header**) from the ScreenClip reports routine. The address and secret stay in the Keychain | [external-assistant.md](external-assistant.md) |

Separately from automatic dispatch, Codex and Claude Code can **read** the queue through the optional MCP plugin. See [the plugin README](../../plugins/screenclip/README.md).

The one-off prompts once used to have each agent investigate its own integration are archived in [Claude Code and Grok Bot handoffs](../archive/claude-grok-handoffs.md).

## Choosing an agent

- **System default.** Settings → Connections → **AI agent** → **System default** sets `AppSettings.defaultAgent`. Missing in older queues means Codex.
- **Project default.** Project settings stores either inherit (`defaultAgent` null) or an explicit provider. Inherit follows the system default. An explicit provider stays when the system default changes. An older project with screenshot sharing on migrates to Grok Bot; every other older project inherits.
- **Per report.** The capture window's **Agent** picker starts at the project's effective default (or its last submitted agent, model, and effort when enabled in Project settings) and can be changed for a new report or a draft. The choice is stamped on the issue (`Issue.agent`).
- **Follow-ups keep their agent.** Adding a capture to a submitted issue locks the picker to that issue's agent, because conversation IDs are not interchangeable between agents. Switching a submitted issue to another agent is not supported; cancel it and submit a new report.
- **Older issues** have no `agent` field and resolve to Codex (`Issue.resolvedAgent`).

## Default prompt add-on

**Settings → Connections → Agent instructions → Default prompt add-on** stores instructions shared by all projects and agents. Edit the multiline text and choose **Save settings**. Leave it empty to disable it, or choose **Restore default prompt** to restore the built-in text. Older queues use the built-in default automatically, and so does a queue that saved an earlier built-in text unchanged (`AppSettings.retiredPromptAddOnTexts`).

The built-in text asks for a PR description a reviewer can scan: **What was the issue** (the reported problem and its root cause), **How we addressed it** (the approach and key changes), and **How we verified it** (checks, results, and the retest), followed by the **Before / After** comparison for visual fixes. For local agents ScreenClip appends that comparison right after the agent's summary, so the agent does not repeat the images.

The original synthetic [Before](../screenshots/default-prompt-before.png) / [After](../screenshots/default-prompt-after.png) comparison for PR #47 is retained here so its evidence does not depend on a temporary branch. These are historical feature-introduction captures, not the current Settings layout.

ScreenClip publishes a labeled **Before / After** comparison for local-agent reports with captures. The agent rebuilds, retests, and saves real PNG screenshots in `.screenclip/pr/<issue-id>/revision-<revision>/after/` in its isolated worktree. ScreenClip copies the original flattened report captures into the adjacent `before/` folder, validates the PNGs, stages them (even if the repository ignores PNGs), runs project validation, and commits and pushes the evidence with the fix. The PR embeds immutable GitHub commit links, which survive branch deletion and merging. Existing PR descriptions are refreshed after follow-up work.

Screenshot sharing to the project repository is always enabled. There is no separate sharing checkbox or approval step. Only annotated/redacted report derivatives are published; unredacted originals are never copied. Anyone who can read the repository can read the evidence. A missing or invalid After image triggers the local agent's repair flow; after two failed repairs the report needs attention instead of opening a text-only PR. Agents unable to capture the fixed UI must explain the concrete blocker and return blocked. Previous revisions' images do not satisfy a new revision's retest.

Codex and Claude Code receive this contract and the current add-on on every turn, including resumed conversations. The add-on customizes the summary; clearing it does not disable the screenshot publication contract. Grok Bot receives `promptAddOn` in the evidence JSON and webhook, and its remote routine remains responsible for taking and embedding its Before / After comparison. Local screenshot enforcement does not run in that remote routine.

## Detection and readiness

`AgentDetector` (in `ScreenClipCore`) finds each local agent's executable, reads its version, and, where supported, its sign-in state. For Grok Bot, detection checks the connection saved in the Keychain. Detection runs at launch, from **Detect agents** in Settings, and every minute while a queued report is held for an agent that is not ready. It searches Homebrew and system folders, common per-user install folders, and the login shell's PATH.

- Settings lists installed agents and the system default. The capture window offers connected providers, including Grok Bot once its webhook is saved. A follow-up retains its original agent.
- The queue holds a queued issue whose agent detection reports missing, signed out, or not configured (`AgentDetection.usable == false`), and Codex reports while Codex sign-in is known to be signed out. The once-a-minute check resumes them after you sign in or install the agent; **Detect agents** resumes them at once.
- A run that fails because its agent is signed out goes back to the queue, held, instead of failing. It and the reports queued after it wait for sign-in. Because `claude auth status` can still say signed in (an expired token, for example), the automatic check keeps that agent held for 10 minutes after such a failure; **Detect agents** clears it immediately.
- The queue sidebar shows each provider's status (`AppModel.agentStatus`) as **Codex ready**, **Claude Code ready**, or **Grok Bot ready**, and the same shape for not connected, not found, and sign-in.

## The agent contract

Codex and Claude Code follow the same contract, so the rest of ScreenClip stays agent-neutral. Grok Bot is the remote exception described after the usage table.

**ScreenClip provides**
- An isolated worktree and `screenclip/<id>` branch (`GitWorkspace.prepare`), started from `origin/<base>`, as the agent's working directory. The tester's checkout is never the working directory.
- One prompt per turn (`AgentPrompt.turn`). The first turn of a conversation gets the full prompt (`AgentPrompt.text`): the issue, project, worktree, branch, validation command, capture context, user replies, and the latest validation or CI failure (`Issue.validationFeedback`, never unrelated errors). A resumed conversation that completed a turn gets a short follow-up with only the captures, notes, replies, and validation feedback it has not seen, and only the new screenshots; `Issue.deliveredContext` records what it has seen. A new or relinked conversation gets everything again. Notes, screenshot contents, titles, and URLs are labeled as untrusted evidence.
- The approved screenshots only (annotated, with redactions flattened), never unredacted originals.
- A JSON Schema for the result (`AgentPrompt.resultSchema`).
- An environment with inherited GitHub token variables and git redirect variables removed (`ProcessEnvironment.agent`). The prompt reserves publication for ScreenClip. Environment cleanup does not isolate credentials available elsewhere on the Mac; full-access Codex commands are unsandboxed.
- Instructions to work autonomously: make reasonable implementation choices, investigate failures, and run checks without conversational permission requests. Questions are reserved for a missing decision that materially affects the intended result and cannot be resolved from the repository or evidence. Runtime permissions still follow the configured agent mode; see [Codex permissions](codex.md#at-a-glance).

**The agent returns** one structured result per turn:

```json
{ "outcome": "implemented | question | blocked", "summary": "…", "question": "…" }
```

**ScreenClip owns everything after the result.** `finish` in [AgentWorker+Publishing.swift](../../Sources/ScreenClip/AgentWorker+Publishing.swift) turns `question` and `blocked` into **Needs you**. For `implemented`, it runs the project's validation, commits, pushes, opens the PR, watches checks, schedules up to two repair turns, and merges only after independently verifying the PR head, checks, reviews, and input revision. Agents are told not to commit, push, open PRs, or merge. The one git operation an agent may start is merging the base branch into its worktree, uncommitted, when a rebase or update is requested or the base conflicts; ScreenClip concludes that merge with its own commit. Each integration also blocks those operations where the agent supports it.

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

1. **Model.** Add the case and its `title` to `AgentKind` in [Models.swift](../../Sources/ScreenClipCore/Models.swift). Add any settings (executable path, model) to `AppSettings` as **optional** properties, so older queues still decode. If the agent offers models or efforts, add them to `AgentModelCatalog` in [AgentModels.swift](../../Sources/ScreenClipCore/AgentModels.swift) (a static list, or parsed from the agent) and pass `Issue.agentModel` / `agentEffort` on each turn; `AgentModelMenu` shows them in the composer.
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
