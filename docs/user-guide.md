# User guide

Capture is the point of the app: notice something, grab it, and keep going. Agent work, pull requests, and retest happen afterward. Status meanings are in the [product specification](product-spec.md#issue-lifecycle).

## Capture

Choose **Screenshot task** in the menu bar or press **⌘⇧2** to select a screen region. Choose **Text task** to type an observation directly. Escape cancels the selection. The composer can take a note, freehand drawing, arrows, rectangles, ellipses, text, and an opaque redaction, with undo and redo. A screenshot alone is a valid report. Submit with the primary button or **⌘↩**.

ScreenClip suggests a project from the app or the browser context. Correct it before submitting. If the project is ambiguous, the report is saved as **Needs project** and no agent starts.

In the composer's **Issue** menu, **New issue** starts a report. Existing issues are listed newest first, and choosing one appends the capture to it. The **Agent** menu also picks the model and reasoning effort in one go: choose an agent to keep its defaults, or open its submenu for a model (**Claude Code ▸ Opus**) and that model's submenu for an effort (**Claude Code ▸ Opus ▸ Extra high**). The default rows name the default when the agent reports it; otherwise the model from Settings applies. Codex lists its own models and efforts once connected; the Claude Code list (Fable, Opus, Sonnet, Haiku) is built in. Grok Bot picks its own model. A follow-up keeps that issue's agent, model, and effort. You cannot switch a submitted issue to a different agent; cancel it and file a new report.

New reports start with the project default. Enable **Use the last agent, model, and effort for new reports** in Project settings to reuse the selection from the last report submitted for that project.

Redaction is only the black rectangles you draw with the redact tool. Those pixels are flattened to opaque black in the saved screenshot. Arrows, pen strokes, shapes, and text do not hide what is underneath. When a capture has a redaction, ScreenClip does not keep the unredacted crop.

### From an iOS app

On a physical iPhone or iPad, add ScreenClipKit to your app's Debug build, then shake the device to report a screen. To report an earlier screen, use the photo button in the composer to choose a screenshot. The Mac identifies images chosen from Photos. **Attach logs and diagnostics** also controls any files the app supplies. Reports arrive in the queue with an iPhone icon. Setup, pairing, and Fetch are in [ScreenClip for iOS](ios-sdk.md).

## The queue

Captures are stored under `~/Library/Application Support/ScreenClip` before any agent runs. Each report has a permanent number such as **#234**. Click the number to copy a reference. Search for `#234` or `234` finds that report across projects, statuses, and the archive.

The menu bar shows the count of submitted, unresolved issues. **Merged** issues leave that count and appear under **To retest**. Drafts are separate. Adding a second screenshot to an existing issue does not add another count.

In the menu bar popover, **Open**, **Needs you** and **To retest** count the same reports as the queue's sidebar lists. Click a count to list its reports below it, newest first; **Open** is shown first. Click a report to open it in the queue on the matching list. **Open queue** opens the queue as you left it. The queue lists reports newest first. When a report you have open leaves the list you are on, for example after you verify or archive it, it closes and the list stays.

A project runs up to three reports at once. The limit is 1–6, in **Settings → Connections → AI agent**. A report waiting for your answer does not count toward it, so the next report starts while one waits. Keep ScreenClip running and the Mac awake while Codex or Claude Code works. Grok Bot keeps working in the cloud if the Mac sleeps; ScreenClip updates the pull request the next time it is running.

**Add context** saves a text note without another screenshot, including while a report is queued or working. Notes stay with the report and go out the next time the agent works. Adding context during a turn triggers follow-up work. A completed report reopens for a follow-up. A pending question still uses its reply controls.

**Open in Codex** opens that issue's chat. Claude reports offer **Copy Claude resume command**. A Grok Bot report shows **Open Grok Bot agent** once Grok Bot reports its agent link, and the pull request once ScreenClip finds it; until then it says the conversation is in Grok Bot's chat. Cancel stops the local record. When the connection supports it, ScreenClip also asks Grok Bot to stop; that request is best-effort, and Grok Bot may still finish work it already started. Cancel active work before using the same worktree in another coding client.

Codex chats may show up in Recents instead of the desktop project you expect. That limit is written up in the [repository association review](validation.md#repository-association-review).

After an interruption, **Reconcile chat** can recover a saved Codex result and validate it again before publication. For Claude Code, reconciliation checks that no session process is still running before Continue. It does not recover a finished result from Claude's history. **Refresh PR status** updates checks immediately. It also appears on a **Needs you** or **Failed** report that has a pull request: if you merged that pull request on GitHub yourself, ScreenClip marks the report **Merged**, closes its open question, and moves it to **To retest**. ScreenClip also checks these reports on its own about once a minute, including after the report's worktree was deleted. A fix that landed in a pull request ScreenClip did not open cannot be detected; archive that report.

If a report's worktree is deleted outside ScreenClip, for example by whoever carried the fix on by hand, the agent does not start there. The report fails and says so. If its branch was then pushed and merged on GitHub, ScreenClip finds that pull request by the report's branch, links it, and moves the report to **To retest**. Otherwise archive it if the fix landed some other way, or choose **Continue** to keep working in a new worktree on the same branch. When the report has a pull request, the new worktree first picks up commits pushed to its branch from elsewhere; if the two sides have diverged, ScreenClip stops and asks you to bring the branch up to date by hand. Changes that were never pushed are gone with the old worktree. An open pull request whose worktree is gone stays open until you merge or close it on GitHub. A pull request merged on GitHub counts whoever merged it: the report moves to **To retest**. One closed without merging moves the report to **Needs you**: choose **Continue** to have the agent open a new pull request from the same branch, or archive the report.

Select a report with a pull request to read its formatted GitHub description in the **Pull request description** card, with its Before / After screenshots fitted to the window. Descriptions and screenshots are loaded in the background, so they open complete. The agent's summary on a report renders its Markdown. The refresh button beside the PR number reloads the description and checks the PR status. Choose **Merge pull request** and confirm to squash-merge a ready PR, even when automatic merge is off. ScreenClip checks the reviewed commit, current report revision, local validation, GitHub checks and required reviews before merging. If GitHub still reports no checks for a clean, mergeable PR three minutes after it first saw that commit, you can merge it manually after local validation passes; the wait gives CI time to register its runs after a push. If ScreenClip is busy updating the PR when you confirm, it says so and you can try again a moment later. Automatic merge still requires passing GitHub checks. The report moves to **To retest** when GitHub confirms the merge. Screenshots stay in the pull request description and never reach the base branch: ScreenClip removes the `.screenclip/` evidence folder before merging. If a pull request still has it, ScreenClip removes it, pushes, and merges once checks pass on the new commit; a manual merge is confirmed again for that commit.

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

Open **Settings → Connections → Agent instructions** to edit the **Default prompt add-on** for all projects. The default asks agents to open every PR description with **What was the issue**, **How we addressed it**, and **How we verified it**, followed for visual fixes by original and retested screenshots labeled **Before / After**, or an explanation of missing evidence. A queue that saved the earlier built-in text unchanged switches to the new default automatically. Choose **Save settings** to apply edits to the next agent request, leave the text empty to disable it, or use **Restore default prompt**. Screenshot sharing is always enabled. For reports with screenshots, local agents supply a retested After PNG; ScreenClip publishes it with the original report image in the PR. If the agent cannot capture one, the PR still opens with the Before images and the agent's explanation. See [Coding agents](agents/README.md#default-prompt-add-on) for details.

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

## Updates

From 1.0.3 on, ScreenClip updates itself. Once a day it downloads the update feed from GitHub Releases, downloads a new version in the background, and installs it the next time ScreenClip quits. A menu bar app rarely quits, so a downloaded update also shows **Update to …** in the menu bar popover, which installs it and relaunches. An open capture or running agent work can stop that quit; click the button again once it is done.

**Settings → General → Updates** has **Download and install updates automatically** and **Check for Updates…**, which is also in the popover's **⋯** menu. The bottom of the Settings window shows the installed version and build number. Updates are signed, and ScreenClip refuses one that is not signed with its update key. The check sends no system profile or usage data.

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

### Check tasks from your agents

Settings › Connections › **Check tasks from your agents** installs ScreenClip’s MCP server for Claude Code or Codex in one click. After that, a session in any project can answer “Check this project's ScreenClip tasks”: what is open, in progress, or blocked, and the details of each report. **Copy command** shows the Terminal equivalent, and **Copy JSON** configures other MCP apps. Grok Bot runs in the cloud and cannot use it. An agent can also suggest a validation command or a base branch. Review the full suggestion in the menu bar popover or the project’s settings, then choose **Accept** or **Reject**. Accepting a validation command continues reports waiting for one. Details are in the [MCP plugin](../plugins/screenclip/README.md).
