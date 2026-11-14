# Optional ScreenClip plugin

This local MCP plugin lets a Codex chat read the queue, notes, approved screenshots, and status. The native ScreenClip app owns automatic dispatch, replies, publication, and merge verification. This bridge is read-only to avoid competing agents and queue writers.

Requires Python 3 and local execution. Add this folder to a local plugin marketplace using the supported Codex plugin setup, or configure the MCP server directly in Codex with `python3 /absolute/path/to/plugins/screenclip/server.py`. No cloud service or lifecycle hook is required.

The default data folder is `~/Library/Application Support/ScreenClip`. For a development instance, set `SCREENCLIP_DATA_DIR` on the server process. Tools:

- `list_issues(status?)`: non-archived issues, report numbers, and statuses.
- `get_issue(issue_id, include_images=false)`: issue context and optional approved images. Accepts a UUID or report number such as `#234` or `234`, including archived reports. Original captures and private settings are excluded.

Example: “Use ScreenClip to show the observations that need my input.” Do not manually start another fix for an issue already marked Working.

For a quick review without configuring MCP, run `python3 scripts/review_queue.py --project ScreenClip --details` from the repository. It reads the live SQLite snapshot in read-only mode, groups reports by status, shows pending questions and errors, and checks for missing project validation or an origin remote. Use `--include-archived`, `--search "text"`, `--check-worktrees`, or `--json` as needed. `SCREENCLIP_DATA_DIR` and `--data-dir` select a development queue. This command never dispatches, retries, archives, or changes reports.

Only Verified and Canceled reports are suggested as archive candidates. Merged reports still need retesting; an agent's implemented result or an archived Codex chat does not establish that a fix was merged or verified. Use the native queue's Archive action to retain evidence with the report. Archiving a report and archiving its Codex chat are independent actions.

The plugin has been tested over stdio; installation into the public directory is not part of this build. Local MCP public submission is subject to [OpenAI's desktop-only plugin requirements](https://developers.openai.com/plugins/deploy/desktop-only).
