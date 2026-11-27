# Grok Bot (external assistant)

Updated: November 26, 2026. Part of [Coding agents](README.md).

Grok Bot is a remote destination. It does not run on the Mac and does not return the local agents' `implemented` / `question` / `blocked` result. ScreenClip uses an isolated worktree only to commit and push the approved screenshots, wakes Grok Bot with a webhook, then tracks the pull request on GitHub. In every agent list the destination is named **Grok Bot**.

## At a glance

| Topic | Behavior |
| --- | --- |
| Where it appears | Settings → AI Agents → **AI agent** → **System default**, each project's **Project default**, and the capture window's **Agent** picker, next to Codex and Claude Code. |
| Ready | The Grok Bot row says **Grok Bot ready** and the host once the Webhook URL and key have been saved in the Keychain. Otherwise it says **Grok Bot is not connected**. |
| Evidence | Approved screenshots and `report.json` are committed to `screenclip/<reportNumber>-<slug>-<workspace>` in the project's repository and pushed. The webhook does not contain image bytes. |
| Screenshot sharing | Always enabled for configured projects, including older projects saved with sharing off. The project's **Commit screenshots to the repository** setting applies to Codex and Claude Code only; it does not turn off the Grok Bot evidence push. |
| After a 2xx | Activity `Sent to external assistant`. The issue stays **Working** until a pull request is found. |
| Pull request | The assistant opens a PR from that same branch. The body contains `ScreenClip: #<reportNumber>`. It may also contain `ScreenClip-Report:`, `ScreenClip-Revision:`, and `ScreenClip-Agent:`. ScreenClip polls GitHub and **Refresh PR status** picks it up immediately. A fork PR is ignored. A draft is attached and is not merged. |
| Merge | ScreenClip decides. The existing auto-merge checks apply (validated head, passing checks, current revision, reviews). A PR that still has the hand-off folder `.screenclip/<reportNumber>/`, or that is still a draft, is not merged. Other `.screenclip/` files do not hold the merge back and are left in place. |
| Conversation | When Grok Bot posts a commit status whose link is `https://cursor.com/agents/bc-<uuid>`, the report shows **Open Grok Bot agent**. A pull request in the same repository is the other allowed link. Before either exists, the report says the conversation is in Grok Bot's chat. There is still no report-specific Grok Bot deep link. |
| Cancel | Local always. If the setup code includes `"capabilities":["cancel"]`, ScreenClip also POSTs a best-effort cancel. The remote run may still finish. |

## Hand-off

1. ScreenClip creates or reuses a worktree on `screenclip/<reportNumber>-<slug>-<workspace>`, branched from the project's base branch. The slug is a short lowercase form of the title. `<workspace>` is the first eight characters of the issue's workspace id, so a follow-up after a merge does not reuse the merged branch.
2. It commits `.screenclip/<reportNumber>/report.json` and `.screenclip/<reportNumber>/capture-<n>.png`. The PNGs are the approved derivatives (annotations applied, redactions flattened). Unredacted originals are never committed.
3. It pushes that branch with the `gh` and `git` credentials already used for pull requests.
4. It POSTs JSON with schema `screenclip.external.v1`.

A follow-up capture adds files and a new commit on the same branch, then sends the new revision. A retry of the same report number and revision pushes the existing evidence commit again if needed and POSTs the same revision. ScreenClip marks the handoff uncertain before the POST, the same way the local outbox does, so a crash can retry without inventing a second revision.

`report.json` uses the same fields as the webhook, except `delivery`. Its `evidence.commit` is null: a commit cannot contain its own id, so the file has no delivery key. The webhook sets `evidence.commit` to the id of the commit that contains the file, and then adds `delivery`.

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
    "branch": "screenclip/234-clipped-button-a1b2c3d4",
    "commit": "0123456789abcdef0123456789abcdef01234567",
    "paths": [".screenclip/234/report.json", ".screenclip/234/capture-1.png"]
  },
  "workspaceID": "a1b2c3d4-0000-4000-8000-000000000000",
  "previousPullRequests": ["https://github.com/owner/name/pull/12"],
  "delivery": {
    "key": "00000000-0000-4000-8000-000000000000:r1:0123456789abcdef0123456789abcdef01234567",
    "attempt": 1
  }
}
```

`issueID` in a real payload is the report's UUID. The example above uses a dummy id. `delivery` is omitted from `report.json`. `delivery.key` is `<issueID>:r<revision>:<commit>`. `delivery.attempt` counts POSTs of that revision and is not part of the key: 1 is the first send, and a retry or **Continue** is higher. `previousPullRequests` lists earlier `Previous fix:` URLs after a follow-up on a merged report. `workspaceID` is the issue workspace. Empty optional fields are omitted.

The webhook also sends `Idempotency-Key` set to `delivery.key`. Request headers are not documented to reach the routine, so the routine must dedupe on the key in the body (or on the commit status), not on that header.

`notes` are the capture notes, in capture order. `capture-<n>.png` belongs to `notes[n-1]`; a text note has no PNG, so its number is skipped (a text note followed by a screenshot gives `capture-2.png`). `contextNotes` are text added later with **Add context**, kept separate so they do not shift the screenshot paths. `context.browserURL` and `context.windowTitle` are included only when **Read the active browser URL for project matching** is on. App name and bundle ID are always included.

`promptAddOn` includes required autonomy instructions and the screenshot publication contract (or, for a report filed as text only, a line saying there are no original screenshots) followed by the current shared instruction text from **Settings → AI Agents → Agent instructions**. Both `report.json` and the webhook include it, even when the optional add-on is empty. The routine should use the latest webhook value. Screenshot publication is authorized: the routine must embed the original evidence PNGs at `evidence.commit`, capture the rebuilt fixed UI, commit retest PNGs inside the hand-off directory (never elsewhere in the repository), and embed immutable GitHub commit links for both. Screenshots appear only in the pull request description; they never reach the base branch. Follow-up revisions must update the comparison. A missing retest capture does not block the pull request: the routine finishes it and states in the description which After screenshot is missing and the concrete obstacle. ScreenClip's local missing-image repair check does not run inside the remote routine.

ScreenClip asks the remote routine to investigate, implement, build, test, and prepare its pull request autonomously, asking only for material missing decisions or concrete blockers. The routine should use automatic permission review in its coding agent when available and leave merging to ScreenClip. ScreenClip does not control the remote Grok Bot or cloud agent permission settings through this webhook; those must also permit unattended work.

## What Grok Bot does

1. Wakes on the webhook and reads the note plus the screenshots on the evidence branch.
2. Starts or continues a cloud coding agent on that repository. The branch stays `screenclip/<reportNumber>-<slug>-<workspace>`. The pull request body includes `ScreenClip: #<reportNumber>`, and should also include `ScreenClip-Report: <issueID>`, `ScreenClip-Revision: <revision>`, and `ScreenClip-Agent: <agent URL>`.
3. Writes a commit status on the evidence commit, context `screenclip/grok-bot`: `pending` with `target_url` `https://cursor.com/agents/bc-<uuid>`, then `success` with the pull request URL, or `failure`, or `error` with "Canceled from ScreenClip".
4. Questions stay in Grok Bot's chat.
5. The last commit deletes `.screenclip/`. Removing the hand-off folder `.screenclip/<reportNumber>/` is how ScreenClip knows the routine finished the revision, so ScreenClip does not merge while it is still in the pull request, or while the pull request is a draft. Other `.screenclip/` files, such as Before / After evidence earlier fixes committed, do not hold the merge back; ScreenClip leaves them in place.

## Setup

Connecting Grok Bot is global. The sheet does not pick a project.

1. Open **Settings → AI Agents**. In the **Grok Bot** section, click **Connect Grok Bot**.
2. In Grok Bot, open your ScreenClip assistant's info pane, then the **ScreenClip reports** routine. It shows **POST to**, **key**, and **header**, each with a copy button. The routine's webhook secret is not visible to the assistant, so asking it to connect does not produce these values.
3. Paste **POST to** into **Webhook URL**. Paste **key**, or **header**, into **Key**. A bare key is sent as `Bearer` plus that key. A value that already starts with `Bearer ` is kept. A value that starts with `Authorization:` has that prefix removed, and `Bearer ` is added when the remainder does not already have it. The address must be `https` (plain `http` is accepted only for `localhost`, `127.0.0.1`, and `::1`). The key must be a single line.
4. Click **Connect**. ScreenClip sends the test webhook and shows **Grok Bot ready**, or an error for a bad URL, a missing key, or HTTP 401.
5. In **Project settings**, leave **Project default** on **System default**, or choose Grok Bot for that project. Screenshot sharing is always enabled.
6. A new capture starts on the project's effective default. You can pick another connected provider for that capture. A follow-up stays on the provider the report already uses.

In **Settings → AI Agents**, the **AI agent** list shows Grok Bot like Codex and Claude Code: icon, name, and a status such as **Grok Bot ready · host**. There are no buttons on that row. The **Grok Bot** section below Claude Code and Codex has the Webhook URL, a Key row that says **Set** or **Not set** and never shows the secret, a Capabilities row, **Connect Grok Bot** or **Test connection**, and **Disconnect Grok Bot**. **Save settings** stores an edited URL with the saved key. **Disconnect Grok Bot** removes the Keychain item.

The address and secret live in the Keychain (`com.screenclip.app.external-assistant`). They are not written to the SQLite queue, and ScreenClip does not write them to a log. Replacing a saved connection updates the Keychain item in place. The check ScreenClip runs asks Grok Bot to accept a small test message. `scripts/send_test_webhook.py` sends that same test from `SCREENCLIP_WEBHOOK_URL` and `SCREENCLIP_AUTHORIZATION`.

Opening a `screenclip://connect` link fills the same two fields. The app registers the `screenclip` URL scheme in `Resources/Info.plist` (also used by `screenclip://issues/<uuid>` and its `/reconcile`, `/continue`, and `/resume` report actions, which also require the `token` from `link-token` in the data folder).

## Webhook and key

Example values only:

```text
Webhook URL: https://assistant.example/hook
Key: dummy-key
```

ScreenClip stores that key as `Bearer dummy-key`. Pasting `Bearer dummy-key` or `Authorization: Bearer dummy-key` stores the same header. ScreenClip does not add a second `Bearer` prefix. The secret must be a single line with no control characters.

A pasted connection can also carry an optional `capabilities` array. It is not a secret. The only value ScreenClip acts on today is `cancel`. Older builds ignore unknown keys. The sheet does not ask for this array; it is kept when a pasted connection includes it.

## Privacy

What leaves the Mac for a Grok Bot report:

- The webhook JSON in the hand-off section: report number, issue id, revision, title, capture notes, **Add context** notes, source app name, bundle ID, project name, `owner/name`, base branch, validation command, evidence branch, commit, file paths, workspace id, earlier pull request URLs, and the delivery key and attempt. Browser URL and window title are included only when **Read the active browser URL for project matching** is on. A cancel, when the setup code allows it, sends the issue id, report number, revision, repository, and branch.
- The git push: `.screenclip/<reportNumber>/report.json` and the approved `capture-<n>.png` files. Anyone who can read that GitHub repository can read those files. On a public repository that means anyone. **Treat a push as permanent:** removing `.screenclip/` in a later commit does not remove the files from history, and GitHub keeps every pull request's commits reachable (`refs/pull/<n>/head`) even after the branch is deleted. ScreenClip deletes the remote evidence branch after it confirms the merge; canceling leaves the branch and any open pull request in place.

Redaction is only a rectangle you draw with the redact tool. ScreenClip flattens those rectangles to opaque black in the PNG it stores and sends. Arrows, pen, shapes, and text do not cover pixels. The unredacted crop is not kept when a capture has a redaction, and it is never pushed or posted.

The address must use HTTPS (plain HTTP is accepted only for `localhost` test servers). A redirect to a different host does not include the secret. A retry after an uncertain delivery can send the same `issueID` and `revision` again, so the assistant should treat that pair as idempotent. The pasted connection is parsed on the Mac and stored in the Keychain. ScreenClip does not write the pasted text, the address, or the secret to a log, and a failed check does not show the reply body, because that body can repeat the secret.

## Status

| Result | Queue |
| --- | --- |
| HTTP 2xx | **Working**, activity `Sent to external assistant`. |
| Non-2xx or network failure | **Failed**, with the error and **Retry**. Retry sends the same report number and revision. |
| Pull request found | **PR open**, then the existing merged → **To retest** path. |
| Hand-off folder `.screenclip/<reportNumber>/` still in the PR | Stays **PR open**, is not merged, and appears under **Needs you** with an explanation. |
| Other `.screenclip/` files in a PR that is otherwise ready to merge | Merged as is. ScreenClip does not remove them. |
| Cancel, no `cancel` capability | **Canceled**. The activity says Grok Bot cannot be stopped from ScreenClip. |
| Cancel, setup code has `cancel` | **Canceled**, and ScreenClip POSTs `screenclip.external.v1.cancel`. The activity says this is best-effort. |
| Commit status `screenclip/grok-bot` | Records the description and, when the link is allowed, **Open Grok Bot agent**. ScreenClip keeps reading statuses while the pull request is open so a later revision can update them. |
| No status, and this connection has posted one before | About 15 minutes after the send, **Needs you** once: Grok Bot has not picked up that revision. **Continue** sends it again. ScreenClip keeps watching. |
| Restart during the POST | **Failed**, with a note that Retry delivers the same revision. The evidence commit is kept. |
| Restart after a successful send | Stays **Working** and keeps watching for the pull request. |
| No pull request 2 hours after the send, and no earlier status warning | Moves to **Needs you** once, with a notification. ScreenClip keeps watching and attaches a later pull request. **Continue** sends the same report again. |

Polling looks for an open (or already merged) pull request whose head is the evidence branch, about once a minute, and whenever **Refresh PR status** is used. A fork (`isCrossRepository`, or a head owner that is not this repository's owner) is ignored. If the body has a `ScreenClip-Report:` line, it must equal this report's issue id. If it does not, the body must contain `ScreenClip: #<reportNumber>`, and that marker must not be followed by another digit, so `#234` does not match a body that only says `#2340`. A closed pull request is reported and not attached. A draft is attached, labeled **Draft PR**, and is not merged.

The same pass reads `gh api repos/<owner>/<name>/commits/<evidence-commit>/statuses` and keeps the newest `screenclip/grok-bot` entry. With no such status, and until this connection has produced one, behavior is the 2-hour reminder only. A status link is shown only when it is `https://cursor.com/agents/bc-<uuid>` or a pull request in this repository. Any other target, including `grokbot://`, is ignored. A non-2xx webhook error is `Grok Bot rejected the report (HTTP <status>).` and does not include the response body.

ScreenClip runs the project’s validation command on the pull request head before merging. This runs the pull request’s code on your Mac. With automatic merge off, validation waits until you confirm **Merge pull request** on the report. Both merge paths require a current revision, the project’s required reviews, and no failing or pending checks. Automatic merge also needs at least one passing check; a manual merge accepts a pull request whose GitHub checks have stayed empty for three minutes on the same commit. The assistant does not merge.

## Picker

The menu bar status line is **Grok Bot ready** or **Grok Bot is not connected**, the same shape as **Codex ready** and **Claude Code ready**.

- **System default:** Settings → AI Agents → **System default**. A missing value in an older queue means Codex.
- **Project default:** Project settings. **System default (Codex)** (or whichever provider is current) follows the system default. Choosing Grok Bot, Codex, or Claude Code stores that provider and does not change when the system default changes. An older project that had **Allow sending screenshots to the external assistant** on migrates to an explicit Grok Bot default. Other older projects keep inheriting.
- **Capture:** the **Agent** picker starts at the project's effective default. You can override it for that capture. Follow-up captures stay on the provider the report started with.
- Grok Bot appears in those pickers once it is connected. A follow-up locked to Grok Bot explains why it cannot be sent if the connection is missing.

## Limitations

- The webhook returns only an HTTP status. A 200 means a run started. There is no body, run id, conversation id, status API, cancel API, or documented dedupe header for ScreenClip to read. Progress and the agent link exist only when the routine writes the GitHub commit status and the pull request lines above.
- `Idempotency-Key` is sent and must not be relied on. The delivery key in the JSON is the value the routine can see.
- Questions are not copied into ScreenClip. Answer them in Grok Bot's chat.
- Cancel is best-effort, and only when the saved connection lists `cancel`. There is no API that hard-stops the cloud agent. Without that capability, cancel is local only.
- ScreenClip has no report-specific Grok Bot chat link. Grok Bot documents a `grokbot://app/v1/prompt` link that opens a Bot with an unsent draft message. That link does not identify a particular ScreenClip report or send the message, and ScreenClip does not offer it as one. See [Grok Bot deep links](https://docs.x.ai/grok-bot/deep-links). `screenclip://connect` only opens the connect sheet.
- Merge waits until Grok Bot removes its hand-off folder and the pull request is not a draft, even when checks are green. ScreenClip cannot tell a finished revision from one in progress any other way.

## Verification status

- **Automated:** payload encoding (delivery key only on the webhook), branch slugs, GitHub remote parsing, always-enabled screenshot sharing, idempotent retry of the same revision, pull-request matching (fork rejection, `ScreenClip-Report`, optional marker, drafts not merged), commit-status link allowlist, old-queue decoding, cancel gating, header-safety, same-origin redirect handling (scheme, host and port), connection-paste encoding and lenient parsing, key normalization, project-default resolution and migration, `screenclip://connect` and `screenclip://issues/` routing, and `scripts/send_test_webhook.py`. `bash scripts/test.sh` includes both Grok Bot suites. The macOS GitHub Actions job runs that script on every push to `main` and every pull request. See [Development](../development.md#ci).
- **Not yet exercised:** a live webhook, a real evidence push, pull-request discovery, and auto-merge. See [validation.md](../validation.md).
