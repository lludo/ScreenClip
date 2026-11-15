# Claude Code and Grok Bot handoffs

These prompts are for the user to give to Claude Code and Grok Bot. They ask each agent to investigate its own integration with ScreenClip and, where it can safely do so, improve and validate it. They do not authorize sending credentials, private Codex state, screenshots, or repository access to a remote service. The user chooses what to share.

## Claude Code

```text
Please investigate and improve ScreenClip's Claude Code integration in this repository. The goal is for ScreenClip-created Claude sessions to be easy to find and continue in Claude's desktop app, associated with the right project, while keeping each report's isolated worktree and preventing concurrent writers.

Start with docs/agents/claude-code.md, Sources/ScreenClip/AgentWorker+Claude.swift, Sources/ScreenClipCore/ClaudeCodeClient.swift, and the agent tests. ScreenClip currently runs one headless `claude -p` process per turn, chooses a session UUID, and exposes a Terminal resume command. Check the installed CLI version and current official Claude documentation before relying on desktop features: the version observed on November 14, 2026 was 2.1.128, which did not list `--desktop`; current documentation describes `claude --desktop --resume <session-id>` on newer supported versions. Do not update the user's installation without their instruction.

Determine through a disposable test whether a headless session created in a separate worktree appears under the intended project in Claude Desktop, and whether it can be opened in the same session after the worker finishes. Do not assume CLI and Desktop session lists are identical. If there is a supported integration, implement capability detection and a clear fallback for older CLI versions, handle a running session safely, and test the success, unsupported-version, and error paths. Do not change sandbox or approval policies without explaining the effects. Keep unrelated changes and existing user data intact.

Run focused automated tests and a safe end-to-end test when possible. Report exactly what was verified in the real desktop app, what still requires user action, and any remaining limitations. Do not send screenshots, credentials, private session history, or repository content elsewhere unless the user separately authorizes it.
```

## Grok Bot

```text
Please investigate and improve the Grok Bot side of the ScreenClip integration. The goal is for a ScreenClip report to reach the right repository and for the user to find the corresponding Bot conversation or pull request easily, including on retries and follow-up revisions.

Read docs/agents/external-assistant.md and, if this repository is available to you, Sources/ScreenClip/AgentWorker+External.swift and Sources/ScreenClipCore/ExternalAssistant.swift. ScreenClip sends schema `screenclip.external.v1` after pushing approved evidence to a report-specific branch; it identifies the repository, branch, report number, and revision, and tracks a matching pull request. The connection is configured by the user. The existing integration does not receive a durable report-specific conversation identifier and cannot cancel a remote run.

Check current official Grok Bot documentation and your actual bot's available interfaces. The documented `grokbot://app/v1/prompt` opens a Bot and optionally prepares an unsent message; do not present it as a report-specific link or automatic delivery. Determine whether the webhook can reliably return or later expose a stable bot/conversation/run ID and a supported link; whether that ID survives retries and revisions; and whether the bot can provide progress, questions, and cancellation. Propose or implement a backward-compatible protocol only for capabilities that actually exist. Provide examples with dummy values; never disclose or paste the connection secret.

Before performing a live handoff, confirm with the user which test repository and approved synthetic evidence may be sent. Use a private test repository if authorized. Verify that duplicate revision delivery is idempotent, follow-ups reach the intended report, and the PR matches the correct branch and report. Do not push real screenshots or change production repositories without authorization. Report the verified capabilities, precise setup steps, and any changes ScreenClip needs on its side.
```

## Shared Codex context

The Codex sidebar issue is separate from either agent's own session system. ScreenClip's Codex app-server thread has a runtime project assignment, but Codex desktop has not consistently placed it in its sidebar project. The [repository association review](../validation.md#repository-association-review) records the actual and isolated-copy tests. Do not edit a running Codex desktop's private state or clear its migration checkpoint as a workaround. Any proposed repair needs an isolated reproduction, backups, safe handling of active chats, and verified desktop sidebar readback.
