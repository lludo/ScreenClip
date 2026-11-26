# ScreenClip roadmap

Updated: November 16, 2026. The local app is working: capture, markup, the queue, Codex and Claude Code dispatch, the Grok Bot hand-off, validation, PRs, and guarded merges. This page lists engineering work that is still open. What has been verified is in [validation](validation.md). Release and publishing items that are not done are only listed in [Publishing checklist](release/publishing-checklist.md). Product choices that used to be open are in [Decisions](product-spec.md#decisions).

## Open gates

| Area | What is left | Notes |
| --- | --- | --- |
| Capture, hands-on | Each physical monitor, mixed scales, negative display origins, full-screen Spaces, transient menus, Escape, return-to-source focus, and every ScreenClip surface with hiding on and off | A selection spanning two displays is not implemented |
| Claude Code, live | A real Claude fix through validation, PR publication, and merge; permanent plugin installation; an interactive plugin fix | Covered today by fake-CLI tests. See [Claude Code](agents/claude-code.md#verification-status) |
| Grok Bot, live | A live webhook, an evidence push to a real repository, pull-request discovery, and auto-merge with other `.screenclip/` files left in place | Covered today by unit and app tests. See [Grok Bot](agents/external-assistant.md#verification-status) |
| Codex desktop | Sidebar project grouping for chats created through app-server | Fails on the tested Codex version; exact chat links work. See [repository association review](validation.md#repository-association-review) |
| Release signing | Developer ID signing and notarization from the tag workflow | The v1.0.0 app and DMG were signed and notarized locally ([readiness](release/v1.0.0-status.md)). Release builds already enable the hardened runtime, and the Apple Events entitlement is in `Resources/ScreenClip.entitlements`. Debug builds leave the hardened runtime off. The tag workflow is in [direct distribution](release/direct-distribution.md). The Apple secrets are not configured ([open TODOs](release/publishing-checklist.md#release-secrets)). |
| Installation | Clean second Mac or user account; a separately installed Codex CLI; older macOS; Intel | Only the development host has been exercised |
| Plugin distribution | Public directory eligibility for Codex; publishing the Claude Code marketplace | Local installation works; the app does not depend on the plugin |

## Next features

- **Usage per agent.** Claude Code turns already log tokens and cost as `usage` activities. Record Codex usage too, then aggregate by agent and project so you can see which agent to use.

## Maintenance backlog

- **Codex client handoff.** A chat owned by another live Codex client can prevent ScreenClip from resuming after a restart. Reports can remain **Needs you**, or fail with an active-writer error. Add an automatic waiting/reconciliation path that preserves the other client's work and adopts its completed result; never force a second writer.
- **Routing memory.** Learned app identifiers are stored like hand-entered ones, so a later pick of a different project cannot replace a learned mapping, and moving a report does not unlearn it. Edit the project's bundle IDs in Settings to correct one. Store learned identifiers separately.
- **Grok Bot recovery.** Restart recovery reads activity wording to decide whether the current revision was delivered. Persist the delivered revision instead.
- **Sidebar counts with search.** Counts follow the selected project but ignore search text.
- **Settings form.** The form still edits a copy of all settings. Detect, Check, and Sign-in buttons save half-edited fields. Move to a draft model that saves only edited fields.
- **Capture timing.** Browser URL lookup (AppleScript, up to 2 seconds) runs before the screen freezes. Freeze first, then look up the URL in the background.
- **Annotation scale.** Minimum text size and the legacy stroke minimum are in canvas points on screen but pixels in the exported PNG, so small crops export relatively larger labels.
- **Thumbnails.** Queue rows decode full-size PNGs on the main thread. Add a thumbnail cache.
- **Store versioning.** 1.0 refuses a queue whose `minimumReaderVersion` is above 1, so a later build can protect new fields by raising it. New fields are added as optionals while the snapshot version stays at 1, so an older build can drop newer fields on save. Bump a minimum-reader version when fields are added.
- **Naming.** `AppSettings.model` is the Codex model (`claudeModel` is Claude's). Rename with a decoding migration.
- **Retention.** Screenshots and notes stay until the report is deleted. There is no expiry setting.
- **Probe.** `ScreenClipProbe` exercises only Codex and is a manual smoke test.
- **PR branch changed on GitHub.** When someone updates a Codex or Claude Code pull request's branch on GitHub (Update branch, a committed review suggestion), the report says the PR changed and the next push is rejected as non-fast-forward. Fetch the branch before publishing, fast-forward when only the remote moved, and validate again.
- **GitHub sign-in check.** `gh auth status` is run without a host, so a stale login for another host or account can block publishing even when github.com is signed in.
- **Login-shell PATH.** The PATH is read from the login shell once per launch with a five-second limit. A slow shell start leaves agents installed under nvm or Volta undetected until relaunch.
- **Claude Code result after the time limit.** A result the CLI printed is discarded if the process then lingers until the watchdog stops it.
- **Untranslated.** The signed-out detail under Settings → Connections is English in every language.
- **Add project from a report.** **Add project…** on a Needs-project report opens Settings on General instead of Projects.

Agent progress lines already go through `AppModel.updateIssueSoon`, which updates memory immediately and saves within a second. State changes still save at once.

## How we verify

Repeated, low-friction capture is the core acceptance path: move through an app, capture a sequence of small observations with optional notes, and keep going after each submit. Background work and questions must never block the next capture. A successful automatic fix does not prove that experience.

- **Automated tests** protect durable behavior: lifecycle transitions, badge counts, atomic submit and recovery, routing, idempotency, run ownership, input revisions, merge eligibility, process timeouts, and agent protocol handling against fake CLIs.
- **Integration checks** exercise the real agent and GitHub contracts in disposable fixture repositories.
- **Hands-on checks** cover screen permissions, geometry, keyboard and focus, annotations and redaction, Spaces, and clean installation. A passing model-layer test does not establish a working capture experience.
