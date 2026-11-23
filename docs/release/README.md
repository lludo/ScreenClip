# Release and distribution

ScreenClip is not on the Mac App Store. The download, when a release exists, is a notarized DMG on GitHub Releases. The site's Download button points at that asset. Building from source does not need a release.

| Page | What it covers |
| --- | --- |
| [v1.0.4 release notes](v1.0.4.md) | Popover lists the reports behind each count, newest-first queue, review fixes |
| [v1.0.3 release notes](v1.0.3.md) | Automatic updates, instant pull request previews, and fixes |
| [v1.0.2 release notes](v1.0.2.md) | Text notes, merging from the report, and fixes |
| [v1.0.1 release notes](v1.0.1.md) | Fixes and improvements since 1.0.0 |
| [v1.0.0 release notes](v1.0.0.md) | Features, installation, requirements, privacy, and limits. The release workflow publishes `docs/release/<tag>.md` as the GitHub Release notes, so each release needs a file named after its tag |
| [v1.0.0 readiness](v1.0.0-status.md) | Current validation and the remaining notarization and publication steps |
| [Direct distribution](direct-distribution.md) | Tag `vX.Y.Z`, the Apple and Sparkle secrets, notarization, `ScreenClip.dmg`, `SHA256SUMS`, `appcast.xml` and automatic updates, the tip window, and the Homebrew cask |
| [Mac App Store sandbox](app-store-sandbox.md) | Why a sandbox cannot ship this app: `/usr/bin/git` refuses to run, and Homebrew `git` and `gh` are not visible to a sandboxed child |
| [Publishing checklist](publishing-checklist.md) | The items that are not done: support channel, Sponsors, and the release secrets |
| [Publication audit](publication-audit.md) | The history cleanup, and the pull-request refs GitHub still has to purge before the repository is public |

The cask file in this repository is `packaging/homebrew/Casks/screenclip.rb`. It is a formula to copy into a personal tap. This repository does not publish the tap, and CI does not update it.

`scripts/release-dmg.sh` refuses to notarize an app whose signature contains `com.apple.security.app-sandbox`. No App Store configuration or scheme was added, so a Release build cannot pick up the sandbox by accident.
