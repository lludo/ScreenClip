# Open-source audit

Rescanned on November 14, 2026 against `origin/main` at `e32f81b39ed34ccc1304e9be9acbcbb758fba58f`, `origin/claude/unstick-agent-runs`, `origin/cursor/grok-bot-handoff-trace-debb`, and every `refs/pull/*/head`. The repository was still private. This scan did not rewrite history or change visibility.

A rewrite earlier the same day already removed the real queue snapshot and the real menu-bar captures from **branch** history. That rewrite is commit `58a0870` on the new history. It is not enough. Six pull-request refs still point at the pre-rewrite commits, and two of those refs still have the private files in the tip tree. Publishing the repository publishes those refs.

## Current branch tips

`main`, `claude/unstick-agent-runs`, and `cursor/grok-bot-handoff-trace-debb` do not contain `Fixtures/ScreenshotData`, `/Users/<redacted>`, `MemoVault`, or `com.ludoviclandry.Genealogy`.

| Checked on `main` | Result |
| --- | --- |
| Screenshot queue | `ScreenshotFixture.materialize()` builds a temporary directory and `PreviewSupport.seed` fills it with the synthetic **Demo storefront** project. |
| Localization screenshots | `scripts/render-localizations.sh` writes `build/localization-screenshots/`. `build/` is gitignored. Those PNGs are not committed. |
| Marketing stills | The README includes an app screenshot supplied and approved for sharing by the owner; the menu and capture-editor examples use demo data. The website popup images use demo data. |
| `.gitignore` | Ignores `Fixtures/ScreenshotData/` so a later copy of the queue is not added by accident. |
| Secrets | No token, private key, webhook URL, or `.env` in the tree. `scripts/send_test_webhook.py` reads the URL from the environment. |

Apple Team ID `D6826XDERA` is still named in [Direct distribution](direct-distribution.md). It is not in `project.pbxproj`. It is an identifier, not a credential.

## What the branch rewrite already removed

The new history does not contain the 68 paths under `Fixtures/ScreenshotData/` or these six real popup blobs:

| Old path | Blob that was removed from branch history |
| --- | --- |
| `website/src/assets/popup-light.png` | `dc5da3cf513c18d559bc6270641fadbdacf14d5d` |
| `website/src/assets/popup-dark.png` | `b2ab1d2f298c1de389776978f794cd136b813f5c` |
| `website/src/assets/popup-light.webp` | `a449cc31b844a1009e850ed09eb101bdeaee5e83` |
| `website/src/assets/popup-dark.webp` | `65ba017effcddc12a3b625a2bf345270ae1a6dd6` |
| `website/src/assets/popup-light.avif` | `f75888249489060441223a23ab53eb0e7a16e06f` |
| `website/src/assets/popup-dark.avif` | `dd763bb83cbdc2aaa6f8a35b968bded9305bb70d` |

The synthetic PNGs that replaced them are `44b2b3e754a972670492d8df3eb2624adff2281d` (light) and `d642fa8eee5a2620040d17a42259c0a660ad49db` (dark). That was the release-audit guidance at the time. The website now uses localized menu images rendered from an isolated snapshot of real ScreenClip reports, at the owner’s request; reassess their contents before publication.

Most author addresses on the rewritten branches are `631630+lludo@users.noreply.github.com`. The home-directory string in the old `docs/agent-integrations.md` example is gone.

## Pull-request refs that still have the private files

`git ls-remote origin 'refs/pull/*/head'` still returns the pre-rewrite commits. A normal branch rewrite does not move these refs. They are fetchable as `refs/pull/<n>/head`.

| Ref | Tip | What is still there |
| --- | --- | --- |
| `refs/pull/25/head` | `993cecf941a96d9275b3394c52cfb828af455bcb` | **The tip tree contains all 68 `Fixtures/ScreenshotData` files**, including `screenclip.sqlite` and the family photograph. It also contains the real `popup-light.png` blob above. |
| `refs/pull/24/head` | `e781e8c16e0962845dd3770872fa0d4c0cedeace` | Tip contains the real popup blobs. |
| `refs/pull/26/head` | `bbcde390fddf3c9505e8a165c1677e7871adce86` | Tip contains the real popup blobs. |
| `refs/pull/28/head` | `1c93d1a38d5bbf5acbf6d84f5206f151b7fe1a95` | History contains the snapshot commit `336b09f4010cd745bae1cd66e2fe54eb1380844b` and the real popup commit `d78d3cfd3d255277862ca86b3e1ee7c70c072b25`. The tip tree does not. |
| `refs/pull/29/head` | `b9a8e7bb01d451f76e6959adca7eb2af628415f4` | Same: history contains `336b09f` and `d78d3cf`. |
| `refs/pull/30/head` | `847bcdb3374eea2cd46c95184e5612b20b920813` | Same: history contains `336b09f` and `d78d3cf`. |

The other pull refs (1–23, 31, 32) do not contain those commits or blobs.

`Fixtures/ScreenshotData/` on `refs/pull/25/head` is a copy of the real ScreenClip queue: projects ScreenClip, Genealogy, and MemoVault, 28 reports, and the captures. Sampled images include a family photograph (`assets/23CA7786-3604-4971-88E0-52968358A832.png`) and a photograph of a private property (`assets/61593962-7546-4BEC-9E99-0AE504DC8387.png`, with `originals/4C6718B6-82C2-48F7-A878-5628C40DE367.png`). The database blob is `1237a773a86e844e7c79bdee35cf5e507b44eb9a`. It has no email, token, or webhook URL. It does have:

| String | Where |
| --- | --- |
| `/Users/<redacted>/Documents-Local/GitHub/ScreenClip` | Project path |
| `/Users/<redacted>/Documents-Local/GitHub/Genealogy` | Project path |
| `/Users/<redacted>/Documents-Local/GitHub/MemoVault` | Project path |
| `/Users/<redacted>/Library/Application Support/ScreenClip/{assets,originals,worktrees}/…` | Capture and worktree paths |
| `com.ludoviclandry.Genealogy` | Bundle id |
| `Ludo Library`, `Greek Gods v8` | Window titles |
| `https://github.com/lludo/Genealogy/pull/1429`–`1433` and `1435`–`1437` | Result links |
| 28 original report titles and notes | Not copied into this file |

The same commit also stored this Swift string, which the rewrite removed from the branches and which the pull refs still have:

`/Users/<redacted>/Library/Application Support/ScreenClip/`

in `Sources/ScreenClip/ScreenshotFixture.swift` at `336b09f`.

Every path on that pull ref:

```
Fixtures/ScreenshotData/screenclip.sqlite
Fixtures/ScreenshotData/assets/07D8E4DE-2CFA-471E-BB04-C37CE68B0433.png
Fixtures/ScreenshotData/assets/1056D643-99F1-4215-AFD6-F39E3AEFBAF6.png
Fixtures/ScreenshotData/assets/1399F5FC-19CD-4E9A-8691-59710572B34F.png
Fixtures/ScreenshotData/assets/1CC1A98C-5205-4ABE-A4FB-48C9F0EAD166.png
Fixtures/ScreenshotData/assets/20CD8AD4-8D72-450F-92A0-17DD44871DEA.png
Fixtures/ScreenshotData/assets/23CA7786-3604-4971-88E0-52968358A832.png
Fixtures/ScreenshotData/assets/2A29043B-E4A6-4917-B35D-3403C927C717.png
Fixtures/ScreenshotData/assets/365B702E-3E62-499B-88CB-6B1E05F2FA10.png
Fixtures/ScreenshotData/assets/37D980EB-F61E-4EAA-BAA4-82B850AB02A9.png
Fixtures/ScreenshotData/assets/3AC4EC05-5374-4D46-B1AF-965FBB2F34B1.png
Fixtures/ScreenshotData/assets/5B56E5E5-D21D-4515-904E-8458DF07FD68.png
Fixtures/ScreenshotData/assets/61593962-7546-4BEC-9E99-0AE504DC8387.png
Fixtures/ScreenshotData/assets/61949748-E054-4308-9C09-323A36BFEDFE.png
Fixtures/ScreenshotData/assets/714ECA97-B91E-4FCC-9C6A-5ED3E47B6B60.png
Fixtures/ScreenshotData/assets/7180BFC2-2D68-4694-B43C-56F560EA482A.png
Fixtures/ScreenshotData/assets/719BE2DD-629F-4E30-8CE4-9679B8D292B0.png
Fixtures/ScreenshotData/assets/8457CB3A-7EEB-4F4E-BF50-954373D9BBBE.png
Fixtures/ScreenshotData/assets/89051B2E-CD88-4BAF-9EAE-AFA78F5523E5.png
Fixtures/ScreenshotData/assets/8A0C1E29-1E2B-4F05-B400-3531D3413471.png
Fixtures/ScreenshotData/assets/A0683795-10E1-492C-BB4B-7B4DEDABD2E5.png
Fixtures/ScreenshotData/assets/A0F9F13E-86ED-41EE-B4E7-A6547DB41F6A.png
Fixtures/ScreenshotData/assets/B67D21AC-CF96-432F-8188-972DCB8875DF.png
Fixtures/ScreenshotData/assets/BBC8CD7B-B850-4C37-A752-26461E8CB730.png
Fixtures/ScreenshotData/assets/BFBDB503-24DA-4FB1-A241-97827AF9E0A6.png
Fixtures/ScreenshotData/assets/C8FBE5EE-0B0E-4F72-9EC2-2930E1574C27.png
Fixtures/ScreenshotData/assets/CD766B43-A7F7-4445-99EF-2A69DAC2B6E9.png
Fixtures/ScreenshotData/assets/DDD35754-CFF4-4F5F-9B25-367DA16BE45C.png
Fixtures/ScreenshotData/assets/EE471DA1-AD2E-409C-9139-19DD7B02DF66.png
Fixtures/ScreenshotData/assets/F215742B-8DC5-49AE-85E0-6BB291932C13.png
Fixtures/ScreenshotData/assets/F82F2E17-8275-4185-9D5D-72A1FACE39FE.png
Fixtures/ScreenshotData/assets/F9E487F2-C3E2-4020-A4C7-09243574AF06.png
Fixtures/ScreenshotData/originals/034488E2-AF5F-4EFE-87F1-7D43E7677B4A.png
Fixtures/ScreenshotData/originals/0AF3EA91-90D7-4E95-AC8E-84AC0C2319B3.png
Fixtures/ScreenshotData/originals/176CFC11-2899-4E32-80C7-8A2F8B708620.png
Fixtures/ScreenshotData/originals/196FDA14-0BB2-464C-8586-B2D2D4466D7A.png
Fixtures/ScreenshotData/originals/21881958-4A2F-4FBA-9882-A3433998AF08.png
Fixtures/ScreenshotData/originals/245BC491-ED50-48D0-BD1E-FC4FC4403F31.png
Fixtures/ScreenshotData/originals/2B7FE52A-62B4-45CA-87FB-4148277F3340.png
Fixtures/ScreenshotData/originals/329A15C5-5F2F-430E-AF80-7414DD380125.png
Fixtures/ScreenshotData/originals/355A16CE-078C-4A48-91C3-3B38E5944F3E.png
Fixtures/ScreenshotData/originals/40537D66-5DC7-47C6-99E1-21AD518F06B4.png
Fixtures/ScreenshotData/originals/430AC7D0-FEAE-4D8E-A2EB-6073FD71CDC0.png
Fixtures/ScreenshotData/originals/433A25F8-0BFA-475B-8D61-903B5450BDDB.png
Fixtures/ScreenshotData/originals/4716FEC5-960A-4E75-A3B6-3C525235411F.png
Fixtures/ScreenshotData/originals/4A0B5BEE-5403-4085-8043-4D4DD56D8D8D.png
Fixtures/ScreenshotData/originals/4C6718B6-82C2-48F7-A878-5628C40DE367.png
Fixtures/ScreenshotData/originals/57811245-1977-4F1F-A547-4BF0DAF43E68.png
Fixtures/ScreenshotData/originals/5F77CC1B-A854-427E-BE10-B5A98F0C1691.png
Fixtures/ScreenshotData/originals/62FAAEC7-5C2A-49E4-A7FC-94B442AEFEBC.png
Fixtures/ScreenshotData/originals/6639A8D2-AAC8-40E5-A0E0-C5533FBD6E45.png
Fixtures/ScreenshotData/originals/6FFD37EB-FDCD-4B77-814C-193CAE66E560.png
Fixtures/ScreenshotData/originals/7B6238E4-E806-4DBE-8F9C-B0B83204EA21.png
Fixtures/ScreenshotData/originals/85B2CE39-CA40-49AF-9C1B-3281604E2305.png
Fixtures/ScreenshotData/originals/A0912FB3-8F0B-463D-88CF-130186B9C379.png
Fixtures/ScreenshotData/originals/A9E131F7-ABD4-4169-BA53-EA733AE4628C.png
Fixtures/ScreenshotData/originals/BA0FF98F-68FD-4936-95D7-F779A79CC670.png
Fixtures/ScreenshotData/originals/BEFF4FD8-965D-4F8A-8BAF-897114905FF5.png
Fixtures/ScreenshotData/originals/C8F3F04F-2EAB-41FF-A741-4894462DDA97.png
Fixtures/ScreenshotData/originals/CC27301E-A4D5-4B60-9598-B83DC6F3B4CF.png
Fixtures/ScreenshotData/originals/E0B9DB2A-E203-42F9-848D-26FF4F650447.png
Fixtures/ScreenshotData/originals/FD622118-0A67-468F-8DE1-0F533B9346C2.png
Fixtures/ScreenshotData/runs/2BFB9C6A-1EEC-4BEF-82D9-16C46198D794.json
Fixtures/ScreenshotData/runs/4BFE57B6-8034-42C0-8795-4B9834516476.json
Fixtures/ScreenshotData/runs/5AF254F6-7D5F-4A09-8F07-C4CB64ADF8DF.json
Fixtures/ScreenshotData/runs/5BE55114-771E-4458-8D99-BA1ED5399633.json
Fixtures/ScreenshotData/runs/D88A1B19-93F5-47B8-A23B-90905D23EBA6.json
Fixtures/ScreenshotData/runs/E5ADABF7-3041-4AA2-B403-2686031746B2.json
```

The real menu-bar captures show report text from that same queue (`#24`, `#25`, `#26`) and thumbnails of real captures.

## Still on the rewritten `main`

These are not the photographs. They survived the rewrite.

| What | Where |
| --- | --- |
| Personal Gmail as the author address | The audit found this in two commits created after the initial rewrite. The address is not repeated here; a subsequent branch-history cleanup replaces it with a GitHub noreply address. GitHub pull-request refs may still retain earlier metadata. |
| Raw ScreenClip note used as the commit subject | `7874fb1` and `de80622`: "Fix: lets fix up the UI here the content is bleading out of the window. Check margins and alignements." `c6a5a07`: "Fix: Right align all the buttons here and verticali align the Edit buttons in their cells." |

No token, private key, or webhook URL turned up in `git log --all -p` or in `git grep` of the rewritten branch tips. `/Users/me` and `/Users/x` in tests are fake home paths.

## What to do before the repository is public

Another `git filter-repo` pass on the branches will not remove `refs/pull/25/head`. That ref's tip is the family photograph. Squashing `main` again, and leaving this GitHub repository in place, also leaves the pull refs.

Use a new repository, or have GitHub purge the old objects, before flipping visibility.

1. Create a new repository, or an orphan commit, from the current `main` tree. Author it with `631630+lludo@users.noreply.github.com`. Keep the synthetic screenshots and `ScreenshotFixture` as they are. Drop the path list in this file from that commit if the public tree should not repeat the home directories.
2. Push that commit as the only branch. Do not push the old pull-request heads.
3. If the public project must stay in `lludo/ScreenClip`, ask GitHub to delete the cached views and the pre-rewrite objects, including `refs/pull/24/head`, `refs/pull/25/head`, `refs/pull/26/head`, `refs/pull/28/head`, `refs/pull/29/head`, and `refs/pull/30/head`, before changing visibility. Closing those pull requests does not by itself delete the commits. Until GitHub garbage-collects them, anyone who knows the SHA can fetch `993cecf` and `336b09f`.
4. The two Gmail author commits and the three raw commit subjects go away if step 1 is a single new commit. They are a reason to prefer that over keeping the rewritten branch history. They are not a reason to skip the pull-ref purge.

This scan also pushed the pre-rewrite snapshot to `cursor/public-history-audit-f3bf` and then deleted that branch. Treat `dacd9da0779c54494b0bd5398054db91171d4f1f` and its parent `e440b3cc4930b19d1b69fbede1251508a55394e2` as further SHAs GitHub may still serve until garbage collection. They contain the same snapshot.
