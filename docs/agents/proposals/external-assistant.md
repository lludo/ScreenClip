# Proposal: external assistant

Status: design proposal, not implemented. Updated: November 13, 2026. Part of [Coding agents](../README.md).

This would add a destination where ScreenClip does not run a local agent at all. It would hand the report to a remote assistant (for example a chat bot such as Grok Bot) that starts a cloud coding agent, and track the outcome through GitHub. It does not fit the local [agent contract](../README.md#the-agent-contract) as written, because the agent would not work in a ScreenClip worktree. It would likely be a separate destination type rather than another `AgentKind`.

## Hand-off

ScreenClip gets an "External assistant" destination with one of two transports:

- **Webhook (preferred).** The assistant exposes a webhook URL plus a sender key. On submit, ScreenClip POSTs JSON: report number, issue UUID, revision, title, note(s), capture context (app, bundle ID, browser URL if allowed), project name, GitHub `owner/repo`, base branch, validation command, and the approved (redacted, annotated) PNG. Whether the PNG can be inline base64 depends on the webhook's payload limit, which is still to be confirmed; if it cannot, upload the image somewhere the assistant can read and send a link instead. Store the URL and key in Keychain.
- **Email.** Send the same content to the assistant's inbox with the PNG attached. Simpler and handles images natively, but slower and harder to correlate.

Never send the unredacted original; only the approved derivative, as the local flow already does.

## What the assistant does

1. Wakes on the webhook or email, reads the screenshot and note.
2. Starts a cloud coding agent on the GitHub repository with the observation, screenshot, and validation command. The branch name and PR body include the report number (for example branch `screenclip/234-<slug>`, body line `ScreenClip: #234`).
3. If something is unclear, asks the user in the assistant's chat.
4. Reports the PR link back to the user, and optionally watches the PR until it merges.

## Closing the loop in ScreenClip

- On successful hand-off, set the issue to a new status such as "Sent" (or reuse `working` with an activity line) and record the assistant as owner.
- `GitHubService` already tracks PRs, checks, and confirmed merges. Add a lookup that finds the PR for an externally handled issue by branch prefix or the `ScreenClip: #234` marker, then reuse the existing `prOpen` → `merged` → "To retest" path. ScreenClip still verifies merges with GitHub itself instead of trusting the assistant's message.
- Questions stay in the assistant's chat in a first version. A later version could add a small authenticated callback or extend the MCP plugin with the proposed `post_update` / `ask_question` / `get_replies` / `record_result` tools so questions also show up under Needs you.

## Trade-offs

- Works while the Mac is asleep, and fixes happen in the cloud rather than in a local worktree.
- The screenshot and note leave the Mac, so this should be opt-in per project, and redaction matters more.
- Auto-merge policy moves to the GitHub side (branch protection, required checks); ScreenClip should only observe the merge.

## Suggested order

1. First version: webhook hand-off plus PR discovery by report number, with questions handled in the assistant's chat.
2. Later: two-way status through the plugin tools or a callback, so remote and local agents report into the same queue UI.

## Open questions

- For this option, which projects may send screenshots off the Mac?
- Does the external assistant also handle merging, or only open the PR and leave merge to ScreenClip's existing policy?
