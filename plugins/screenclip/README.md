# Optional ScreenClip plugin

This local MCP plugin lets a Codex or Claude Code session read the queue, notes, approved screenshots, and status. Grok Bot does not install this plugin; its questions stay in Grok Bot's chat. The native ScreenClip app owns automatic dispatch, replies, publication, and merge verification. This bridge is read-only to avoid competing agents and queue writers.

Requires Python 3.9+ and local execution. Add this folder to a local plugin marketplace using the supported Codex plugin setup, or configure the MCP server directly in Codex with `python3 /absolute/path/to/plugins/screenclip/server.py`. No cloud service or lifecycle hook is required.

Claude Code: the repository root is a local plugin marketplace (`.claude-plugin/marketplace.json`). Install the plugin, which bundles the same MCP server and a `fix-report` skill for interactive fixes:

```sh
claude plugin marketplace add /absolute/path/to/ScreenClip
claude plugin install screenclip@screenclip
```

For one session only, run `claude --plugin-dir /absolute/path/to/plugins/screenclip`. To add only the MCP server, without the skill, run `claude mcp add screenclip -- python3 /absolute/path/to/plugins/screenclip/server.py`. See [Claude Code](../../docs/agents/claude-code.md#reading-the-queue-interactively-plugin) for the workflow and verification status, and [Coding agents](../../docs/agents/README.md) for how the plugin relates to automatic dispatch.

The default data folder is `~/Library/Application Support/ScreenClip`. For a development instance, set `SCREENCLIP_DATA_DIR` on the server process. Tools:

- `list_issues(status?, include_closed=false, limit=50)`: open, non-archived reports with report numbers, agents, and statuses, most recently updated first. Merged, verified, and canceled reports are left out unless `include_closed` is true or `status` names them. The `agent` value is `codex`, `claude`, or `external` (Grok Bot). Older issues with no agent field are reported as Codex.
- `get_issue(issue_id, include_images=false, activity_limit=20)`: issue context, the most recent activity entries (with `activityCount` for the total), and optional approved images. Accepts a UUID or report number such as `#234` or `234`, including archived reports. Original captures and private settings are excluded.

The documentation index is [docs/README.md](../../docs/README.md). Grok Bot setup, including the setup code, is in [Grok Bot](../../docs/agents/external-assistant.md).

Example: “Use ScreenClip to show the observations that need my input.” Do not manually start another fix for an issue already marked Working.

For a quick review without configuring MCP, run `python3 scripts/review_queue.py --project ScreenClip --details` from the repository. It reads the live SQLite snapshot in read-only mode, groups reports by status, shows pending questions and errors, and checks for missing project validation or an origin remote. Use `--include-archived`, `--search "text"`, `--check-worktrees`, or `--json` as needed. `SCREENCLIP_DATA_DIR` and `--data-dir` select a development queue. This command never dispatches, retries, archives, or changes reports.

Only Verified and Canceled reports are suggested as archive candidates. Merged reports still need retesting; an agent's implemented result or an archived Codex chat does not establish that a fix was merged or verified. Use the native queue's Archive action to retain evidence with the report. Archiving a report and archiving its Codex chat are independent actions.

The plugin has been tested over stdio; installation into the public directory is not part of this build. Local MCP public submission is subject to [OpenAI's desktop-only plugin requirements](https://developers.openai.com/plugins/deploy/desktop-only).
