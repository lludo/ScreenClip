# Grok Bot (external assistant)

Updated: November 14, 2026. Part of [Coding agents](README.md).

Grok Bot is a remote destination. It does not run on the Mac and does not return the local agents' `implemented` / `question` / `blocked` result. ScreenClip uses an isolated worktree only to commit and push the approved screenshots, wakes Grok Bot with a webhook, then tracks the pull request on GitHub. In every agent list the destination is named **Grok Bot**.

## At a glance

| Topic | Behavior |
| --- | --- |
| Where it appears | Settings → Connections → **AI agent** → **Default agent** and the agent list. The capture window offers Grok Bot when its connection and the project opt-in are ready. |
| Ready | The Grok Bot row says **Connected** and the host once a setup code has been saved in the Keychain. Otherwise it says **Not connected — Connect Grok Bot**. |
| Evidence | Approved screenshots and `report.json` are committed to `screenclip/<reportNumber>-<slug>-<workspace>` in the project's repository and pushed. The webhook does not contain image bytes. |
| Opt-in | Each project has **Allow sending screenshots to the external assistant**, off by default. Public and private repositories both need it. A follow-up locked to Grok Bot explains why it cannot be sent while the opt-in is off. |
| After a 2xx | Activity `Sent to external assistant`. The issue stays **Working** until a pull request is found. |
| Pull request | The assistant opens a PR from that same branch. The body contains `ScreenClip: #<reportNumber>`. It may also contain `ScreenClip-Report:`, `ScreenClip-Revision:`, and `ScreenClip-Agent:`. ScreenClip polls GitHub and **Refresh PR status** picks it up immediately. A fork PR is ignored. A draft is attached and is not merged. |
| Merge | ScreenClip decides. The existing auto-merge checks apply (validated head, passing checks, current revision, reviews). A PR that still contains `.screenclip/` files, or that is still a draft, is not auto-merged. |
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

`notes` are the capture notes, in capture order. `contextNotes` are text added later with **Add context**, kept separate so they do not shift the screenshot paths. `context.browserURL` and `context.windowTitle` are included only when **Read the active browser URL for project matching** is on. App name and bundle ID are always included.

## What Grok Bot does

1. Wakes on the webhook and reads the note plus the screenshots on the evidence branch.
2. Starts or continues a cloud coding agent on that repository. The branch stays `screenclip/<reportNumber>-<slug>-<workspace>`. The pull request body includes `ScreenClip: #<reportNumber>`, and should also include `ScreenClip-Report: <issueID>`, `ScreenClip-Revision: <revision>`, and `ScreenClip-Agent: <agent URL>`.
3. Writes a commit status on the evidence commit, context `screenclip/grok-bot`: `pending` with `target_url` `https://cursor.com/agents/bc-<uuid>`, then `success` with the pull request URL, or `failure`, or `error` with "Canceled from ScreenClip".
4. Questions stay in Grok Bot's chat.
5. The last commit deletes `.screenclip/`. ScreenClip will not auto-merge while those files are still in the pull request, or while the pull request is a draft.

## Setup

1. Open **Settings → Connections**. On the **Grok Bot** row, click **Connect Grok Bot**.
2. In Grok Bot, open your ScreenClip assistant and ask it: **Connect ScreenClip**. It replies with a setup code. Copy that phrase with the button in the sheet.
3. Paste the setup code. If it is already on the clipboard when the sheet opens, click **Use code from clipboard**. ScreenClip checks the connection and shows **Connected**, or a short explanation of what to do next.
4. Turn on **Turn on for this project**. Approved annotated screenshots are pushed to a branch in that project's GitHub repo. A private repo is recommended. The same choice lives in **Settings → Projects** as **Allow sending screenshots to the external assistant**, and it stays off until you turn it on.
5. Choose Grok Bot as **Default agent**, or pick it in the capture window once it is connected and that project opt-in is on.

Afterward the row says **Connected** with the host, and offers **Test again** and **Disconnect**. **Advanced** still has the address and secret fields for anyone who already has them. **Save settings** stores edits there. **Disconnect** removes the Keychain item. Leaving both fields blank and clicking **Save settings** does not disconnect.

The address and secret live in the Keychain (`com.screenclip.app.external-assistant`). They are not written to the SQLite queue, and ScreenClip does not write them to a log. Replacing a saved connection updates the Keychain item in place. The check ScreenClip runs asks Grok Bot to accept a small test message. `scripts/send_test_webhook.py` sends that same test from `SCREENCLIP_WEBHOOK_URL` and `SCREENCLIP_AUTHORIZATION`.

A clickable link from the assistant opens the same sheet with the code filled in. The app registers the `screenclip` URL scheme in `Resources/Info.plist` (also used by `screenclip://issues/<uuid>`).

## Setup code

When someone asks the assistant **Connect ScreenClip**, reply with a setup code and, if you can, a link. Do not ask the person to find a webhook.

The code is one line:

```text
screenclip-connect:v1:<base64url>
```

`<base64url>` is the UTF-8 JSON object below, encoded with RFC 4648 §5 base64url and **no** `=` padding. The object is compact (no extra space) and its keys are sorted alphabetically, `authorization` then `url`:

```json
{"authorization":"<secret>","url":"https://assistant.example/hook"}
```

An optional `capabilities` array may be included. Keys stay sorted alphabetically. Older ScreenClip builds ignore unknown keys. `capabilities` is not a secret. The only value ScreenClip acts on today is `cancel`:

```json
{"authorization":"<secret>","capabilities":["cancel"],"url":"https://assistant.example/hook"}
```

`<secret>` is the full value ScreenClip will send as the `Authorization` header. ScreenClip does not add `Bearer` or any other prefix. The address must be `https` (plain `http` is accepted only for `localhost`, `127.0.0.1`, and `::1`). The secret must be a single line with no control characters.

Example, for `https://assistant.example/hook` and `Bearer secret`:

```text
screenclip-connect:v1:eyJhdXRob3JpemF0aW9uIjoiQmVhcmVyIHNlY3JldCIsInVybCI6Imh0dHBzOi8vYXNzaXN0YW50LmV4YW1wbGUvaG9vayJ9
```

Link, with the code percent-encoded in the `code` query item:

```text
screenclip://connect?code=screenclip-connect%3Av1%3AeyJhdXRob3JpemF0aW9uIjoiQmVhcmVyIHNlY3JldCIsInVybCI6Imh0dHBzOi8vYXNzaXN0YW50LmV4YW1wbGUvaG9vayJ9
```

ScreenClip also accepts, if that is what gets pasted:

- JSON with `url` and `authorization`, or `url` and `header`
- a block that contains both an `https://` address and a line `Authorization: …`
- a `curl` command with that address and header

Build the link with a normal query encoder so `:` in the code becomes `%3A`. ScreenClip reads `screenclip://connect?code=`.

## Privacy

What leaves the Mac for a Grok Bot report:

- The webhook JSON in the hand-off section: report number, issue id, revision, title, capture notes, **Add context** notes, source app name, bundle ID, project name, `owner/name`, base branch, validation command, evidence branch, commit, file paths, workspace id, earlier pull request URLs, and the delivery key and attempt. Browser URL and window title are included only when **Read the active browser URL for project matching** is on. A cancel, when the setup code allows it, sends the issue id, report number, revision, repository, and branch.
- The git push: `.screenclip/<reportNumber>/report.json` and the approved `capture-<n>.png` files. Anyone who can read that GitHub repository can read those files. On a public repository that means anyone. **Treat a push as permanent:** removing `.screenclip/` in a later commit does not remove the files from history, and GitHub keeps every pull request's commits reachable (`refs/pull/<n>/head`) even after the branch is deleted. ScreenClip deletes the remote evidence branch after it confirms the merge; canceling leaves the branch and any open pull request in place.

Redaction is only a rectangle you draw with the redact tool. ScreenClip flattens those rectangles to opaque black in the PNG it stores and sends. Arrows, pen, shapes, and text do not cover pixels. The unredacted crop is not kept when a capture has a redaction, and it is never pushed or posted.

The address must use HTTPS (plain HTTP is accepted only for `localhost` test servers). A redirect to a different host does not include the secret. A retry after an uncertain delivery can send the same `issueID` and `revision` again, so the assistant should treat that pair as idempotent. The setup code is parsed on the Mac and stored in the Keychain. ScreenClip does not write the code, the address, or the secret to a log, and a failed check does not show the reply body, because that body can repeat the secret.

## Status

| Result | Queue |
| --- | --- |
| HTTP 2xx | **Working**, activity `Sent to external assistant`. |
| Non-2xx or network failure | **Failed**, with the error and **Retry**. Retry sends the same report number and revision. |
| Pull request found | **PR open**, then the existing merged → **To retest** path. |
| `.screenclip/` still in the PR | Stays **PR open**, is not auto-merged, and appears under **Needs you** with an explanation. |
| Cancel, no `cancel` capability | **Canceled**. The activity says Grok Bot cannot be stopped from ScreenClip. |
| Cancel, setup code has `cancel` | **Canceled**, and ScreenClip POSTs `screenclip.external.v1.cancel`. The activity says this is best-effort. |
| Commit status `screenclip/grok-bot` | Records the description and, when the link is allowed, **Open Grok Bot agent**. ScreenClip keeps reading statuses while the pull request is open so a later revision can update them. |
| No status, and this connection has posted one before | About 15 minutes after the send, **Needs you** once: Grok Bot has not picked up that revision. **Continue** sends it again. ScreenClip keeps watching. |
| Restart during the POST | **Failed**, with a note that Retry delivers the same revision. The evidence commit is kept. |
| Restart after a successful send | Stays **Working** and keeps watching for the pull request. |
| No pull request 2 hours after the send, and no earlier status warning | Moves to **Needs you** once, with a notification. ScreenClip keeps watching and attaches a later pull request. **Continue** sends the same report again. |

Polling looks for an open (or already merged) pull request whose head is the evidence branch, about once a minute, and whenever **Refresh PR status** is used. A fork (`isCrossRepository`, or a head owner that is not this repository's owner) is ignored. If the body has a `ScreenClip-Report:` line, it must equal this report's issue id. If it does not, the body must contain `ScreenClip: #<reportNumber>`, and that marker must not be followed by another digit, so `#234` does not match a body that only says `#2340`. A closed pull request is reported and not attached. A draft is attached, labeled **Draft PR**, and is not merged.

The same pass reads `gh api repos/<owner>/<name>/commits/<evidence-commit>/statuses` and keeps the newest `screenclip/grok-bot` entry. With no such status, and until this connection has produced one, behavior is the 2-hour reminder only. A status link is shown only when it is `https://cursor.com/agents/bc-<uuid>` or a pull request in this repository. Any other target, including `grokbot://`, is ignored. A non-2xx webhook error is `Grok Bot rejected the report (HTTP <status>).` and does not include the response body.

ScreenClip validates the pull request head with the project's validation command before auto-merge, and it still requires passing checks, a current revision, and the project's review rules. The assistant does not merge.

## Picker

Grok Bot stays in Settings even when it is not connected. The capture window offers it when it is ready for the selected project.

- **Settings:** it can be the default agent. The row is green and says **Connected** with the host when the connection is saved. Otherwise it says **Not connected — Connect Grok Bot**.
- **Capture window:** Grok Bot appears in the Agent menu only when it is connected and the selected project has opted in. A follow-up stays on Grok Bot and explains why it cannot be sent if the connection or opt-in is missing.

## Limitations

- The webhook returns only an HTTP status. A 200 means a run started. There is no body, run id, conversation id, status API, cancel API, or documented dedupe header for ScreenClip to read. Progress and the agent link exist only when the routine writes the GitHub commit status and the pull request lines above.
- `Idempotency-Key` is sent and must not be relied on. The delivery key in the JSON is the value the routine can see.
- Questions are not copied into ScreenClip. Answer them in Grok Bot's chat.
- Cancel is best-effort, and only when the setup code lists `cancel`. There is no API that hard-stops the cloud agent. Without that capability, cancel is local only.
- ScreenClip has no report-specific Grok Bot chat link. Grok Bot documents a `grokbot://app/v1/prompt` link that opens a Bot with an unsent draft message. That link does not identify a particular ScreenClip report or send the message, and ScreenClip does not offer it as one. See [Grok Bot deep links](https://docs.x.ai/grok-bot/deep-links). `screenclip://connect?code=` only opens the connect sheet.
- Automatic merge waits until `.screenclip/` is gone and the pull request is not a draft, even when checks are green.
- The destination is refused while the project opt-in is off, including for private repositories.

## Verification status

- **Automated:** payload encoding (delivery key only on the webhook), branch slugs, GitHub remote parsing, opt-in gating, idempotent retry of the same revision, pull-request matching (fork rejection, `ScreenClip-Report`, optional marker, drafts not merged), commit-status link allowlist, old-queue decoding, cancel gating, header-safety, same-origin redirect handling (scheme, host and port), setup-code encoding and lenient parsing, `screenclip://connect` and `screenclip://issues/` routing, and `scripts/send_test_webhook.py`. `bash scripts/test.sh` includes both Grok Bot suites. The macOS GitHub Actions job runs that script on every push to `main` and every pull request. See [Development](../development.md#ci).
- **Not yet exercised:** a live webhook, a real evidence push, pull-request discovery, and auto-merge. See [validation.md](../validation.md).
