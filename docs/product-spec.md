# ScreenClip product specification

Updated: November 13, 2026. Status: implemented local app; confirmed decisions and proposed future behavior. See [validation evidence](validation.md) for exact coverage and remaining hands-on checks.

## Problem and intended outcome

During a testing flow, the tester notices many small problems. Each screenshot currently requires a manual trip to chat, context reconstruction, image attachment, and chat organization. Those interruptions break the flow, and details are forgotten before the issue is reported.

ScreenClip should make reporting a brief interruption and keep the whole feedback loop visible: observation, investigation, questions, implementation, testing, pull request, merge, and retest.

Example: while testing a checkout flow, the tester spots a clipped button, selects it, writes “Label is cut off at this width,” and submits. Work begins in the background. Later, the menu bar shows either a question or a merged fix, with a link to the issue's Codex chat and PR.

## Confirmed requirements

| Decision | Agreed behavior |
| --- | --- |
| Platform | macOS only |
| Apps being tested | Websites and native macOS apps |
| Entry point | Menu bar utility plus a global keyboard shortcut |
| Capture | Region selection resembling Command–Shift–4 |
| Composer | Screenshot overlay with a short description and image annotations |
| Capturing ScreenClip itself | Keep its windows and menu bar popover available; provide a setting to hide/exclude them |
| Submission | Save to the queue and begin AI work immediately |
| Organization | One chat per issue; related captures share that issue |
| Project routing | Infer from app/browser context; user can correct it |
| Visibility | Counts, statuses, and links to the correct Codex chat |
| Agent outcome | Implement, test, open a PR, and merge when checks pass |
| Communication | Follow-up questions and completion feedback |
| Audience | Eventual public distribution |
| Integration exploration | Consider Codex's plugin system |

Everything below is a proposed implementation or interaction choice unless covered by this table.

## Capture and submission

1. Invoke a configurable global shortcut. Proposed initial shortcut: Command–Shift–2, subject to availability; the built-in screenshot shortcut stays available.
2. Preserve the source app and available context before ScreenClip takes focus.
3. Show a crosshair and region selection. Escape cancels. The selection should work across multiple monitors, Retina scales, and full-screen apps.
4. Show a compact overlay with the image, a focused note field, an inferred project chip, and an issue destination: **New issue** or **Add to issue…**.
5. Immediately offer freehand marks, arrows, rectangles, circles/ellipses, text, color and stroke-thickness choices, undo/redo, and an opaque redaction tool. Notes and annotations are optional; allow an image-only observation.
6. Submit using the primary button or Command–Return. Persist the report before acknowledging success, dismiss the overlay, and return focus to the tested app.
7. Dispatch immediately when routing and connectivity permit. A paused, offline, or ambiguous report remains saved with a clear reason.

The normal path should not require a title, severity, reproduction template, repository picker, or new chat creation. ScreenClip can derive an editable title from the note. Enter inserts a newline in the note.

Cancel after editing offers to save a draft when content would be lost. A second shortcut invocation must not overwrite an unfinished draft.

## Preserving testing context

Group captures into a lightweight testing session for a project. Project inference should reduce setup; a session name such as “Checkout on narrow window” is optional.

Attach a snapshot of the following context when available:

- Capture time, source app identity, selected window title, region, display scale, and image dimensions.
- Project/repository and the routing evidence used to select it.
- Browser URL and viewport when a supported, authorized adapter can supply them.
- Testing session name, capture sequence, and any session note supplied by the user.
- Known tested build/version or Git revision, with its source and confidence. A checkout's current HEAD alone does not prove which build is running.

Keep capture-time context immutable even if the user switches apps or the agent changes the repository later. Related issues can share session context without sharing one giant conversation. Supply only relevant neighboring captures to an agent; do not automatically send unrelated issues.

There is no continuous screen recording in the first version. ScreenClip cannot reconstruct actions that were never captured. A small crop may need an optional second, wider screenshot or a follow-up question.

## Automatic project inference

Register a local repository once, then associate it with website origins/path patterns, local development ports, or native app identifiers. Let the user teach or correct these mappings during setup and from the overlay.

Show the inferred destination before submission. Prefer explicit saved mappings and a user-selected session over guesses from window titles. A browser's app identity alone cannot identify which web project is being tested.

If evidence is missing or conflicting, save the submission as **Needs project** and offer a quick correction. Never start coding in a guessed repository. A correction to an issue already in progress pauses dispatch, retains its history, and asks how to handle any work already produced; it must not silently move edits between projects.

## Menu bar and issue view

Proposed compact menu bar label: icon plus the count of submitted, unresolved issues. A separate attention indicator signals questions, failures, or routing problems. The popover provides explicit counts by state; color alone must not carry meaning.

| Surface | Contents and actions |
| --- | --- |
| Menu bar popover | Current project/session, New capture, Pause processing, status totals, recent issues, Open queue, Settings |
| Issue row | Thumbnail, short title, project, status, latest update, unread indicator |
| Issue detail | Ordered images and notes, captured context, concise activity, questions and replies, Codex link, PR link, validation result |
| Queue window | All issues, project/status filters, search, drafts, archive |

The queue has resizable panes with a status filter and feedback search above the report list. Search includes capture notes, questions, replies, results, and activity. Archive and Restore are available directly in report details and the report row's context menu; archiving retains screenshots, status, and PR/merge evidence. Active work and outstanding agent permission requests must be canceled or resolved before archiving. The composer uses the regular macOS close control with its existing discard confirmation.

Counts represent issues, so adding a second screenshot to an existing issue does not increment the count. Drafts are counted separately. **Merged** issues leave the active count and appear under **To retest**. Keep row positions stable during updates; offer explicit sorting and filtering.

Notify on a question, blocked run, or completed merge. Do not interrupt testing with a notification for every agent action. Clicking a notification opens the relevant issue. Notification permission is optional; the queue remains usable without it.

## Issue lifecycle

| State | Meaning |
| --- | --- |
| Draft | Local report that has not been submitted |
| Needs project | Saved, but the target project is unresolved |
| Queued | Submitted; waiting for the worker, connectivity, capacity, or resume |
| Working | Agent investigating, editing, testing, or repairing checks |
| Needs you | Agent needs an answer or an action that its configured permissions do not allow |
| PR open | A PR exists; CI, review requirements, or mergeability are pending |
| Merged | The hosting service confirms the PR was merged |
| Verified | Tester confirmed the fix in the relevant running build |
| Failed | Processing stopped with a recoverable or explained error |
| Canceled | Further agent work was stopped; existing files/PRs remain inspectable |

Archiving is an independent visibility setting. A run also records a finer stage such as investigating, implementing, testing, or waiting for CI.

A completed agent turn does not prove that a fix works or that a PR merged. “Merged” does not mean deployed, rebuilt, or manually verified. If the user reports “still broken,” reopen the same issue/chat with a new capture and the version tested. A merged PR remains part of its history; a further fix uses a new PR.

## Agent workflow

1. Claim the issue, retrieve the submitted image and context, and open or resume its Codex chat.
2. Investigate and reproduce where practical. Ask a focused question if the intended behavior is unclear; do not invent it.
3. Work in an isolated Git worktree and branch; preserve the tester's checkout and local changes.
4. Implement and run the repository's relevant validation, including a visual check when the issue is visual and the environment supports it.
5. Open a PR with a concise explanation and evidence. Screenshots stay private by default; attaching them to a public PR is a separate sharing choice.
6. Repair failing checks where possible. Merge automatically once configured verification passes and hosting-service policies allow it. Do not bypass required checks or reviews.
7. Return a concise result: what changed, tests run, PR/merge reference, and how to retest. Show deployment/build status only when independently known.

Related captures received during work are appended to the same issue. Track their revision so the agent cannot mark the issue complete against an outdated set of observations.

## First usable release

Include region capture, a quick composer, core annotations, project mapping/inference, local persistence, issue grouping, immediate Codex dispatch, status updates, inline questions, exact chat links, PR/merge tracking, retry/cancel/pause, and restart recovery.

Defer video, voice notes, scrolling screenshots, browser DOM/console/network capture, automatic duplicate merging, other operating systems, other AI providers, and team assignment/shared queues. Public packaging and updates follow the working personal prototype; public distribution remains an architectural requirement.

## Remaining decisions

These are open product choices, with proposed defaults so implementation can proceed after the integration prototype:

| Question | Proposed default |
| --- | --- |
| Which source-control host first? | GitHub, behind a provider interface |
| Which browsers first? | Safari and Chrome; confirm how URL access is granted during the native prototype |
| Local execution or a hosted plugin/event service? | Local Codex worker first; evaluate the plugin as a companion |
| Should a merge refresh/relaunch the app under test? | Notify and offer a retest action; keep the running testing session stable |
| Can AI ask and receive replies inside ScreenClip? | Yes, with an Open in Codex action for longer discussion |
| Old screenshots and notes? | Retain locally until deletion; add a configurable retention policy before public release |
| Minimum supported macOS? | macOS 14+ candidate; verify every chosen API and the worker's requirements |
| Distribution channel? | Direct signed/notarized download first; evaluate App Store feasibility separately |
| Product name, shortcut, pricing? | ScreenClip is a working name; shortcut configurable; pricing undecided |

## Release acceptance examples

- Report several issues during one flow without manually opening a chat or re-entering shared context.
- Add evidence to an existing issue and retain its one chat and capture order.
- Switch between two projects in the same browser; correct a mapping before dispatch.
- Restart while offline and recover every acknowledged submission and annotation.
- Reply to an agent question in ScreenClip and continue the same issue.
- See a PR, then a confirmed merge, then separately verify the fix after rebuilding or deploying.
- Stop a run without deleting a PR or changing the user's testing checkout.
