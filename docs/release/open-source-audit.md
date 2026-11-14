# Open-source audit

Scanned on November 14, 2026, against every commit reachable from `origin/main` at `a1c72c6e4b5d2f86ae663923a45804b09f4b4f50`, plus one unreachable duplicate commit left in the local object store. The repository was private at the time of the audit; neither history nor visibility was changed.

This record stops at `a1c72c6`. Commits after that, including app and website localization, are not covered. Rescan before making the repository public. The checklist, including the missing `LICENSE`, is in [Open source](../open-source.md).

**The scanned history did not require a rewrite.** No real secret was found in the scanned commits. This is a point-in-time audit, not a guarantee about later commits; scan subsequent changes before publication. The personal data below is an author address and one old home-directory path. Both are already in the commit metadata or in a file that later commits deleted. Publishing the repo publishes them. Switch future commits to a GitHub noreply address if you want to stop adding the mailbox. Rewriting the existing commits is optional and not required for safety.

## Tools

| Tool | Result |
| --- | --- |
| gitleaks 8.30.1, `gitleaks detect --log-opts=--all --redact` | No leaks. It reported 31 commits scanned |
| trufflehog 3.99.9, `trufflehog git --no-update --no-verification` | 733 chunks, 0 verified and 0 unverified secrets. Verification was left off so nothing was sent to a vendor |
| `git rev-list --all` | 37 commits, including merges. The gap versus gitleaks is merges and duplicate trees, not a skipped ref |
| Extra `git grep` over every reachable commit for token prefixes (`ghp_`, `github_pat_`, `sk-`, Slack/AWS key shapes), `BEGIN PRIVATE KEY`, `BEGIN CERTIFICATE`, phone numbers, and `/Users/` | No credential matches. Personal-data matches are listed below |

`git rev-list --all --count` was 37 because `a1c72c6` replaced, in the reachable set, the commits that had only been on a deleted remote branch. See branches below.

## Branches that would become public

`git ls-remote --heads origin` after a fetch on this date returned one branch:

- `main` at `a1c72c6e4b5d2f86ae663923a45804b09f4b4f50`

There are no tags.

`codex/screenclip-5be55114` was a remote-tracking branch in the environment snapshot and was **deleted on origin** by the time this audit fetched. It is not a branch that would become public. Before that fetch, its diff against `main` was review-queue code: `QueueView.swift`, `Models.swift`, `AppModel.swift`, `AgentWorker.swift`, tests, `scripts/review_queue.py`, the plugin server, and short doc edits. No `.env`, key, or certificate filenames. Those blobs were not reachable after the remote branch was pruned, so they were not in the gitleaks or trufflehog pass. GitHub may still serve a deleted branch's commits by SHA until it garbage-collects them. There is no branch ref to hide.

The only unreachable local commit `git fsck` still reported is `6b99ab1c68f1be3fc915feb81cf25e85ada5ce8d`, an earlier copy of the commit that landed as `c5b0936` ("Fix: I forgot to enter text…"). It is not on a branch.

## Findings

### Real secrets

None were found in the scanned tree or history: API tokens, private keys, certificates, `.env` files, credential-bearing webhook URLs, and `Authorization` header values. Grok Bot's webhook and header are stored in the Keychain at runtime (`ExternalAssistantKeychain`) and are not committed. Tests use example hosts such as `git@github.com` and `git@gitlab.com` inside remote-URL parsing. `ProcessEnvironment` names `GH_TOKEN`, `GITHUB_TOKEN`, and `SCREENCLIP_NOTARY_PROFILE` only to strip them from a child process. Those names are not values.

### Personal data

| What | Where | Class | Rewrite? |
| --- | --- | --- | --- |
| Author email, Gmail, local part starts with `land` | Author field of Ludovic Landry's commits (most of the history). Not printed in full here | Personal data, not a credential | No. Optional if that mailbox should not be public. Use a GitHub noreply address on future commits |
| `cursoragent@cursor.com` | Author of the Cursor Agent commits (`bdca085`, `ea15634`, `3165306`, `8ea83f8`, `00fe495`, `4bc8ca9`, `c3deb2a`) | Service mailbox | No |
| A `python3` example whose path starts with `/Users/ludo/` | `4294f368244109c6ea87702403f6c8cc8ec1d99f`, `docs/agent-integrations.md` line 43. The file was removed in `802d6776193e3e71666e60c5ac65911e7924e3d2` and is not on `main` | Personal data (a home path). Low sensitivity | No. It remains reachable in history |
| `/Users/me` as a fake `HOME` in a unit test | `Tests/ScreenClipCoreTests/SafetyTests.swift` on `a1c72c6` | Harmless fixture | No |
| Apple Team ID `D6826XDERA` | Introduced in `4e93de5239416382b5c8174d87f40568af91d49c` (`DEVELOPMENT_TEAM` in `project.pbxproj`) and removed in `a1c72c6`. Not on the current tree | Identifier, not a secret. It will also appear in any Developer ID signature | No |

No phone numbers. No other home directories.

### Harmless

| What | Where | Class |
| --- | --- | --- |
| Product screenshots | `docs/screenshots/composer-preview.png`, `docs/screenshots/queue-preview.png`, and the copies under `website/src/assets/` that existed at this commit (`composer-preview.png`, `queue-preview.png`). Later commits added `og.png`, `popup-light.png`, and `popup-dark.png`. There is no `social-preview.png` or `apple-touch-icon.png` in the tree; the site icons are generated by `website/build.py` | Demo images of the app, not `.screenclip/` evidence |
| `.screenclip/` evidence, capture PNGs from a real queue, or a `screenclip.sqlite` database | Not in any commit | Absent |
| Certificates, `.p12`, `.pem`, provisioning profiles, `.env` | Not in any commit | Absent |

## Files to add before the repo is public

These are not in the tree:

- `LICENSE`. Pick one before flipping visibility. This audit does not choose it.
- `CONTRIBUTING.md`.
- `SECURITY.md`. A short one should say that queue screenshots stay on the Mac, that the Grok Bot webhook and header live in the Keychain, and where to report a vulnerability.

`.github/FUNDING.yml` is added with this distribution work and names the GitHub Sponsors account `lludo`. It does not contain a payment secret.
