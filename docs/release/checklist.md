# Release checklist

Every step for cutting `vX.Y.Z`, in order. Follow it top to bottom for every release, including small ones. [Direct distribution](direct-distribution.md) explains the signing, notarization and update machinery behind these steps.

Until the Apple secrets are set in the repository, every release is built and published from the maintainer's Mac (steps 8–11). The tag's workflow then finishes green without building.

## 1. Start from everything

- [ ] `git switch main && git pull --ff-only && git fetch --prune`.
- [ ] `gh pr list --state open` is empty, or each open PR is merged or deliberately left out.
- [ ] In ScreenClip, no report on the ScreenClip project is **Queued**, **Working**, **Needs you** or **PR open**, unless it is deliberately left for the next release. Merge a report's own PR rather than folding it into the release branch, so ScreenClip sees it merged and moves the report to **To retest**.
- [ ] Delete merged side branches, locally and on GitHub. Check each with `gh pr list --state all --head <branch>` first, since the repository squash-merges and `git branch --merged` doesn't see squashed work. `git worktree list` shows only the main checkout.

## 2. Review everything since the last release

- [ ] Review `git diff vPREVIOUS..main` in full: app UI, worker and core, ScreenClipKit and the wire format, the MCP plugin, release tooling, docs and website. Look for regressions, state that persists (new saved fields must decode from old payloads), localization (all 10 languages), two places that compute the same thing differently, and the SDK in both directions: the new SDK with the previous Mac release, the previous SDK with the new Mac, and a Release build that still contains none of it.
- [ ] Fix every finding in the release branch (`release-X.Y.Z`), with tests for behavior changes.

## 3. Version and build number

- [ ] `MARKETING_VERSION = X.Y.Z` in both the Debug and Release configurations of `ScreenClip.xcodeproj/project.pbxproj`. The appcast names the release by this value, so a stale version makes Sparkle download the wrong DMG.
- [ ] `CURRENT_PROJECT_VERSION` higher than the published `sparkle:version` (`curl -sL https://github.com/lludo/ScreenClip/releases/latest/download/appcast.xml`), in both configurations. It also goes up by one with every build.

## 4. Release notes

- [ ] Write `docs/release/vX.Y.Z.md` in the shape of the previous notes (when `docs/release/next.md` holds a draft, rename it with `git mv` and drop its row from `docs/release/README.md`): a `# ScreenClip X.Y.Z` title, a one-line lead, `## New`, `## Fixes`, then `## Install`. Everything between the title and `## Install` becomes the update notes Sparkle shows; the whole file becomes the GitHub Release notes. `release-dmg.sh` and `make_appcast.py` refuse to run without it.
- [ ] Use the app's UI names exactly as in `Sources/ScreenClip/Localizable.xcstrings`, and the SDK's as in `Sources/ScreenClipKit`.
- [ ] In `## Install`, name the ScreenClipKit version to use and the ScreenClip version it needs on the Mac.

## 5. Docs

- [ ] `README.md`: "The current release is X.Y.Z" and its notes link.
- [ ] `docs/README.md` and `docs/release/README.md`: a new row above the previous release.
- [ ] `docs/getting-started.md`: add the release to the "later changes" list.
- [ ] `docs/user-guide.md`, `docs/product-spec.md`, `docs/agents/`, `docs/ios-sdk.md`, `plugins/screenclip/README.md` and its skills, and `SECURITY.md` describe every new or changed behavior.
- [ ] Version statements in `docs/ios-sdk.md` and the DocC articles in `Sources/ScreenClipKit/ScreenClipKit.docc` (which SDK version added an API, which ScreenClip the Mac needs).
- [ ] `version` in `plugins/screenclip/plugin.json` and `plugins/screenclip/.claude-plugin/plugin.json` matches `serverInfo` in `plugins/screenclip/server.py` when the server's tools changed.

## 6. Website

The site deploys from `main`, so these changes go live when the release PR merges. Publish the GitHub Release (step 11) right after merging.

- [ ] Version in `download.title`, `download.noteReady` and `support.statusReady`, in all 10 `website/locales/*.json` files. `iosPage.setupIntro` names the ScreenClip version the SDK needs on the Mac. Write versions in full everywhere (1.2.0, never 1.2).
- [ ] If the report sheet on iOS changed: `python3 scripts/sdk_screenshots.py` redraws `composer.png` for the site and the SDK documentation.
- [ ] If the SDK's public API, doc comments or `ScreenClipKit.docc` changed, or the screenshot was redrawn: `python3 scripts/build_sdk_docs.py`, and commit `website/sdk/`.
- [ ] `app["softwareVersion"]` in `website/build.py`.
- [ ] If the app or site now sends anything new anywhere, update the privacy policy (`privacy.*` in all 10 locales) and its `privacy.updated` date.
- [ ] `python3 website/build.py`. When it prints "vercel.json security headers do not match", copy the expected `Content-Security-Policy` into `website/vercel.json` and build again.
- [ ] `node website/test_locale.mjs`.

## 7. Checks and release PR

- [ ] `bash scripts/test.sh` (localizations plus all Swift tests), `python3 scripts/test_plugin.py`, `python3 scripts/test_review_queue.py`, `python3 scripts/test_external_assistant.py`, `python3 scripts/check_localizations.py`.
- [ ] `python3 scripts/test_ios_sdk.py` (the SDK's unit and UI tests on a simulator, and the Release build without the SDK).
- [ ] Commit, push `release-X.Y.Z`, open the PR, wait for CI to pass, and squash-merge it. Squash is the only merge method the repository allows.

## 8. Build from the merged main

```bash
git switch main && git pull --ff-only
```

```bash
bash scripts/build.sh release DEVELOPMENT_TEAM=D6826XDERA CODE_SIGN_STYLE=Manual CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS=--timestamp
```

- [ ] `/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' -c 'Print :CFBundleVersion' build/DerivedData/Build/Products/Release/ScreenClip.app/Contents/Info.plist` prints the new version and build.

## 9. Sign, notarize, write the appcast

```bash
APPLE_SIGNING_IDENTITY="Developer ID Application: Ludovic Landry (D6826XDERA)" SCREENCLIP_NOTARY_PROFILE=ScreenClip-notary bash scripts/release-dmg.sh
```

It checks the release notes, version and build number against the published appcast, re-signs Sparkle's helpers with the Developer ID, notarizes and staples the app and the DMG, and writes `build/ScreenClip.dmg`, `build/SHA256SUMS` and `build/appcast.xml`, signed with the Sparkle key from the login keychain. Both notarizations must say **Accepted**.

## 10. Tag

```bash
git tag vX.Y.Z && git push origin vX.Y.Z
```

Tag the merge commit the DMG was built from. The tag is also the ScreenClipKit version Swift Package Manager resolves, so never move a published tag.

## 11. Publish

```bash
gh release create vX.Y.Z build/ScreenClip.dmg build/SHA256SUMS build/appcast.xml --title "ScreenClip X.Y.Z" --notes-file docs/release/vX.Y.Z.md
```

If the tag's workflow already created the release, use `gh release upload vX.Y.Z build/ScreenClip.dmg build/SHA256SUMS build/appcast.xml --clobber` and `gh release edit vX.Y.Z --notes-file docs/release/vX.Y.Z.md`.

## 12. Verify what people get

In an empty folder:

- [ ] Download `https://github.com/lludo/ScreenClip/releases/latest/download/ScreenClip.dmg` and `…/SHA256SUMS`; `shasum -a 256 -c SHA256SUMS` passes.
- [ ] `spctl -a -t open --context context:primary-signature -v ScreenClip.dmg` says `source=Notarized Developer ID`, and `xcrun stapler validate ScreenClip.dmg` passes.
- [ ] `curl -sL https://github.com/lludo/ScreenClip/releases/latest/download/appcast.xml` shows the new `sparkle:version` and `sparkle:shortVersionString`, and its enclosure URL downloads (`curl -sIL <url>` ends in 200).
- [ ] [screenclipai.com](https://screenclipai.com) shows the new version once Vercel has deployed `main`, and [the SDK documentation](https://screenclipai.com/sdk/documentation/screenclipkit) shows any new API.
- [ ] `git ls-remote --tags https://github.com/lludo/ScreenClip vX.Y.Z` lists the tag, so the Swift package resolves `from: "X.Y.Z"`.
- [ ] On a Mac running the previous release, **Check for Updates…** offers the new version, installs it and relaunches. The bottom of Settings shows the new version and build.
- [ ] The tag's GitHub Actions run is green.

## 13. Clean up

- [ ] Delete the `release-X.Y.Z` branch locally and on GitHub. `git branch -a` shows only `main`.
- [ ] `gh pr list --state open` is empty.
- [ ] Reports whose PRs shipped are under **To retest** in ScreenClip.
