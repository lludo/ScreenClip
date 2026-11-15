# Release and distribution

ScreenClip is not on the Mac App Store. The download, when a release exists, is a notarized DMG on GitHub Releases. The site's Download button points at that asset. Building from source does not need a release.

| Page | What it covers |
| --- | --- |
| [Direct distribution](direct-distribution.md) | Tag `vX.Y.Z`, the six Apple secrets, notarization, `ScreenClip.dmg`, `SHA256SUMS`, the tip window, and the Homebrew cask |
| [Mac App Store sandbox](app-store-sandbox.md) | Why a sandbox cannot ship this app: `/usr/bin/git` refuses to run, and Homebrew `git` and `gh` are not visible to a sandboxed child |
| [Secret-scan record](open-source-audit.md) | The history scan; the covered commit is named on that page |
| [Publishing checklist](../open-source.md) | The items that are not done: support email, Sponsors, and the release secrets |

The cask file in this repository is `packaging/homebrew/Casks/screenclip.rb`. It is a formula to copy into a personal tap. This repository does not publish the tap, and CI does not update it.

`scripts/release-dmg.sh` refuses to notarize an app whose signature contains `com.apple.security.app-sandbox`. No App Store configuration or scheme was added, so a Release build cannot pick up the sandbox by accident.
