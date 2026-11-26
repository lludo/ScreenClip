# Optional ScreenClip plugin

This local MCP plugin lets a Codex or Claude Code session read the queue, notes, approved screenshots, and status. Grok Bot does not install this plugin; its questions stay in Grok Bot's chat. The native ScreenClip app owns automatic dispatch, replies, publication, and merge verification. This bridge never writes the queue, to avoid competing agents and queue writers. The one thing it can write is a settings proposal, which changes nothing until you accept it in ScreenClip.

## Install from ScreenClip (easiest)

Open ScreenClip › Settings › AI Agents › **Check tasks from your agents** and click **Install** next to Claude Code or Codex. ScreenClip copies this server to `~/Library/Application Support/ScreenClip/mcp/server.py`, so the path survives app updates (each launch refreshes that copy), and registers it at user level (`claude mcp add --scope user` or `codex mcp add`). Every project's sessions then have the tools. **Copy command** gives the same command for Terminal, and **Copy JSON** gives an `mcpServers` block for other MCP apps. Start a new agent session after installing, then ask: “Check this project's ScreenClip tasks.” A development instance started with `--data-dir` registers itself as `screenclip-dev`, so it never replaces the everyday entry. When the Claude Code plugin is enabled, it already provides the tools, so Install stays off for Claude Code.

## Install from the repository

Requires Python 3.9+ and local execution. Add this folder to a local plugin marketplace using the supported Codex plugin setup, or configure the MCP server directly in Codex with `python3 /absolute/path/to/plugins/screenclip/server.py`. No cloud service or lifecycle hook is required.

Claude Code: the repository root is a local plugin marketplace (`.claude-plugin/marketplace.json`). Install the plugin, which bundles the same MCP server, a `fix-report` skill for interactive fixes, and an `install-ios-sdk` skill that adds [ScreenClipKit](../../docs/ios-sdk.md) to an iOS app's Debug build:

```sh
claude plugin marketplace add /absolute/path/to/ScreenClip
claude plugin install screenclip@screenclip
```

For one session only, run `claude --plugin-dir /absolute/path/to/plugins/screenclip`. To add only the MCP server, without the skill, run `claude mcp add screenclip -- python3 /absolute/path/to/plugins/screenclip/server.py`. See [Claude Code](../../docs/agents/claude-code.md#reading-the-queue-interactively-plugin) for the workflow and verification status, and [Coding agents](../../docs/agents/README.md) for how the plugin relates to automatic dispatch.

The default data folder is `~/Library/Application Support/ScreenClip`. For a development instance, set `SCREENCLIP_DATA_DIR` on the server process. Tools:

- `task_summary(project?)`: how many reports are **open** (draft, needsProject, queued), **in progress** (working, prOpen), **blocked** (needsYou, failed), and **done** (merged, verified, canceled), plus the blocked reports. Start here.
- `list_projects()`: each project's name, repository path, base branch, whether a validation command is set (`hasValidationCommand`; the command itself is left out because it can hold tokens), whether fixes commit their Before / After screenshots to the repository (`commitsScreenshots`), whether a settings proposal is waiting (`settingsProposalPending`), and the same counts.
- `propose_project_settings(project, validation_command?, base_branch?, reason?)`: proposes a project's validation command or base branch. ScreenClip refuses to publish a fix until a project has a validation command, so an agent can propose one when reports are blocked on it. The server writes the proposal to `proposals/<id>.json` in the data folder and nothing else. ScreenClip shows it in the menu bar popover, on the project in the queue sidebar (orange dot), on reports blocked by the missing command, and above the project's settings, with **Accept** and **Reject**. Accepting saves the settings and continues the reports that were waiting for a validation command. A newer proposal for the same project replaces the waiting one, and a proposal the project already matches is dropped.
- `close_issue(issue_id, summary, resolution?, pull_request?, commit?)`: closes a report the agent resolved itself. `done` (the default) needs a `pull_request` https URL or a `commit` SHA showing where the fix landed and marks the report merged. A `pull_request` is checked with GitHub first: it must be merged into the project's base branch, in the project's own repository; otherwise the report stays as it was and an activity line starting with `Not closed:` says why; `canceled` is for duplicates or reports that no longer apply. The server writes `closures/<id>.json` in the data folder; ScreenClip applies it within about 15 seconds, stopping any run still working on the report and recording the summary on its timeline. The worktree and branch are kept. ScreenClip also finds such a fix on its own when the merged pull request's title or body names the report as `ScreenClip #N`.
- `list_issues(project?, status?, include_closed=false, limit=50)`: non-archived reports with report numbers, project, group, agents, and statuses, most recently updated first. `status` takes a group (`open`, `in_progress`, `blocked`, `done`) or one status. Merged, verified, and canceled reports are left out unless `include_closed` is true or `status` names them. The `agent` value is `codex`, `claude`, or `external` (Grok Bot). Older issues with no agent field are reported as Codex.
- `get_issue(issue_id, include_images=false, activity_limit=20)`: issue context, the most recent activity entries (with `activityCount` for the total), and optional approved images. Accepts a UUID or report number such as `#234` or `234`, including archived reports. Original captures and private settings are excluded.

`project` takes a project name or any path inside the project's repository: a subfolder, a linked Git worktree, or a ScreenClip worktree. An agent passes its working directory. Relative paths such as `.` resolve against the folder the agent started the server in. When projects are nested, the deepest one wins. An unknown project returns the list of known names.

Image inclusion requires the JSON boolean `true`. Strings such as `"false"`, numeric flags, and other mistyped arguments return a parameter error; they never opt a request into screenshot delivery.

The documentation index is [docs/README.md](../../docs/README.md). Grok Bot setup, including the webhook paste, is in [Grok Bot](../../docs/agents/external-assistant.md).

Example: “Use ScreenClip to show the observations that need my input.” Do not manually start another fix for an issue already marked Working.

For a quick review without configuring MCP, run `python3 scripts/review_queue.py --project ScreenClip --details` from the repository. It reads the live SQLite snapshot in read-only mode, groups reports by status, shows pending questions and errors, and checks for missing project validation or an origin remote. Use `--include-archived`, `--search "text"`, `--check-worktrees`, or `--json` as needed. `SCREENCLIP_DATA_DIR` and `--data-dir` select a development queue. This command never dispatches, retries, archives, or changes reports.

Only Verified and Canceled reports are suggested as archive candidates. Merged reports still need retesting; an agent's implemented result or an archived Codex chat does not establish that a fix was merged or verified. Use the native queue's Archive action to retain evidence with the report. Archiving a report and archiving its Codex chat are independent actions.

The plugin has been tested over stdio; installation into the public directory is not part of this build. Local MCP public submission is subject to [OpenAI's desktop-only plugin requirements](https://developers.openai.com/plugins/deploy/desktop-only).
