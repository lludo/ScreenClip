# Direct distribution

ScreenClip stays off the Mac App Store. The reason is [the sandbox study](app-store-sandbox.md). The release path is one tag-triggered GitHub Actions workflow: build the unsandboxed Release app, sign it with a Developer ID, notarize with `notarytool`, staple, write a DMG and `SHA256SUMS`, and attach both to a GitHub Release. The website's Download button points at that asset. A small tip window in the app opens GitHub Sponsors. Sparkle and a Homebrew cask are optional and are not in the first pipeline.

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

4. Turn on [GitHub Sponsors](https://github.com/sponsors/lludo) for the `lludo` account and finish the payout and tax steps. `.github/FUNDING.yml` already names that account. The in-app buttons open `https://github.com/sponsors/lludo`.
5. When the repo should be public, add a `LICENSE` first. `CONTRIBUTING.md` and `SECURITY.md` are still missing. The [open-source audit](open-source-audit.md) says history does not need a rewrite.

## What the tag does

Push a tag `v1.2.3` (three numbers). [`.github/workflows/release.yml`](../../.github/workflows/release.yml) then:

1. Stops immediately, with a notice and a green job, if none of the Apple secrets are set. If some are set and some are missing, the job fails.
2. Writes the tag into `CFBundleShortVersionString` and `CFBundleVersion` for that build only. The copy of `Resources/Info.plist` in git is not updated. Local builds keep the versions checked in there. `MARKETING_VERSION` in the Xcode project is unused while `GENERATE_INFOPLIST_FILE` is off.
3. Imports the Developer ID certificate into a temporary keychain, builds the Release scheme with `scripts/build.sh`, and passes `--timestamp` plus `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`.
4. Runs `scripts/release-dmg.sh`. That script refuses an App Sandbox signature. It notarizes a zip of the app, staples the app, builds a UDZO disk image with an Applications shortcut, signs and notarizes the DMG, staples the DMG, and writes `SHA256SUMS`.
5. Creates or updates the GitHub Release for that tag and uploads `ScreenClip.dmg` and `SHA256SUMS`.

The asset name is always `ScreenClip.dmg`, so this URL tracks the newest tag:

`https://github.com/lludo/ScreenClip/releases/latest/download/ScreenClip.dmg`

The website uses that URL (`website/site.config.json`). Until the first tag exists, the link has no file. The page says so.

Check a download with `shasum -a 256 -c SHA256SUMS`.

A local notarization can still use `SCREENCLIP_SIGNING_IDENTITY` and a Keychain profile in `SCREENCLIP_NOTARY_PROFILE` via `scripts/package.sh`. CI uses the API key instead of a Keychain profile, because the runner has no long-lived login keychain. `notarytool` is required. `altool` notarization ended in 2023. Apple's current flow: [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

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

The formula points at the same `releases/latest/download/ScreenClip.dmg` asset. When you want a pinned cask, replace `:latest` and `:no_check` with the tag and the `SHA256SUMS` line.

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

### Which tip service

Use **GitHub Sponsors** and nothing else in the app until that page is live.

Figures below are from the vendors' pages as checked on November 14, 2026, for a small one-time tip. Card rates move. A $5 tip is the comparison point.

| Service | Fee on a personal $5 tip | Setup | Why it lost or won |
| --- | --- | --- | --- |
| [GitHub Sponsors](https://docs.github.com/en/sponsors/sponsoring-open-source-contributors/about-sponsorships-fees-and-taxes) | $0 from personal sponsors. Organization sponsors pay up to 6% (3% card processing and 3% GitHub; invoiced orgs can drop the card 3%) | Sponsors profile, payout, tax form. Approval can take days | Wins. Same account as the repo, `FUNDING.yml`, no platform fee for a person, one-time and monthly |
| [Ko-fi Free](https://help.ko-fi.com/hc/en-us/articles/360002506494-Does-Ko-fi-take-a-fee) | 0% platform fee on one-time tips, plus the processor (about 3% + $0.30), so about $4.55 back. Monthly tips are 5% even on Free | Minutes, once PayPal or Stripe is connected | Best backup if Sponsors approval lags a release. Add the link only after the page exists |
| [Stripe Payment Links](https://stripe.com/pricing) | No extra Payment Links fee. US domestic cards are 2.9% + $0.30 on standard pricing, about $4.55 before tax you remit | Stripe account review. You handle sales tax | Right tool for a priced product. Extra account for a tip |
| [Buy Me a Coffee](https://help.buymeacoffee.com/en/articles/8105744-how-to-calculate-charges-on-your-payment) | 5% platform, plus Stripe's 2.9% + $0.30, plus a 0.5% payout fee. About $4.28 before international card surcharges | Minutes | More expensive than Sponsors or Ko-fi for the same tip |
| [Lemon Squeezy](https://www.lemonsqueezy.com/pricing) | 5% + $0.50, about $4.25 on $5, before the international surcharge. They are the merchant of record and remit VAT | Account review | The $0.50 floor hurts a $3 tip. Worth it when selling a license internationally, not for a tip jar |

Gumroad, Paddle, and Setapp are distribution deals, not a tip button. Gumroad's direct fee is higher and they are a merchant of record. Paddle is the same shape. Setapp takes a revenue share and has to accept the app. None of them belong in the first release. The repo will be open source, so a $0.99 store price was already easy to route around by building from source. A tip matches that.

If Sponsors is not approved the week of the first tag, create a Ko-fi page on the Free plan and add that URL next to `DonationLinks.sponsors`. Do not add Lemon Squeezy or Stripe until there is a paid license to sell.
