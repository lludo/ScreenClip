# Direct distribution

ScreenClip stays off the Mac App Store. The reason is [the sandbox study](app-store-sandbox.md). The release path is one tag-triggered GitHub Actions workflow: build the unsandboxed Release app, sign it with a Developer ID, notarize with `notarytool`, staple, write a DMG and `SHA256SUMS`, and attach both to a GitHub Release. The website's Download button points at that asset. A small tip window in the app opens GitHub Sponsors. Sparkle is not in this pipeline. A Homebrew cask formula is checked in for a personal tap; the release workflow does not publish or update that tap.

People who clone the repo can build it themselves. The DMG is for someone who wants a signed app without Xcode. The tip is optional.

## What Ludo does once

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

4. Turn on [GitHub Sponsors](https://github.com/sponsors/lludo) for the `lludo` account and finish the payout and tax steps. `.github/FUNDING.yml` already names that account. The in-app buttons open `https://github.com/sponsors/lludo`. The profile is not ready, and the website `donateUrl` is empty. Status is in [Publishing checklist](../open-source.md#github-sponsors-and-the-donate-url).
5. `LICENSE.md` is the PolyForm Noncommercial License 1.0.0. Root `CONTRIBUTING.md` and `SECURITY.md` are still missing. The contributing workflow is in [Development](../development.md#contributing). Review the [open-source audit](open-source-audit.md) and scan changes since its recorded commit before publishing. The checklist is in [Publishing checklist](../open-source.md).

## What the tag does

Push a tag `v1.2.3` (three numbers). [`.github/workflows/release.yml`](../../.github/workflows/release.yml) then:

1. Stops immediately, with a notice and a green job, if none of the Apple secrets are set. That is the current state: the secrets are not configured ([open TODOs](../open-source.md#release-secrets)). If some are set and some are missing, the job fails.
2. Writes the tag into `CFBundleShortVersionString` and `CFBundleVersion` for that build only. The copy of `Resources/Info.plist` in git is not updated. Local builds keep the versions checked in there. `MARKETING_VERSION` in the Xcode project is unused while `GENERATE_INFOPLIST_FILE` is off.
3. Imports the Developer ID certificate into a temporary keychain, builds the Release scheme with `scripts/build.sh`, and passes `--timestamp` plus `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`.
4. Runs `scripts/release-dmg.sh`. That script refuses an App Sandbox signature. It notarizes a zip of the app, staples the app, builds a UDZO disk image with an Applications shortcut, signs and notarizes the DMG, staples the DMG, and writes `SHA256SUMS`.
5. Creates or updates the GitHub Release for that tag and uploads `ScreenClip.dmg` and `SHA256SUMS`.

The asset name is always `ScreenClip.dmg`, so this URL tracks the newest tag:

`https://github.com/lludo/ScreenClip/releases/latest/download/ScreenClip.dmg`

The website uses that URL (`website/site.config.json`). Until the first tag exists, the link has no file. The page says so.

Check a download with `shasum -a 256 -c SHA256SUMS`.

A local notarization can still use `SCREENCLIP_SIGNING_IDENTITY` and a Keychain profile in `SCREENCLIP_NOTARY_PROFILE` via `scripts/package.sh`. CI uses the API key instead of a Keychain profile, because the runner has no long-lived login keychain. `notarytool` is required. Apple's current flow: [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

Release builds already set `ENABLE_HARDENED_RUNTIME = YES`. Debug builds do not. The Apple Events entitlement ScreenClip needs for the optional Safari and Chrome URL lookup is already in `Resources/ScreenClip.entitlements`.

## Updates

Sparkle 2 is the usual Mac auto-update library: an EdDSA key pair, `SUPublicEDKey` in the app, a signed appcast, and a feed URL. GitHub Releases can host the appcast, or it can live on screenclipai.com. The private key would be another Actions secret and must never be committed. Rotating it means shipping a new build that contains the new public key.

That is a second piece of signing machinery, a framework to embed, and an appcast to keep in sync with the DMG. The first release does not include it. Someone who wants an update downloads the latest DMG again. Add Sparkle later if install friction shows up. Sparkle's own guide: [Sparkle documentation](https://sparkle-project.github.io/documentation/).

## Homebrew

A personal tap is the easy install. Official [homebrew-cask](https://docs.brew.sh/Acceptable-Casks) wants a pinned version, a checksum, a livecheck, and enough users. A brand-new app will not pass that review. `version :latest` and `sha256 :no_check` are rejected there.

`packaging/homebrew/Casks/screenclip.rb` is a formula for a tap named `lludo/homebrew-tap` (the GitHub repo `lludo/homebrew-tap`, file `Casks/screenclip.rb`). It is not installed by this repo. After the first release:

```sh
brew tap lludo/homebrew-tap
brew install --cask screenclip
```

The formula points at the same `releases/latest/download/ScreenClip.dmg` asset. Its homepage is the GitHub repository. When you want a pinned cask, replace `:latest` and `:no_check` with the tag and the `SHA256SUMS` line, then commit that change in `lludo/homebrew-tap`. Nothing in `.github/workflows/release.yml` edits the formula.

## Tip window

The direct-download build shows a small window, not a system sheet, because the menu-bar app often has no other window open.

- It appears on its own after 3 merged or verified fixes, including archived ones, or after the queue has existed for 7 days. Whichever comes first.
- **Not now**, or closing the window, hides it for 30 days. Closing it after opening it from the menu does the same.
- **Don't ask again** stores an opt-out in the queue and the automatic prompt stops.
- The same window is always available from the menu's **Support ScreenClip…** and from **Settings → General → Support**, including after opt-out.
- The suggested amounts are $3, $5, and $10. Each button opens GitHub Sponsors. GitHub does not offer a stable URL that pre-fills the amount, so the person chooses the amount on that page.
- Saving Settings does not wipe the opt-out, the snooze, or the first-launch date. Those fields are optional in the queue JSON so older queues still open.
- Preview and integration launches do not show it. While ScreenClip hides itself for a capture, the window is ordered out so it is not in the screenshot.

`DistributionChannel.offersDonations` is false when the app is built with the Swift flag `SCREENCLIP_APP_STORE`. The window, the menu item, and the Settings section are compiled out in that case. Do not set the flag for the GitHub build. Guideline 3.1.1 is why the flag exists: payments for the app, including a tip jar, are an In-App Purchase question on the store, and external payment links are restricted by storefront. The [App Store Review Guidelines](https://developer.apple.com/app-store/review/guidelines/#in-app-purchase) are the reference. This project does not submit to the store, so the flag stays unset.

### Tip service

The app links to GitHub Sponsors. Complete the Sponsors profile and payout setup before relying on the link; if a different service is chosen, update the app and website links together.
