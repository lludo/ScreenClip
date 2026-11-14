# Open source

The repository is private. These are the items that are still open. Other pages describe how a feature works today and link here instead of keeping a second checklist.

Engineering work that is not a release blocker (live Claude and Grok Bot runs, multi-monitor capture, and the maintenance list) stays on the [roadmap](roadmap.md).

## Open TODOs

### Support email

`website/src/pages/support.html` shows the literal placeholder **TODO**. The built site, including [screenclipai.com/support](https://screenclipai.com/support), says no support inbox is set up. Replace that placeholder with a monitored address before publishing one. `website/site.config.json` has no email field; the text is in the page source.

### LICENSE

There is no `LICENSE` file. Choose one before making the repository public. This page does not pick it.

Two related files are also absent:

- A root `CONTRIBUTING.md`. The workflow people should follow is [Development → Contributing](development.md#contributing).
- A root `SECURITY.md`. It should say that queue screenshots stay on the Mac, that the Grok Bot webhook address and header live in the Keychain (`com.screenclip.app.external-assistant`), and where to report a vulnerability.

The agent icons under `Sources/ScreenClip/Assets.xcassets` are from Lobe Icons and already carry an MIT notice in `Sources/ScreenClip/AgentIcons-LICENSE.txt`. That notice covers those icons. It is not a license for the app.

The [secret-scan record](release/open-source-audit.md) covers history through `a1c72c6` (November 14, 2026). Every commit after that, including localization and the website locales, is outside that scan. Run the scan again before changing visibility.

### GitHub Sponsors and the donate URL

The in-app tip buttons and `.github/FUNDING.yml` (`github: lludo`) point at `https://github.com/sponsors/lludo`. That Sponsors profile is not set up to receive payments.

`website/site.config.json` has `"donateUrl": ""`, so the site omits **Support the project**. Set `donateUrl` to an `https://` URL and rebuild when a page should appear. If the destination is not GitHub Sponsors, change `DonationLinks.sponsors` in `Sources/ScreenClipCore/DonationPrompt.swift` in the same change. The tip window's timing is documented in the [user guide](user-guide.md#tip-window).

### Release secrets

The six Apple secrets named in [`.github/workflows/release.yml`](../.github/workflows/release.yml) are not configured:

| Secret | What it is |
| --- | --- |
| `APPLE_DEVELOPER_ID_P12_BASE64` | Base64 of the Developer ID Application `.p12` |
| `APPLE_DEVELOPER_ID_P12_PASSWORD` | Password for that `.p12` |
| `APPLE_SIGNING_IDENTITY` | The certificate's common name, for example `Developer ID Application: Name (TEAMID)` |
| `APPLE_NOTARY_KEY_P8_BASE64` | Base64 of the App Store Connect API `.p8` |
| `APPLE_NOTARY_KEY_ID` | The Key ID |
| `APPLE_NOTARY_ISSUER_ID` | The Issuer ID |

A tag push still starts the Release workflow. When none of the secrets are set, the job stops immediately, posts a notice, and finishes green. Nothing is signed or uploaded. If some secrets are set and others are missing, the job fails. How to create the certificate and the notarization key is in [Direct distribution](release/direct-distribution.md#what-the-tag-does).

## Before the repository is public

1. Add `LICENSE`.
2. Rescan history from `a1c72c6` forward. The earlier scan did not require a history rewrite.
3. Add root `CONTRIBUTING.md` and `SECURITY.md`, or accept that those files are still missing and that [Development](development.md#contributing) is the only contributing page.
4. Replace the support-email placeholder if the public site should list an address.
5. Decide whether the Sponsors link and `donateUrl` should go live with the first public download.

Publishing does not require the Apple secrets. Without them there is still no notarized DMG, so the site's download URL has no file. See [Direct distribution](release/direct-distribution.md).
