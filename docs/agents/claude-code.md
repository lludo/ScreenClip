# Claude Code

Updated: November 14, 2026. Part of [Coding agents](README.md), which describes the shared agent contract.

ScreenClip can send any report to Claude Code instead of Codex or Grok Bot. Each turn runs `claude -p` headless in the issue's worktree ([ClaudeCodeClient.swift](../../Sources/ScreenClipCore/ClaudeCodeClient.swift)). One Claude Code session per issue carries the conversation across questions, replies, and new evidence.

## At a glance

| Topic | Behavior |
| --- | --- |
| Executable | Settings → Connections → Claude Code. Detected from `/opt/homebrew/bin/claude`, `/usr/local/bin/claude`, `~/.local/bin/claude`, `~/.claude/local/claude`, `~/.npm-global/bin/claude`, or `~/.bun/bin/claude`. Override the path if needed. |
| Model | Optional, for example `opus` or `sonnet`. Empty uses Claude Code's default. |
| Sign-in | **Sign in to Claude** opens Terminal running `claude auth login`, then use **Detect agents**. Detection reads `claude auth status`. ScreenClip never handles Claude credentials. The Claude desktop app's sign-in is separate from the CLI's. |
| Turn | One process per turn, with the prompt and approved PNGs sent as one stream-json user message. |
| Questions | Returned as a structured `question` or `blocked` result, answered under **Needs you**. A reply starts the next turn with `--resume`. |
| Open the conversation | **Copy Claude resume command** copies `cd '<worktree>' && claude --resume '<session>'`. Cancel active ScreenClip work before continuing there. |
| Usage | Each turn logs tokens and cost as a `usage` activity. |

## How a turn runs

```sh
# First turn; later turns use --resume '<uuid>' instead of --session-id.
claude -p --input-format stream-json --output-format stream-json --verbose \
  --json-schema '<ScreenClip result schema>' \
  --settings '{"sandbox":{"enabled":true,"autoAllowBashIfSandboxed":true,"allowUnsandboxedCommands":false}}' \
  --disallowedTools 'Bash(git push:*)' 'Bash(gh:*)' \
  --permission-mode acceptEdits \
  --session-id '<uuid>' \
  --name 'ScreenClip: #234 …'
```

Add `--model '<model>'` when a model override is configured.

- **Working directory:** the issue's worktree.
- **Input:** a single `{"type":"user","message":{"content":[text, image…]}}` line on stdin, then stdin closes. Images are base64 `image/png` blocks.
- **Output events:**
  - `system/init` carries the session ID.
  - `assistant` text blocks become activity entries.
  - The final `result` event provides `structured_output` (schema-validated), `usage`, `total_cost_usd`, `permission_denials`, and `is_error`.
- **Fallback:** if `structured_output` is absent, ScreenClip extracts JSON from the final message text, including fenced code blocks.
- **Environment:** `CLAUDECODE` and session variables are removed, so a ScreenClip launched from a Claude Code session does not inherit its identity.

## Sessions

ScreenClip generates the session UUID and stores it in `Issue.threadID` before the first turn. Later turns use `--resume`. If Claude Code reports that the session no longer exists (its history was cleared), either in a result or only on stderr, ScreenClip starts a fresh session with the saved captures and replies. Every prompt is self-contained.

## Permissions and sandbox

- File edits inside the worktree are auto-approved (`acceptEdits`).
- Bash runs inside Claude Code's sandbox and is auto-allowed only there. Writes are limited to the working directory, and the unsandboxed escape hatch is off. This is comparable to Codex's `workspace-write`.
- `git push` and `gh` are denied, and the process runs without `GH_TOKEN`/`GITHUB_TOKEN`. The deny rules match command prefixes, so the real safeguards are the missing credentials and the sandbox. The prompt also forbids commits, PRs, and merges, because ScreenClip publishes after its own validation.
- Headless mode cannot show approval prompts. A blocked tool is denied, and its denials are appended to the `question` of a `question` or `blocked` result, so **Needs you** says what was blocked.

## Recovery

- **Cancel** terminates the running `claude` child process.
- A turn that runs longer than 45 minutes is stopped and reported as failed. Continue runs it again in the same session.
- A child process can survive a ScreenClip crash, and a session may also be running in Terminal. **Reconcile chat** and resumed dispatch check for those processes and refuse a competing turn. Reconciliation clears interrupted state only when no matching process is found; it does not read completed results from Claude history. Continue to run the turn again.
- **Link existing chat…** accepts a Claude Code session UUID.
- Codex disconnects do not affect Claude jobs.

## Reading the queue interactively (plugin)

You can also pull reports into your own interactive Claude Code session instead of having ScreenClip dispatch them. The repository is a local Claude Code plugin marketplace with the read-only MCP server and a `fix-report` skill. Installation steps are in the [plugin README](../../plugins/screenclip/README.md).

Then ask, for example, "fix ScreenClip #234". The skill reads the note, context, and screenshots, refuses to duplicate a report ScreenClip is already working on, and fixes it in the current session. ScreenClip does not learn about fixes made this way: mark the report Verified or archive it after retesting.

## Limitations

- Runs only while ScreenClip is running and the Mac is awake, the same as Codex.
- No mid-turn approvals. Blocked tools end the turn as `blocked` or `question` with the denials listed.
- Reconciliation cannot recover a result that finished while ScreenClip was not running.
- Switching an issue between Codex and Claude Code after submission is not supported.

## Verification status

- **Automated:** fake-CLI tests cover arguments, stdin evidence, progress, structured and fenced results, usage, missing results and non-zero exits, cancellation, detection, and the worker flow (capture → question → reply → `--resume` in the same worktree session), plus holding work for a signed-out agent.
- **Manual:** the installed CLI (2.1.128) provides every flag and sandbox setting used, and the plugin manifests pass `claude plugin validate`.
- **Not yet verified:** a live Claude fix through validation, PR publication, and merge; permanent plugin installation; and an interactive plugin fix.

Track results in [validation.md](../validation.md).
