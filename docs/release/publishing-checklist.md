# Publishing checklist

ScreenClip is source-available under the [PolyForm Noncommercial License 1.0.0](../../LICENSE.md). It is free for noncommercial use. Commercial licensing is available on request. The required copyright notice is in that file.

The agent icons under `Sources/ScreenClip/Assets.xcassets` are from Lobe Icons and already carry an MIT notice in `Sources/ScreenClip/AgentIcons-LICENSE.txt`. That notice covers those icons. It is not a license for the app.

The [publication audit](publication-audit.md) records the November 15, 2026 history cleanup. The private fixture database and flagged image blobs were removed from rewritten history, and every branch except `main` was deleted. GitHub still retains private data through read-only pull-request refs until it purges them; the audit has the details.

The repository is public. Release progress is in [v1.0.0 readiness](v1.0.0-status.md). The other release pages are listed in [Release and distribution](README.md).

Engineering work that is not a release blocker (live Claude and Grok Bot runs, multi-monitor capture, and the maintenance list) stays on the [roadmap](../roadmap.md).

## Open TODOs

### Support email

The support page links to the repository's GitHub Issues. Add a monitored address if you want a channel besides Issues. `website/site.config.json` has no email field.

### GitHub Sponsors and the donate URL

The in-app tip buttons and `.github/FUNDING.yml` (`github: lludo`) point at `https://github.com/sponsors/lludo`. That Sponsors profile is not set up to receive payments.

`website/site.config.json` has `"donateUrl": ""`, so the site omits **Support the project**. Set `donateUrl` to an `https://` URL and rebuild when a page should appear. If the destination is not GitHub Sponsors, change `DonationLinks.sponsors` in `Sources/ScreenClipCore/DonationPrompt.swift` in the same change. The tip window's timing is documented in the [user guide](../user-guide.md#tip-window).

### Release secrets

Configure the six Apple secrets and `SPARKLE_ED_PRIVATE_KEY` named in [`.github/workflows/release.yml`](../../.github/workflows/release.yml) before relying on a tag to publish a notarized download. What each one is, and how the workflow behaves with none, some or all of them set, is in [Direct distribution](direct-distribution.md#maintainer-setup-one-time). With none configured, a tag push finishes green without signing or uploading anything; a partial set fails the release gate.

## Open items

1. Have GitHub purge the retained pull-request refs and cached private objects. Rewriting main again cannot remove GitHub-owned refs.
2. Root `CONTRIBUTING.md` and `SECURITY.md` exist. Add a support email to `SECURITY.md` if you want one besides GitHub private reporting.
3. Add a monitored support channel if the public site should list one.
4. Decide whether the Sponsors link and `donateUrl` should go live with the first public download.

Publishing does not require the Apple secrets. The first DMG is signed and notarized locally. The site's download URL already points at the latest release asset, and the v1.0.0 release is published; and each later release replaces it. See [Direct distribution](direct-distribution.md).
