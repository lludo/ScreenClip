# Publishing checklist

ScreenClip is source-available under the [PolyForm Noncommercial License 1.0.0](../LICENSE.md). It is free for noncommercial use. Commercial licensing is available on request. The required copyright notice is in that file.

The agent icons under `Sources/ScreenClip/Assets.xcassets` are from Lobe Icons and already carry an MIT notice in `Sources/ScreenClip/AgentIcons-LICENSE.txt`. That notice covers those icons. It is not a license for the app.

The [secret-scan record](release/open-source-audit.md) was repeated on November 14, 2026 through `e32f81b`. Branch tips are synthetic. Pull-request refs 24, 25, 26, 28, 29, and 30 still point at the pre-rewrite commits, and the tip of pull request 25 still contains the real queue snapshot. Replace or purge that history before changing visibility.

The repository is private. These are the items that are still open. Other pages describe how a feature works today and link here instead of keeping a second checklist.

Engineering work that is not a release blocker (live Claude and Grok Bot runs, multi-monitor capture, and the maintenance list) stays on the [roadmap](roadmap.md).

## Open TODOs

### Support email

The support page says public support is not available yet. Add a monitored address or another support channel before advertising one. `website/site.config.json` has no email field.

### GitHub Sponsors and the donate URL

The in-app tip buttons and `.github/FUNDING.yml` (`github: lludo`) point at `https://github.com/sponsors/lludo`. That Sponsors profile is not set up to receive payments.

`website/site.config.json` has `"donateUrl": ""`, so the site omits **Support the project**. Set `donateUrl` to an `https://` URL and rebuild when a page should appear. If the destination is not GitHub Sponsors, change `DonationLinks.sponsors` in `Sources/ScreenClipCore/DonationPrompt.swift` in the same change. The tip window's timing is documented in the [user guide](user-guide.md#tip-window).

### Release secrets

Configure the six Apple secrets named in [`.github/workflows/release.yml`](../.github/workflows/release.yml) before relying on a tag to publish a notarized download. What each one is, and how the workflow behaves with none, some or all of them set, is in [Direct distribution](release/direct-distribution.md#maintainer-setup-one-time). With none configured, a tag push finishes green without signing or uploading anything; a partial set fails the release gate.

## Before the repository is public

1. Publish from a new repository or a single new commit, and have GitHub purge the pre-rewrite pull-request refs. The branch rewrite did not remove them. The path list is in the [open-source audit](release/open-source-audit.md#what-to-do-before-the-repository-is-public).
2. Root `CONTRIBUTING.md` and `SECURITY.md` exist. Add a support email to `SECURITY.md` if you want one besides GitHub private reporting.
3. Add a monitored support channel if the public site should list one.
4. Decide whether the Sponsors link and `donateUrl` should go live with the first public download.

Publishing does not require the Apple secrets. Without them there is still no notarized DMG, so the site leaves its download URL empty. See [Direct distribution](release/direct-distribution.md).
