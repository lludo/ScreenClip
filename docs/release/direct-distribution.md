# Direct distribution

ScreenClip stays off the Mac App Store. The reason is [the sandbox study](app-store-sandbox.md). The release path is one tag-triggered GitHub Actions workflow: build the unsandboxed Release app, sign it with a Developer ID, notarize with `notarytool`, staple, write a DMG and `SHA256SUMS`, and attach both to a GitHub Release. The website's Download button points at that asset. A small tip window in the app opens GitHub Sponsors. Installed copies update themselves through Sparkle from a signed `appcast.xml` attached to the same release. A Homebrew cask formula is checked in for a personal tap; the release workflow does not publish or update that tap.

The step-by-step process for a release, including docs and website updates, is the [Release checklist](checklist.md).

People who clone the repo can build it themselves. The DMG is for someone who wants a signed app without Xcode. The tip is optional.

## Maintainer setup (one time)

1. Enroll in the Apple Developer Program if the account behind team `D6826XDERA` is not already active. Create a **Developer ID Application** certificate (not Apple Development, and not Mac App Store). Export it from Keychain Access as a `.p12` with a password.
2. In App Store Connect, create an **App Store Connect API** key with the Developer role. Download the `.p8` once. Note the Key ID and the Issuer ID. This key is only for notarization. It does not submit the app to the store.
3. Add these Actions secrets on `lludo/ScreenClip`. Do not commit any of them. Base64 the files with `base64 -i file | pbcopy` on a Mac:

   | Secret | Value |
   | --- | --- |
   | `APPLE_DEVELOPER_ID_P12_BASE64` | Base64 of the Developer ID `.p12` |
   | `APPLE_DEVELOPER_ID_P12_PASSWORD` | Password for that `.p12` |
   | `APPLE_SIGNING_IDENTITY` | The certificate's common name, for example `Developer ID Application: Name (TEAMID)` |
   | `APPLE_NOTARY_KEY_P8_BASE64` | Base64 of the `AuthKey_XXXX.p8` file |
   | `APPLE_NOTARY_KEY_ID` | The Key ID |
   | `APPLE_NOTARY_ISSUER_ID` | The Issuer ID |
   | `SPARKLE_ED_PRIVATE_KEY` | The Sparkle EdDSA private key. See [Updates](#updates) |

4. Turn on [GitHub Sponsors](https://github.com/sponsors/lludo) for the `lludo` account and finish the payout and tax steps. `.github/FUNDING.yml` already names that account. The in-app buttons open `https://github.com/sponsors/lludo`. The profile is not ready, and the website `donateUrl` is empty. Status is in [Publishing checklist](publishing-checklist.md#github-sponsors-and-the-donate-url).
5. `LICENSE.md` is the PolyForm Noncommercial License 1.0.0. Root [`CONTRIBUTING.md`](../../CONTRIBUTING.md) and [`SECURITY.md`](../../SECURITY.md) exist; the contributing workflow is in [Development](../development.md#contributing). Review the [publication audit](publication-audit.md) before publishing, and check anything committed after its date for private data. The checklist is in [Publishing checklist](publishing-checklist.md).

## What the tag does

Push a tag `v1.2.3` (three numbers). [`.github/workflows/release.yml`](../../.github/workflows/release.yml) then:

1. Stops immediately, with a notice and a green job, if none of the Apple secrets are set. If some are set and some are missing, the job fails. The gate checks the configured secrets at runtime; required values are listed under [Release secrets](publishing-checklist.md#release-secrets).
2. Writes the tag into `CFBundleShortVersionString` for that build. `Resources/Info.plist` takes its version from `MARKETING_VERSION` and its build number from `CURRENT_PROJECT_VERSION` in the Xcode project. Before tagging, bump `MARKETING_VERSION` in a release commit so local builds match. `CURRENT_PROJECT_VERSION` is an integer that goes up by one with every build, and the release keeps the committed value. The tag must match `X.Y.Z` (three numbers); `v1.0.0-rc1` fails.
3. Imports the Developer ID certificate into a temporary keychain, builds the Release scheme with `scripts/build.sh`, and passes `--timestamp` plus `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`.
4. Runs `scripts/release-dmg.sh`. That script refuses an App Sandbox signature. It notarizes a zip of the app, staples the app, builds a UDZO disk image with an Applications shortcut, signs and notarizes the DMG, staples the DMG, and writes `SHA256SUMS`.
5. Signs the DMG with the Sparkle key and writes `appcast.xml` (`scripts/make_appcast.py`), with the release notes from `docs/release/<tag>.md`.
6. Creates or updates the GitHub Release for that tag and uploads `ScreenClip.dmg`, `SHA256SUMS`, and `appcast.xml`.

The asset name is always `ScreenClip.dmg`, so this URL tracks the newest tag:

`https://github.com/lludo/ScreenClip/releases/latest/download/ScreenClip.dmg`

`downloadUrl` in `website/site.config.json` is set to that URL. Every release uploads `ScreenClip.dmg`, so the button always gets the newest one. An empty value renders the coming-soon state without a download link.

Check a download with `shasum -a 256 -c SHA256SUMS`.

A release can also be signed and notarized locally, without the Actions secrets: set `APPLE_SIGNING_IDENTITY` and a Keychain profile name in `SCREENCLIP_NOTARY_PROFILE`, then run `bash scripts/release-dmg.sh`. v1.0.0 was prepared this way; the commands are in [v1.0.0 readiness](v1.0.0-status.md). CI uses the API key instead of a Keychain profile, because the runner has no long-lived login keychain. `scripts/package.sh` only makes a development zip and is not part of the release. `notarytool` is required. Apple's current flow: [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

Release builds already set `ENABLE_HARDENED_RUNTIME = YES`. Debug builds do not. The Apple Events entitlement ScreenClip needs for the optional Safari and Chrome URL lookup is already in `Resources/ScreenClip.entitlements`.

## Updates

ScreenClip updates itself with [Sparkle 2](https://sparkle-project.org/documentation/). The settings are in `Resources/Info.plist`:

- `SUFeedURL` is `https://github.com/lludo/ScreenClip/releases/latest/download/appcast.xml`, so the feed always comes from the newest release.
- `SUPublicEDKey` is the EdDSA public key. Sparkle refuses a DMG whose signature does not match it.
- `SUEnableAutomaticChecks` and `SUAutomaticallyUpdate` are on: the app checks once a day without asking first, downloads a new version in the background, and installs it when ScreenClip quits. A menu bar app rarely quits, so a downloaded update also shows an **Update to X** button in the menu bar popover that installs and relaunches. Quitting goes through the usual checks, so an open capture or running work stops it.
- Settings → General → Updates turns automatic installation off and has **Check for Updates…**; the popover's **⋯** menu has it too.

Debug builds do not check unless launched with `--check-updates`, so a development copy is not replaced by the public release. `swift build` and `swift test` do not include Sparkle; `Updater.swift` compiles to a no-op there.

`sparkle:version` is `CFBundleVersion`, so every release needs a higher `CURRENT_PROJECT_VERSION` than the one before. Copies older than the first Sparkle build (1.0.2 and earlier) have no updater and need one manual download.

### The signing key

The private key was generated with Sparkle's `generate_keys --account ScreenClip` and lives in the maintainer's login keychain (item "Private key for signing Sparkle updates"). Back it up: losing it means existing copies cannot verify new updates until people download a build with a new public key by hand.

- **CI**: export it with `.local/XcodePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account ScreenClip -x sparkle_key`, then `gh secret set SPARKLE_ED_PRIVATE_KEY < sparkle_key` and delete the file. The release job fails if the Apple secrets are set and this one is not.
- **Local release**: `scripts/release-dmg.sh` signs with the keychain key when `SPARKLE_ED_PRIVATE_KEY` is unset, and writes `build/appcast.xml`. Before signing anything it checks that `docs/release/vX.Y.Z.md` exists for the app's version, and that the version and build number are both higher than the published appcast's; it stops if the appcast cannot be downloaded (set `SCREENCLIP_SKIP_FEED_CHECK=1` only for the very first release). Publish with `gh release create vX.Y.Z build/ScreenClip.dmg build/SHA256SUMS build/appcast.xml --title "ScreenClip X.Y.Z" --notes-file docs/release/vX.Y.Z.md`; use `gh release upload … --clobber` only to replace files on a release that already exists.

So far every release has been published this way from the maintainer's Mac: the Apple secrets are not set in the repository, so the tag's workflow finishes without building.

Never commit the private key.

## Homebrew

A personal tap is the easy install. Official [homebrew-cask](https://docs.brew.sh/Acceptable-Casks) wants a pinned version, a checksum, a livecheck, and enough users. A brand-new app will not pass that review. `version :latest` and `sha256 :no_check` are rejected there.

`packaging/homebrew/Casks/screenclip.rb` is a formula for a tap named `lludo/homebrew-tap` (the GitHub repo `lludo/homebrew-tap`, file `Casks/screenclip.rb`). It is not installed by this repo, and the tap does not exist yet. Once it does:

```sh
brew tap lludo/homebrew-tap
brew install --cask screenclip
```

The formula points at the same `releases/latest/download/ScreenClip.dmg` asset. Its homepage is the GitHub repository. When you want a pinned cask, replace `:latest` and `:no_check` with the tag and the `SHA256SUMS` line, then commit that change in `lludo/homebrew-tap`. Nothing in `.github/workflows/release.yml` edits the formula.

## Tip window

The direct-download build shows a small tip window. When it appears, how to dismiss it, and where to reopen it are in the [user guide](../user-guide.md#tip-window). The parts that matter for a release:

- The opt-out, the snooze, and the first-launch date are stored in the queue. Saving Settings does not wipe them. Those fields are optional in the queue JSON so older queues still open.
- Each amount button opens GitHub Sponsors. GitHub does not offer a stable URL that pre-fills the amount, so the person chooses the amount on that page.

`DistributionChannel.offersDonations` is false when the app is built with the Swift flag `SCREENCLIP_APP_STORE`. The window, the menu item, and the Settings section are compiled out in that case. Do not set the flag for the GitHub build. Guideline 3.1.1 is why the flag exists: payments for the app, including a tip jar, are an In-App Purchase question on the store, and external payment links are restricted by storefront. The [App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/#in-app-purchase) are the reference. This project does not submit to the store, so the flag stays unset.

### Tip service

The app links to GitHub Sponsors. Complete the Sponsors profile and payout setup before relying on the link; if a different service is chosen, update the app and website links together.
