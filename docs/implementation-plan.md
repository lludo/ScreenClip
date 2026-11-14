# ScreenClip implementation plan

Updated: November 13, 2026. Implementation and live integration testing are complete for the local app. Hands-on screen-capture permission/monitor checks and public-release credentials remain. See [validation evidence](validation.md).

## 1. Prove the Codex handoff

Resolve the main uncertainty before building the whole interface.

- Select a working, supported Codex runtime; the globally installed launcher currently fails with a missing native binary.
- Use a disposable repository and a synthetic screenshot for the experiment.
- Exercise image submission, persistent chat identity, progress, a question/reply, cancellation, restart, and a resumed result.
- Open the exact externally created chat in the desktop app and verify project/worktree ownership.
- Try a reply from the desktop chat, then reconcile it in the client without duplicate turns.
- Evaluate a minimal companion plugin with issue retrieval and status reporting; test a manually installed local route before assuming public distribution.
- If exploring MCP Events, separately verify account eligibility, Cloud execution/local repository access, and creation of one chat per issue. Receiving events in a shared monitoring chat is insufficient.

Exit evidence: a short recorded result for each experiment, runtime versions, supported route, and unresolved limitations. Do not mark the Codex integration feasible end to end until automatic pickup, questions, exact desktop links, and recovery have passed. If the route fails, propose a concrete alternative and identify any changed product behavior.

## 2. Build the native capture loop

Create the macOS app target, signing identity for local development, menu bar entry, configurable shortcut, region selector, and composer. Start with a local stub worker so capture behavior can be exercised independently of model access.

Add focused notes, core annotations/redaction, undo/redo, visible project/issue destination, durable submit, draft recovery, and return-to-app focus.

Exit evidence: capture a real region, annotate it, submit it, immediately make another capture, and reopen both after app restart. Exercise denied permission, Escape, full-screen apps, two monitors with different scales, and transient menus. Confirm overlays never appear in the captured result and redacted pixels are absent from the agent-visible derivative.

## 3. Preserve context and infer the project

Add registered repositories and routing rules, source-context snapshots, testing sessions, **Add to issue**, and a correction control. Prototype URL access for the selected browsers and disclose required permissions during setup.

Exit evidence: alternate between a website and a native app, then between two repositories in the same browser. Confirm routing decisions and capture-time context. An unknown/conflicting project saves successfully but cannot dispatch until resolved.

## 4. Connect the queue and agent

Implement the proven adapter, outbox, run leases, input revisions, issue/chat binding, concise status updates, inline questions, reply delivery, retry/cancel/pause, and notification actions. Keep raw transport messages out of the normal user interface.

Exit evidence: submission starts automatically and creates exactly one issue chat. Related captures and answers continue it. Reconnect after lost acknowledgments without duplicate jobs. New evidence received during work prevents completion against an old revision. Desktop-side activity reconciles into ScreenClip.

## 5. Complete one fix through merge

Implement isolated worktree creation, validation configuration, source-control authentication, PR tracking, current-head checks, merge policy, and verified host outcomes. GitHub is the proposed first provider.

Use a disposable private repository for the first full exercise. Deliberately fail a check, repair it, merge, and notify with retest instructions. Also exercise an unmet review requirement, a conflicting base change, a failed run, and a user question. Preserve the tested checkout throughout.

Exit evidence: a captured observation leads to a tested PR and a confirmed merge, with accurate links and status. An agent success message, stale green check, or absent check configuration cannot alone cause a merge. Retesting closes the loop separately.

## 6. Prepare public distribution

Resolve the supported macOS baseline and runtime packaging, then sign/notarize the app and test clean installation on a second Mac or clean user account. Add onboarding for screen capture, project mappings, Codex/source-control sign-in, validation/merge policy, and optional notifications/login item.

Confirm a public plugin distribution route before making it a required dependency. Ship without lifecycle hooks as a requirement. If local MCP directory access remains restricted, choose a supported optional/local setup or evaluate a hosted plugin; document the user's actual installation path.

Add updates, runtime compatibility checks, local deletion/retention controls, export/recovery, and clear offline/quit/sleep behavior. Separate private capture storage from public PR descriptions. Resolve licensing and redistribution terms before bundling third-party runtimes.

Exit evidence: a new user can install, register a project, capture, follow questions, open the exact Codex chat, and receive a merged result without hidden developer setup.

## Focused verification

Use automated checks where they protect durable behavior: lifecycle transitions, badge counts, atomic submit/recovery, routing ambiguity, idempotency, run ownership, input revisions, and current-head merge eligibility. Exercise failure injection for lost responses and process restarts.

Use integration checks for the actual Codex and Git provider contracts. Use hands-on macOS verification for capture permissions, screen geometry, keyboard/focus behavior, annotations/redaction, Spaces, and clean installation. A passing model-layer test does not establish a working capture experience.

## Next concrete deliverable

A local app bundle and ZIP are generated under `build/`. Complete the user's first capture with macOS permission granted, then test monitor/Spaces behavior on their setup. Public distribution next needs Developer ID signing/notarization, a clean second-machine installation, and runtime compatibility coverage. Product choices still open are tracked in the [product specification](product-spec.md#remaining-decisions). The user's confirmed submission, grouping, project-inference, and automatic-merge choices should not be asked again.
