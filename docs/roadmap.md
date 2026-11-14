# ScreenClip roadmap

Updated: November 14, 2026. The local app is working: capture, markup, the queue, Codex and Claude Code dispatch, validation, PRs, and guarded merges. This page lists what is still open. What has been verified is in [validation](validation.md). Product questions are under [remaining decisions](product-spec.md#remaining-decisions).

## Open gates

| Area | What is left | Notes |
| --- | --- | --- |
| Capture, hands-on | Each physical monitor, mixed scales, negative display origins, full-screen Spaces, transient menus, Escape, return-to-source focus, and every ScreenClip surface with hiding on and off | A selection spanning two displays is not implemented |
| Claude Code, live | A real Claude fix through validation, PR publication, and merge; permanent plugin installation; an interactive plugin fix | Covered today by fake-CLI tests. See [Claude Code](agents/claude-code.md#verification-status) |
| Codex desktop | Sidebar project grouping for chats created through app-server | Fails on the tested Codex version; exact chat links work. See [repository association review](validation.md#repository-association-review) |
| Release signing | Developer ID signing and notarization | The Xcode target currently has `ENABLE_HARDENED_RUNTIME = NO`. Notarization requires the hardened runtime, and browser URL lookup then needs the Apple Events entitlement (`com.apple.security.automation.apple-events`) |
| Installation | Clean second Mac or user account; a separately installed Codex CLI; older macOS; Intel | Only the development host has been exercised |
| Plugin distribution | Public directory eligibility for Codex; publishing the Claude Code marketplace | Local installation works; the app does not depend on the plugin |

## Next features

- **Usage per agent.** Claude Code turns already log tokens and cost as `usage` activities. Record Codex usage too, then aggregate by agent and project so you can see which agent to use.
- **Per-project default agent.** Today the default is global with a per-report override. A per-project default is likely more natural.
- **External assistant.** A remote hand-off is designed but not built: [proposal](agents/proposals/external-assistant.md).

## Deferred cleanups from the November 2026 review

These were found in a full review and judged lower risk than the fixes that shipped.

- **Settings form.** The form still edits a copy of all settings. Pause state is now preserved and the form reloads each time Settings opens, but Detect, Check, and Sign-in buttons save half-edited fields. Move to a draft model that saves only edited fields.
- **Capture timing.** Browser URL lookup (AppleScript, up to 2 seconds) runs before the screen freezes. Freeze first, then look up the URL in the background.
- **Annotation scale.** Minimum text size and the legacy stroke minimum are in canvas points on screen but pixels in the exported PNG, so small crops export relatively larger labels.
- **Thumbnails.** Queue rows decode full-size PNGs on the main thread. Add a thumbnail cache.
- **Store versioning.** New fields are added as optionals while the snapshot version stays at 1, so an older build can drop newer fields on save. Bump a minimum-reader version when fields are added.
- **Naming.** `AppSettings.model` is the Codex model (`claudeModel` is Claude's). Rename with a decoding migration.
- **Progress writes.** Each Claude progress message saves the whole store. Throttle them.
- **Probe.** `ScreenClipProbe` exercises only Codex and is a manual smoke test.

## How we verify

Repeated, low-friction capture is the core acceptance path: move through an app, capture a sequence of small observations with optional notes, and keep going after each submit. Background work and questions must never block the next capture. A successful automatic fix does not prove that experience.

- **Automated tests** protect durable behavior: lifecycle transitions, badge counts, atomic submit and recovery, routing, idempotency, run ownership, input revisions, merge eligibility, process timeouts, and agent protocol handling against fake CLIs.
- **Integration checks** exercise the real agent and GitHub contracts in disposable fixture repositories.
- **Hands-on checks** cover screen permissions, geometry, keyboard and focus, annotations and redaction, Spaces, and clean installation. A passing model-layer test does not establish a working capture experience.
