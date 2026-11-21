# User guide

Capture is the point of the app: notice something, grab it, and keep going. Agent work, pull requests, and retest happen afterward. Status meanings are in the [product specification](product-spec.md#issue-lifecycle).

## Capture

The default shortcut is **⌘⇧2**. Escape cancels the selection. The composer can take a note, freehand drawing, arrows, rectangles, ellipses, text, and an opaque redaction, with undo and redo. A screenshot alone is a valid report. Submit with the primary button or **⌘↩**.

ScreenClip suggests a project from the app or the browser context. Correct it before submitting. If the project is ambiguous, the report is saved as **Needs project** and no agent starts.

In the composer's **Issue** menu, **New issue** starts a report, and choosing an existing issue appends the capture to it. The **Agent** menu also picks the model and reasoning effort in one go: choose an agent to keep its defaults, or open its submenu for a model (**Claude Code ▸ Opus**) and that model's submenu for an effort (**Claude Code ▸ Opus ▸ Extra high**). The default rows name the default when the agent reports it; otherwise the model from Settings applies. Codex lists its own models and efforts once connected; the Claude Code list (Fable, Opus, Sonnet, Haiku) is built in. Grok Bot picks its own model. A follow-up keeps that issue's agent, model, and effort. You cannot switch a submitted issue to a different agent; cancel it and file a new report.

Redaction is only the black rectangles you draw with the redact tool. Those pixels are flattened to opaque black in the saved screenshot. Arrows, pen strokes, shapes, and text do not hide what is underneath. When a capture has a redaction, ScreenClip does not keep the unredacted crop.

## The queue

Captures are stored under `~/Library/Application Support/ScreenClip` before any agent runs. Each report has a permanent number such as **#234**. Click the number to copy a reference. Search for `#234` or `234` finds that report across projects, statuses, and the archive.

The menu bar shows the count of submitted, unresolved issues. **Merged** issues leave that count and appear under **To retest**. Drafts are separate. Adding a second screenshot to an existing issue does not add another count.

A project runs up to three reports at once. The limit is 1–6, in **Settings → Connections → AI agent**. A report waiting for your answer does not count toward it, so the next report starts while one waits. Keep ScreenClip running and the Mac awake while Codex or Claude Code works. Grok Bot keeps working in the cloud if the Mac sleeps; ScreenClip updates the pull request the next time it is running.

**Add context** saves a text note without another screenshot, including while a report is queued or working. Notes stay with the report and go out the next time the agent works. Adding context during a turn triggers follow-up work. A completed report reopens for a follow-up. A pending question still uses its reply controls.

**Open in Codex** opens that issue's chat. Claude reports offer **Copy Claude resume command**. A Grok Bot report shows **Open Grok Bot agent** once Grok Bot reports its agent link, and the pull request once ScreenClip finds it; until then it says the conversation is in Grok Bot's chat. Cancel stops the local record. When the connection supports it, ScreenClip also asks Grok Bot to stop; that request is best-effort, and Grok Bot may still finish work it already started. Cancel active work before using the same worktree in another coding client.

Codex chats may show up in Recents instead of the desktop project you expect. That limit is written up in the [repository association review](validation.md#repository-association-review).

After an interruption, **Reconcile chat** can recover a saved Codex result and validate it again before publication. For Claude Code, reconciliation checks that no session process is still running before Continue. It does not recover a finished result from Claude's history. **Refresh PR status** updates checks immediately.

Archive keeps the screenshots and the outcome and clears the report from the active queue. Active work has to be canceled or resolved first. Restore brings it back.

## Filed under the wrong project

Choose **Move to project** in the report's **…** menu.

- Before an agent has a chat or a worktree, the report is reassigned and queued.
- After that, the old report is canceled and a copy with the same screenshots, notes, and agent is queued on the other project. The old chat and worktree belong to the other repository.
- Cancel active work first. A report that already has a pull request cannot be moved until that pull request is closed or merged. Archived reports and reports with an uncertain dispatch are not movable.

## Agent permissions

**Project settings → Codex permissions** controls each project's Codex work. **Automatic review (recommended)** is the default, including for older projects: Codex reviews permission requests automatically while retaining the workspace sandbox. **Ask me** uses manual approvals. **Full access (no approval prompts)** lets commands access your Mac and network without sandbox restrictions or approval prompts; use it for projects you trust. Changes apply to the next turn in the same chat.

For a live command or file approval, **Allow and automate this project** allows the displayed request once and switches later requests to automatic review. Other already running reports retain their current mode until their next turn. On relaunch, permission-only reports and acknowledged interrupted work without an unanswered question can reconcile and resume automatically in an automatic mode. Genuine questions, uncertain dispatches, and active chats in another client are retained. Managed policies and automatic risk review can still refuse an operation.

A permission from a Codex connector, such as Computer Use asking to control an app, is answered on the report with **Allow once**, **Allow for this chat**, **Always allow**, or **Decline**.

**Settings → Connections → AI agent → Continue without my answer** sets how long a live Codex question or permission request waits for you: **Never**, or after 5, 10 (the default), 30, or 60 minutes. After that, Codex is told you are not available. A question gets the safest default, and a command, file, or connector permission is declined so Codex can continue another way. A request that can only be canceled keeps waiting.

## Shared agent instructions

Open **Settings → Connections → Agent instructions** to edit the **Default prompt add-on** for all projects. The default asks for original and retested screenshots labeled **Before / After** in visual-fix PRs, with a short retest result or an explanation of missing evidence. Choose **Save settings** to apply edits to the next agent request, leave the text empty to disable it, or use **Restore default prompt**. Screenshot sharing is always enabled. Local agents must supply a retested After PNG; ScreenClip publishes it with the original report image in the PR. Missing images trigger repair or a concrete blocker. See [Coding agents](agents/README.md#default-prompt-add-on) for details.

## What each agent can see

Codex and Claude Code run locally and receive the approved screenshots, notes, and prompt. The agent may send those inputs to its model provider under your signed-in account's terms. ScreenClip publishes the flattened report screenshots and retested After PNGs in the fix commit and embeds them in the GitHub PR. It removes inherited GitHub token variables from the agent's environment and handles commits, pushes, pull requests, and merges itself. The worktree is the edit directory; it is not a security boundary for a full-access agent.

Grok Bot is remote. Approved PNGs, notes, and report fields are pushed to a `screenclip/<number>-<slug>-<workspace>` branch, then a small JSON webhook is sent. The webhook has no image bytes. The browser URL and window title are included only when **Read the active browser URL for project matching** is on. The Webhook URL and key stay in the Keychain, not in the queue database. Anyone who can read the GitHub repository can read those screenshot files. On a public repository that means anyone. Screenshot sharing is always enabled; there is no project opt-in checkbox. Deleting `.screenclip/` later does not erase the files from Git history.

Details, including how to copy the webhook from the ScreenClip reports routine, are in [Coding agents](agents/README.md).

## Tip window

Direct-download builds can show a small tip window. It is not a system sheet, because the menu-bar app often has no other window open.

- It appears after 3 merged or verified fixes (archived ones count) or after the queue has existed for 7 days, whichever comes first.
- **Not now**, or closing the window, hides it for 30 days. Closing it after opening it from the menu does the same.
- **Don't ask again** stores an opt-out. The automatic prompt stops.
- The window stays available from **Support ScreenClip…** in the menu and from **Settings → General → Support**, including after you opt out.
- The suggested amounts are $3, $5, and $10. Each button opens `https://github.com/sponsors/lludo`. GitHub does not offer a URL that pre-fills the amount.
- Preview and integration launches do not show it. While ScreenClip hides itself for a capture, the window is ordered out so it is not in the screenshot.

The website has no tip link until `donateUrl` is set. That, and the Sponsors profile, are tracked in [Publishing checklist](release/publishing-checklist.md#open-todos). The release mechanics are in [Direct distribution](release/direct-distribution.md#tip-window).

## Screen Recording

If capture fails while access looks enabled, use **Check screen access** in General settings. After changing access in System Settings, choose **Check again** or **Reopen app** from the permission banner.

If an older ad-hoc build left an unusable permission entry, quit ScreenClip, reset its screen-capture approval, then reopen the Applications copy:

```sh
tccutil reset ScreenCapture com.mirageteam.screenclip
open /Applications/ScreenClip.app
```

Diagnostics go to `~/Library/Application Support/ScreenClip/capture-diagnostics.log`. They contain build and API error metadata, without screenshots, notes, browser URLs, or window titles.

## Read the queue from a terminal

The app owns dispatch. This command only reads:

```sh
python3 scripts/review_queue.py --project ScreenClip --details
```

The optional [MCP plugin](../plugins/screenclip/README.md) exposes the same queue to a Codex or Claude Code session. Grok Bot does not install it.
