# Optional ScreenClip plugin

This local MCP plugin lets a Codex chat read the queue, notes, approved screenshots, and status. The native ScreenClip app owns automatic dispatch, replies, publication, and merge verification. This bridge is read-only to avoid competing agents and queue writers.

Requires Python 3 and local execution. Add this folder to a local plugin marketplace using the supported Codex plugin setup, or configure the MCP server directly in Codex with `python3 /absolute/path/to/plugins/screenclip/server.py`. No cloud service or lifecycle hook is required.

The default data folder is `~/Library/Application Support/ScreenClip`. For a development instance, set `SCREENCLIP_DATA_DIR` on the server process. Tools:

- `list_issues(status?)`: non-archived issues and their statuses.
- `get_issue(issue_id, include_images=false)`: issue context and optional approved images. Original captures and private settings are excluded.

Example: “Use ScreenClip to show the observations that need my input.” Do not manually start another fix for an issue already marked Working.

The plugin has been tested over stdio; installation into the public directory is not part of this build. Local MCP public submission is subject to [OpenAI's desktop-only plugin requirements](https://developers.openai.com/plugins/deploy/desktop-only).
