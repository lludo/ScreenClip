# Grok Bot (external assistant)

Updated: November 14, 2026. Part of [Coding agents](README.md).

Grok Bot is a remote destination. It does not run on the Mac and does not return the local agents' `implemented` / `question` / `blocked` result. ScreenClip uses an isolated worktree only to commit and push the approved screenshots, wakes Grok Bot with a webhook, then tracks the pull request on GitHub. In every agent list the destination is named **Grok Bot**.

## At a glance

| Topic | Behavior |
| --- | --- |
| Where it appears | Settings → Connections → **AI agent** → **Default agent**, the agent list, and the capture window's **Agent** picker, next to Codex and Claude Code. |
| Ready | Detected when a webhook URL and an Authorization header value are saved in the Keychain. A successful Send test is optional and is mentioned in the status line. Otherwise the row says **Not configured** and points at Settings → Connections → External assistant. |
| Evidence | Approved screenshots and `report.json` are committed to `screenclip/<reportNumber>-<slug>-<workspace>` in the project's repository and pushed. The webhook does not contain image bytes. |
| Opt-in | Each project has **Allow sending screenshots to the external assistant**, off by default. Public and private repositories both need it. The capture window explains why Grok Bot cannot be chosen while it is off. |
| After a 2xx | Activity `Sent to external assistant`. The issue stays **Working** until a pull request is found. |
| Pull request | The assistant opens a PR from that same branch whose body contains `ScreenClip: #<reportNumber>`. ScreenClip polls GitHub and **Refresh PR status** picks it up immediately. |
| Merge | ScreenClip decides. The existing auto-merge checks apply (validated head, passing checks, current revision, reviews). A PR that still contains `.screenclip/` files is not auto-merged and is shown as needing attention. |
| Conversation | No deep link. The pull request link is shown once known. Before that, the report says the conversation is in Grok Bot's chat. |
| Cancel | Local only. The activity says Grok Bot cannot be stopped from ScreenClip. |

## Hand-off

1. ScreenClip creates or reuses a worktree on `screenclip/<reportNumber>-<slug>-<workspace>`, branched from the project's base branch. The slug is a short lowercase form of the title.
2. It commits `.screenclip/<reportNumber>/report.json` and `.screenclip/<reportNumber>/capture-<n>.png`. The PNGs are the approved derivatives (annotations applied, redactions flattened). Unredacted originals are never committed.
3. It pushes that branch with the `gh` and `git` credentials already used for pull requests.
4. It POSTs JSON with schema `screenclip.external.v1`.

A follow-up capture adds files and a new commit on the same branch, then sends the new revision. A retry of the same report number and revision pushes the existing evidence commit again if needed and POSTs the same revision. ScreenClip marks the handoff uncertain before the POST, the same way the local outbox does, so a crash can retry without inventing a second revision.

`report.json` uses the same fields as the webhook. Its `evidence.commit` is null: a commit cannot contain its own id. The webhook sets `evidence.commit` to the id of the commit that contains the file.

```json
{
  "schema": "screenclip.external.v1",
  "reportNumber": 234,
  "issueID": "…",
  "revision": 1,
  "title": "Clipped button",
  "notes": ["The label is cut off"],
  "contextNotes": ["The purchase button, not the title."],
  "context": { "appName": "Safari", "bundleID": "com.apple.Safari" },
  "project": {
    "name": "ScreenClip",
    "repo": "owner/name",
    "baseBranch": "main",
    "validationCommand": "bash scripts/test.sh"
  },
  "evidence": {
    "branch": "screenclip/234-clipped-button",
    "commit": "…",
    "paths": [".screenclip/234/report.json", ".screenclip/234/capture-1.png"]
  }
}
```

`notes` are the capture notes, in capture order. `contextNotes` are text added later with **Add context**, kept separate so they do not shift the screenshot paths. `context.browserURL` and `context.windowTitle` are included only when **Read the active browser URL for project matching** is on. App name and bundle ID are always included.

## What Grok Bot does

1. Wakes on the webhook and reads the note plus the screenshots on the evidence branch.
2. Starts a cloud coding agent on that repository. The branch stays `screenclip/<reportNumber>-<slug>-<workspace>`. The pull request body includes `ScreenClip: #<reportNumber>`.
3. Questions stay in Grok Bot's chat.
4. The last commit deletes `.screenclip/`. ScreenClip will not auto-merge while those files are still in the pull request.

## Setup

1. Open **Settings → Connections → External assistant**.
2. Paste **Webhook URL** and **Authorization header** from the Grok Bot routine panel. The header is the full value, sent as the HTTP `Authorization` header. ScreenClip does not add `Bearer` or any other prefix. A line break in that value is rejected.
3. Click **Send test**. It POSTs `{"schema":"screenclip.external.v1.test"}` and shows the HTTP status. Saving both fields is enough for **Detected**; **Send test** is optional.
4. Click **Save settings**.
5. Open **Settings → Projects**, edit the project, and turn on **Allow sending screenshots to the external assistant**. It is off until you do that, for private and public repositories.
6. Choose Grok Bot as **Default agent** under **AI agent**, or pick it in the capture window. The capture-window row stays disabled until the webhook is saved and that project opt-in is on.

The URL and header live in the Keychain (`com.screenclip.app.external-assistant`). They are not written to the SQLite queue. Replacing a saved connection updates the Keychain item in place. `scripts/send_test_webhook.py` sends the same test payload from `SCREENCLIP_WEBHOOK_URL` and `SCREENCLIP_AUTHORIZATION`.

## Privacy

What leaves the Mac for a Grok Bot report:

- The webhook JSON in the hand-off section: report number, issue id, revision, title, capture notes, **Add context** notes, source app name, bundle ID, project name, `owner/name`, base branch, validation command, evidence branch, commit, and file paths. Browser URL and window title are included only when **Read the active browser URL for project matching** is on.
- The git push: `.screenclip/<reportNumber>/report.json` and the approved `capture-<n>.png` files. Anyone who can read that GitHub repository can read those files until Grok Bot deletes `.screenclip/`. On a public repository that means anyone.

Redaction is only a rectangle you draw with the redact tool. ScreenClip flattens those rectangles to opaque black in the PNG it stores and sends. Arrows, pen, shapes, and text do not cover pixels. The unredacted crop is not kept when a capture has a redaction, and it is never pushed or posted.

A redirect to a different host does not include the Authorization header.

## Status

| Result | Queue |
| --- | --- |
| HTTP 2xx | **Working**, activity `Sent to external assistant`. |
| Non-2xx or network failure | **Failed**, with the error and **Retry**. Retry sends the same report number and revision. |
| Pull request found | **PR open**, then the existing merged → **To retest** path. |
| `.screenclip/` still in the PR | Stays **PR open**, is not auto-merged, and appears under **Needs you** with an explanation. |
| Cancel | **Canceled**. The remote run is not stopped. |
| Restart during the POST | **Failed**, with a note that Retry delivers the same revision. The evidence commit is kept. |
| Restart after a successful send | Stays **Working** and keeps watching for the pull request. |

Polling looks for an open (or already merged) pull request whose head is the evidence branch and whose body contains `ScreenClip: #<reportNumber>`, about once a minute, and whenever **Refresh PR status** is used. A closed pull request is reported and not attached.

ScreenClip validates the pull request head with the project's validation command before auto-merge, and it still requires passing checks, a current revision, and the project's review rules. The assistant does not merge.

## Picker

Grok Bot is listed even when it is not configured.

- **Settings:** it can be the default agent. The detection row is green when the webhook and header are saved, and says where to configure them otherwise.
- **Capture window:** the menu item is disabled, with a hint, until the webhook is configured and the selected project has opted in. Follow-up captures stay on Grok Bot, the same way other agents stay locked.

## Limitations

- Questions are not copied into ScreenClip. Answer them in Grok Bot's chat.
- Cancel does not stop the remote assistant.
- There is no desktop deep link.
- Automatic merge waits until `.screenclip/` is gone, even when checks are green.
- The destination is refused while the project opt-in is off, including for private repositories.

## Verification status

- **Automated:** payload encoding, branch slugs, GitHub remote parsing, opt-in gating, idempotent retry of the same revision, pull-request matching, the `.screenclip/` merge guard, detection and picker availability, header-safety, same-origin redirect handling (scheme, host and port), and `scripts/send_test_webhook.py`. GitHub Actions on macos-15 passed the earlier Grok Bot suite, the Python tests, and the Xcode Debug and Release builds. The review fixes are in the tests and wait on the next macOS run.
- **Not yet exercised:** a live webhook, a real evidence push, pull-request discovery, and auto-merge. See [validation.md](../validation.md).
