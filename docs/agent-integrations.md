# Agent integrations: Codex, Claude Code, and an external assistant

Updated: November 13, 2026. Local Codex and Claude Code selection is implemented. External-assistant transport and status callbacks below remain design proposals.

## Goal

Let the user choose who handles a capture: Codex or Claude Code locally, with a possible future external assistant such as Grok Bot that receives the report, reads the screenshot and note, and fixes it remotely.

## Current state

| Piece | Status |
| --- | --- |
| `AgentKind` (`codex`, `claude`) and `Issue.agent` / `resolvedAgent` | Done. `resolvedAgent` is `agent ?? .codex`. |
| `AppSettings.claudePath`, `claudeModel`, `defaultAgent`, `preferredAgent` | Done, decoded optionally for old queues. |
| `AgentDetector.detectClaude` (path search, `--version`, `claude auth status`) | Implemented. Settings can refresh detection and override the executable. |
| `ClaudeCodeClient` (headless `claude -p`, stream-json in/out, base64 PNG images, `--json-schema`, `--session-id`/`--resume`, sandbox, `acceptEdits`, `git push`/`gh` denied) | Done, with tests. |
| `AgentWorker.runClaude` (worktree, one session per issue, progress, missing-session restart, permission denials surfaced as questions, same `finish`/publish path as Codex), cancel, and `reconcileClaude` | Implemented with synthetic CLI tests. Resume/reconcile reject sessions still running in another process. |
| `Issue.claudeResumeCommand` (`cd <worktree> && claude --resume <id>`) and `review_queue.py` session display | Done. |
| Agent selection and stamping | Implemented. Settings chooses the default; the composer can override a new report or draft. Follow-ups retain the submitted issue's agent. |
| Settings UI for Claude path/model, detection, and sign-in | Implemented. Sign-in opens a local Terminal command; ScreenClip does not store Claude credentials. |
| Claude Code plugin packaging | Local marketplace, plugin manifest, MCP configuration, and interactive `fix-report` skill are included. CLI manifest validation passes. |

Tests cover the agent stamp, follow-up ownership, session resume, missing-session recovery, external-session conflicts, cancellation, and isolation from Codex disconnects. A live Claude fix through validation, PR publication, and merge remains unverified. External-assistant hand-off is not implemented.

## Option A: Claude Code as a selectable local agent (implemented)

The native workflow is available from Settings and the capture window.

1. **Default agent in Settings → Connections.** Detection lists installed agents and retains the selected default. Claude executable and model overrides are optional. Missing or signed-out agents hold queued work until detection succeeds.
2. **Stamp the agent at submit.** A new issue uses the default or the composer override. Old issues without a stamp continue to resolve to Codex.
3. **Per-report override.** The composer allows a different agent for a new report or draft. Adding evidence to a submitted report locks the picker to that issue's agent. Switching an already submitted issue between agents is not supported.
4. **Sign-in.** "Sign in to Claude" opens Terminal running `claude auth login`. Return to Settings and use Detect agents after signing in.
5. **Open the conversation.** Codex has `codex://threads/<id>`; Claude reports offer **Copy Claude resume command**. Cancel active ScreenClip work before continuing that session in Terminal.
6. **Recovery.** Replies resume the same session. Reconciliation checks for active processes before clearing interrupted state; it does not read completed Claude history. If the session no longer exists, Continue creates a fresh one with saved captures and replies.

Trade-offs versus Codex: runs only while ScreenClip and the Mac are awake (same as Codex); one process per turn, so replies to questions start a new `--resume` turn, which the worker already supports; no sidebar/project-membership problem because there is no desktop chat list to join.

## Option B: Claude Code reading the queue over MCP (no app changes)

The existing read-only plugin is a plain stdio MCP server, so Claude Code can use it today:

```sh
claude mcp add screenclip -- python3 /Users/ludo/Documents-Local/GitHub/ScreenClip/plugins/screenclip/server.py
```

Then, in a Claude Code session in the repo: "Use ScreenClip to get #234 with images and fix it." This is a manual pull workflow, useful for reviewing or batching, but it does not give automatic pickup, status write-back, or PR tracking in ScreenClip. Do not use it on issues ScreenClip is already working on.

## Option C: Send reports to an external assistant (Grok Bot)

A third destination where ScreenClip does not run an agent locally at all. It hands the report off and tracks the outcome.

### Hand-off

ScreenClip gets an "External assistant" destination with one of two transports:

- **Webhook (preferred).** The assistant exposes a webhook URL plus a sender key. On submit, ScreenClip POSTs JSON: report number, issue UUID, revision, title, note(s), capture context (app, bundle ID, browser URL if allowed), project name, GitHub `owner/repo`, base branch, validation command, and the approved (redacted, annotated) PNG. Whether the PNG can be inline base64 depends on the webhook's payload limit, which is still to be confirmed; if it cannot, upload the image somewhere the assistant can read and send a link instead. Store the URL and key in Keychain.
- **Email.** Send the same content to the assistant's inbox with the PNG attached. Simpler and handles images natively, but slower and harder to correlate.

Never send the unredacted original; only the approved derivative, as the local flow already does.

### What the assistant does

1. Wakes on the webhook or email, reads the screenshot and note.
2. Starts a cloud coding agent on the GitHub repository with the observation, screenshot, and validation command. The branch name and PR body include the report number (for example branch `screenclip/234-<slug>`, body line `ScreenClip: #234`).
3. If something is unclear, asks the user in the assistant's chat.
4. Reports the PR link back to the user, and optionally watches the PR until it merges.

### Closing the loop in ScreenClip

- On successful hand-off, set the issue to a new status such as "Sent" (or reuse `working` with an activity line) and record the assistant as owner.
- `GitHubService` already tracks PRs, checks, and confirmed merges. Add a lookup that finds the PR for an externally handled issue by branch prefix or the `ScreenClip: #234` marker, then reuse the existing `prOpen` → `merged` → "To retest" path. ScreenClip still verifies merges with GitHub itself instead of trusting the assistant's message.
- Questions stay in the assistant's chat in a first version. A later version could add a small authenticated callback or extend the MCP plugin with the proposed `post_update` / `ask_question` / `get_replies` / `record_result` tools so questions also show up under Needs you.

### Trade-offs

- Works while the Mac is asleep, and fixes happen in the cloud rather than in a local worktree.
- The screenshot and note leave the Mac, so this should be opt-in per project, and redaction matters more.
- Auto-merge policy moves to the GitHub side (branch protection, required checks); ScreenClip should only observe the merge.

## Suggested order

1. Validate Option A with a live synthetic Claude fixture through publication and merge. The picker, stamp, and worker are implemented; automated coverage uses fake CLIs.
2. Option C, first version: webhook hand-off plus PR discovery by report number, with questions handled in the assistant's chat.
3. Later: two-way status through the plugin tools or a callback, so all three agents report into the same queue UI.

## Open questions

- Should the agent be chosen per project (each project has a default) or globally with per-issue override? Per project is likely more natural.
- For Option C, which projects may send screenshots off the Mac?
- Does the external assistant also handle merging, or only open the PR and leave merge to ScreenClip's existing policy?
