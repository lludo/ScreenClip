# Claude Code

Updated: November 14, 2026. Part of [Coding agents](README.md), which describes the shared agent contract.

ScreenClip can send any report to Claude Code instead of Codex or Grok Bot. Each turn runs `claude -p` headless in the issue's worktree ([ClaudeCodeClient.swift](../../Sources/ScreenClipCore/ClaudeCodeClient.swift)). One Claude Code session per issue carries the conversation across questions, replies, and new evidence.

## At a glance

| Topic | Behavior |
| --- | --- |
| Executable | Settings → Connections → Claude Code. Detected from `/opt/homebrew/bin/claude`, `/usr/local/bin/claude`, `~/.local/bin/claude`, `~/.claude/local/claude`, `~/.npm-global/bin/claude`, or `~/.bun/bin/claude`. Override the path if needed. |
| Model | Optional, for example `opus` or `sonnet`. Empty uses Claude Code's default. |
| Sign-in | **Sign in to Claude Code** opens Terminal running `claude auth login`, then use **Detect agents**. Detection reads `claude auth status`. ScreenClip never handles Claude credentials. The Claude desktop app's sign-in is separate from the CLI's. |
| Turn | One process per turn, with the prompt and approved PNGs sent as one stream-json user message. |
| Questions | Returned as a structured `question` or `blocked` result, answered under **Needs you**. A reply starts the next turn with `--resume`. |
| Open the conversation | **Open in Claude Desktop** runs `claude --desktop --resume '<session>'` from the worktree when the configured CLI is 2.1.285 or newer; older CLIs get an explanatory message. **Copy Claude resume command** copies `cd '<worktree>' && claude --resume '<session>'` and works on every version. Both refuse while a process is running the session. |
| Usage | Each turn logs tokens and cost as a `usage` activity. |

## How a turn runs

```sh
# First turn; later turns use --resume '<uuid>' instead of --session-id.
claude -p --input-format stream-json --output-format stream-json --verbose \
  --json-schema '<ScreenClip result schema>' \
  --settings '{"sandbox":{"enabled":true,"autoAllowBashIfSandboxed":true,"allowUnsandboxedCommands":true}}' \
  --disallowedTools 'Bash(git push:*)' 'Bash(gh:*)' \
  --permission-mode auto \
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

### Claude Desktop

[Claude's desktop documentation](https://code.claude.com/docs/en/desktop#coming-from-the-cli) says a CLI session can be brought into Desktop with `claude --desktop --resume <session-id>` (Claude Code 2.1.285 or newer, macOS, signed in with a Claude subscription) or with `/resume` in a Desktop local session. Desktop keeps its own session list, so a CLI session does not appear there until it is imported.

**Open in Claude Desktop** ([ClaudeDesktop.swift](../../Sources/ScreenClipCore/ClaudeDesktop.swift)) detects support with `claude --version`, refuses while any process is running the session (the same `ps` check used before every turn), and then runs the command in the worktree under a pseudo-terminal (`/usr/bin/script`), because the CLI rejects redirected output. The CLI never moves a session that is running elsewhere, and ScreenClip never starts a turn while one is. After Desktop adopts a session, finish or close it there before ScreenClip continues the report.

Verified on this host (2026-11-14), with a disposable repository, a separate worktree, and a one-word headless turn that used `--session-id` and `--name` exactly as ScreenClip does:

- The transcript landed under the worktree's own `~/.claude/projects/` folder, so the session belongs to the worktree directory.
- The installed CLIs (`/opt/homebrew/bin/claude` 2.1.128 and `~/.local/bin/claude` 2.1.141) have no `--desktop`. The CLI bundled inside Claude Desktop (2.1.325, read-only use) does.
- `claude --desktop --resume <id>` printed `Opening session <id> in Claude Desktop`. Desktop then wrote a session record with `cliSessionId` equal to the headless UUID, `cwd` equal to the worktree, the `--name` title, and `fromCliTranscript`/`adoptedFromOtherSurface` flags.
- The command fails without a terminal (`--desktop opens the Claude Desktop app and can't run non-interactively`).

Not verified: the visual sidebar group. The record had no git anchors immediately after import, and this environment cannot capture the screen. Whether Desktop groups a worktree session under its main repository (or lists it under the worktree folder) must be checked by eye. ScreenClip does not edit Desktop's session files.

## Permissions and sandbox

- Every new and resumed turn explicitly uses Claude Code's `auto` permission mode. Its classifier reviews actions that would otherwise need approval, including extra filesystem or network access. This replaces the old `acceptEdits` mode, which denied unresolved permission requests in headless runs. A CLI and account that support auto mode are required; ScreenClip does not fall back to bypassing permissions.
- Bash uses Claude Code's sandbox by default. Unsandboxed retries are enabled for tools that cannot run within it (for example, builds needing external caches); auto mode reviews the underlying command before granting that access. See Anthropic's [permission modes](https://code.claude.com/docs/en/permission-modes) and [sandbox retry rules](https://code.claude.com/docs/en/sandboxing#the-unsandboxed-retry-escape-hatch).
- `git push` and `gh` are denied, and the process runs without `GH_TOKEN`/`GITHUB_TOKEN`. These are command-prefix deny rules, not a complete security boundary; the classifier also reviews additional access, and the prompt scopes the task. The prompt also forbids commits, PRs, and merges, because ScreenClip publishes after its own validation.
- Headless mode cannot show approval prompts. Automatic review handles routine requests; an explicit deny, managed policy, or classifier rejection can still block a tool. Denied commands are recorded in Activity. A blocked result or empty question with permission denials becomes a retryable failure with a plain-language explanation and **Continue**, rather than a reply box containing shell commands. A real nonempty question is preserved without appending command dumps. Older permission-only reply boxes are converted to the same retryable state when ScreenClip starts.

## Recovery

- **Cancel** sends SIGTERM to `claude` and every process it started, then SIGKILL to anything still running 3 seconds later. ScreenClip stops reading Claude's output 3 seconds after it exits, so a background process that inherited the pipes cannot keep the turn open.
- A turn that runs longer than 45 minutes is stopped the same way and reported as failed. Continue runs it again in the same session.
- A run that reports Claude Code is signed out (`Not logged in · Please run /login`, an invalid API key, an expired token) goes back to the queue, held until you sign in.
- After a ScreenClip restart, a report that was working continues the same session automatically when no `claude` process for that session is still running. If one is (it survived the crash, or you resumed it in Terminal), the report waits under **Needs you** for **Reconcile chat**.
- A child process can survive a ScreenClip crash, and a session may also be running in Terminal. **Reconcile chat** and resumed dispatch check for those processes and refuse a competing turn. Reconciliation clears interrupted state only when no matching process is found; it does not read completed results from Claude history. Continue to run the turn again.
- **Link existing chat…** accepts a Claude Code session UUID.
- Codex disconnects do not affect Claude jobs.

## Reading the queue interactively (plugin)

You can also pull reports into your own interactive Claude Code session instead of having ScreenClip dispatch them. The repository is a local Claude Code plugin marketplace with the read-only MCP server and a `fix-report` skill. Installation steps are in the [plugin README](../../plugins/screenclip/README.md).

Then ask, for example, "fix ScreenClip #234". The skill reads the note, context, and screenshots, refuses to duplicate a report ScreenClip is already working on, and fixes it in the current session. ScreenClip does not learn about fixes made this way: mark the report Verified or archive it after retesting.

## Limitations

- Runs only while ScreenClip is running and the Mac is awake, the same as Codex.
- No human mid-turn permission prompts. Auto mode reviews requests; remaining blocked tools can end the turn as `blocked` or `question` with the denials listed.
- Reconciliation cannot recover a result that finished while ScreenClip was not running.
- Switching an issue between Codex and Claude Code after submission is not supported.

## Verification status

- **Automated:** fake-CLI tests cover arguments, stdin evidence, progress, structured and fenced results, usage, missing results and non-zero exits, cancellation, detection, and the worker flow (capture → question → reply → `--resume` in the same worktree session), plus holding work for a signed-out agent.
- **CLI compatibility:** the installed CLI (2.1.311) advertises `auto` permission mode. Automated tests cover the mode and sandbox settings on both new and resumed turns. A live classifier-reviewed build has not been verified. Earlier plugin manifests passed `claude plugin validate`.
- **Desktop hand-off:** fake-CLI tests cover version classification, the pseudo-terminal invocation, an old CLI (never executed), an unreadable version, an invalid session ID, CLI failure output, and a running session.
- **Not yet verified:** a live Claude fix through validation, PR publication, and merge; permanent plugin installation; and an interactive plugin fix.

Track results in [validation.md](../validation.md).
