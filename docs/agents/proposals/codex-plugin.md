# Proposal: Codex plugin and desktop handoff research

Status: research notes from before the native worker was built. Updated: November 14, 2026. Part of [Coding agents](../README.md). The current Codex integration is described in [codex.md](../codex.md).

## Desktop handoff requirements

The documented app-server interface is an agent integration, not a promise of remote control over the running desktop UI. Test all of the following before selecting it as the production route:

1. An externally created local thread is recognized by the installed desktop app, has the correct project/worktree, and opens through its exact deep link.
2. Images and context remain available after process restart.
3. Questions, agent updates, and replies made from either ScreenClip or the desktop chat reconcile without competing turns.
4. Disconnects, login renewal, and desktop/worker ownership changes recover without duplicate chats or jobs.
5. The capabilities needed for the companion plugin load in the selected worker configuration.

If desktop registration fails, record the failure and revisit the integration. An embedded transcript or a manually submitted new-chat link may help development, but neither satisfies the confirmed automatic pickup plus exact desktop-chat requirement. Do not write to Codex's private databases or automate chat creation with keystrokes as a production shortcut.

## Could this be a Codex plugin?

Yes: a companion plugin is a plausible way to expose ScreenClip's issues to Codex and package the fix workflow. [Plugin architecture](https://developers.openai.com/plugins/concepts/plugins) supports skills, MCP tools, and optional UI. The native app still owns its macOS shortcut, capture overlay, annotations, and menu bar.

Candidate tools, to validate with the prototype:

| Tool | Purpose |
| --- | --- |
| `list_issues` / `get_issue` | Read issues, approved evidence, context, and revisions |
| `claim_issue` | Atomically claim an issue revision and return a renewable lease |
| `bind_thread` | Associate a real, validated Codex chat ID with the claimed issue |
| `post_update` | Append a concise update linked to the active run |
| `ask_question` | Persist a question and its correlation ID |
| `get_replies` | Read replies in order, acknowledging delivery separately |
| `record_result` | Submit validation and PR references for independent verification |

These are proposed ScreenClip tools, not existing Codex endpoints. Restrict them to registered projects and approved evidence. Make mutations idempotent and revision-aware. Prefer a local broker that owns the store over multiple clients writing SQLite directly; prototype its authenticated local IPC before choosing a transport.

There are three distinct plugin options:

| Option | Fit | Limit to account for |
| --- | --- | --- |
| Skills and queue tools | Shared workflow and two-way status in Codex | Does not alone prove automatic creation/dispatch of issue chats |
| Lifecycle hooks | Optional private experiment for lifecycle updates | Manual desktop installs and hook trust review; not a public-release dependency |
| Hosted MCP Events | Event-driven pickup through a plugin | Cloud-oriented execution, hosted service, subscriptions, and chat-routing semantics need evaluation |

[MCP Events](https://developers.openai.com/plugins/build/mcp-events) can deliver feedback events into a subscribed Work chat, including workflows that produce PRs. Current support is documented for web Work, desktop Work with Cloud selected, and dots. This does not establish equivalent local Codex behavior or one new chat per issue; test those requirements separately.

Public distribution changes the choice. [Plugin packaging](https://developers.openai.com/plugins/build/plugins#bundled-mcp-servers-and-lifecycle-hooks) says hook-bearing plugins are ineligible for the public directory. [Desktop-only plugin submission](https://developers.openai.com/plugins/deploy/desktop-only) currently limits local MCP submissions to approved partners. A private local prototype can explore a plugin, but public availability cannot depend on obtaining that approval without confirming eligibility.

Recommendation: prove the native app plus local worker first; evaluate queue tools/skills as a companion in the same integration milestone. Keep a hosted event route as an explicit alternative if the local route cannot meet desktop-chat requirements. A hosted route would require a separate decision about backend operations and uploaded screenshot storage.
