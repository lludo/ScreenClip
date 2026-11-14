# Grok Bot (external assistant)

Updated: November 14, 2026. Part of [Coding agents](README.md).

Grok Bot is a remote destination. ScreenClip does not run it in a local worktree and does not ask it for the local agents' `implemented` / `question` / `blocked` result. It hands the report to the assistant with a webhook, then tracks the pull request on GitHub. In every agent list the destination is named **Grok Bot**.

## At a glance

| Topic | Behavior |
| --- | --- |
| Where it appears | Settings → Connections → Default agent, the agent list, and the capture window's Agent picker, next to Codex and Claude Code. |
| Ready | Detected when a webhook URL and an Authorization header value are saved in the Keychain. A successful Send test is optional and is mentioned in the status line. Otherwise the row says **Not configured** and points at Settings → Connections → External assistant. |
| Evidence | Approved screenshots and `report.json` are committed to `screenclip/<reportNumber>-<slug>` in the project's repository and pushed. The webhook does not contain image bytes. |
| Opt-in | Each project has **Allow sending screenshots to the external assistant**, off by default. Public and private repositories both need it. The capture window explains why Grok Bot cannot be chosen while it is off. |
| After a 2xx | Activity `Sent to external assistant`. The issue stays **Working** until a pull request is found. |
| Pull request | The assistant opens a PR from that same branch whose body contains `ScreenClip: #<reportNumber>`. ScreenClip polls GitHub and **Refresh PR status** picks it up immediately. |
| Merge | ScreenClip decides. The existing auto-merge checks apply (validated head, passing checks, current revision, reviews). A PR that still contains `.screenclip/` files is not auto-merged and is shown as needing attention. |
| Conversation | No deep link. The pull request link is shown once known. Before that, the report says the conversation is in Grok Bot's chat. |
| Cancel | Local only. The activity says Grok Bot cannot be stopped from ScreenClip. |

## Hand-off

1. ScreenClip creates or reuses a worktree on `screenclip/<reportNumber>-<slug>`, branched from the project's base branch. The slug is a short lowercase form of the title.
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

`context.browserURL` and `context.windowTitle` are included only when **Read the active browser URL for project matching** is on. App name and bundle ID are always included.

## What Grok Bot does

1. Wakes on the webhook and reads the note plus the screenshots on the evidence branch.
2. Starts a cloud coding agent on that repository. The branch stays `screenclip/<reportNumber>-<slug>`. The pull request body includes `ScreenClip: #<reportNumber>`.
3. Questions stay in Grok Bot's chat.
4. The last commit deletes `.screenclip/`. ScreenClip will not auto-merge while those files are still in the pull request.

## Settings

Settings → Connections → External assistant stores:

- **Webhook URL**
- **Authorization header** — the full header value from the assistant, sent verbatim as the HTTP `Authorization` header. ScreenClip does not add `Bearer` or any other prefix.

Both live in the Keychain (`com.screenclip.app.external-assistant`). They are not written to the SQLite queue. **Send test** POSTs `{"schema":"screenclip.external.v1.test"}` and shows the HTTP status. `scripts/send_test_webhook.py` sends that same payload from `SCREENCLIP_WEBHOOK_URL` and `SCREENCLIP_AUTHORIZATION`.

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

- **Automated, in this repository:** payload encoding, branch slugs, GitHub remote parsing, opt-in gating, idempotent retry of the same revision, pull-request matching, the `.screenclip/` merge guard, detection and picker availability, and `scripts/send_test_webhook.py`.
- **Not verified from the Linux environment that added this:** `bash scripts/test.sh`, the Xcode build, a live webhook, a real evidence push, pull-request discovery, or auto-merge. See [validation.md](../validation.md).
