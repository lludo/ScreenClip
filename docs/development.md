# Development

Build and install for daily use are in [Getting started](getting-started.md). This page is the check, CI, and contributing loop.

## Build and test locally

From the repository root:

```sh
bash scripts/test.sh
python3 scripts/test_plugin.py
python3 scripts/test_review_queue.py
python3 scripts/test_external_assistant.py
python3 website/build.py
node website/test_locale.mjs
```

`bash scripts/test.sh` runs `python3 scripts/check_localizations.py` and then `swift test --disable-sandbox`. Extra arguments are passed through, for example `bash scripts/test.sh --filter SafetyTests`.

`bash scripts/build.sh debug` and `bash scripts/build.sh release` build the Xcode scheme without installing. Release builds enable the hardened runtime. Debug builds do not. Products land in `build/DerivedData/Build/Products/`.

`bash scripts/package.sh` creates `build/ScreenClip-macOS.zip` from the Release app. If `SCREENCLIP_NOTARY_PROFILE` is set, it also notarizes with that Keychain profile and requires `SCREENCLIP_SIGNING_IDENTITY`. Do not distribute that zip: the published download is the notarized DMG. The GitHub Release path does not use this script. It uses `scripts/release-dmg.sh`. See [Direct distribution](release/direct-distribution.md).

Other local tools:

| Command | What it does |
| --- | --- |
| `bash scripts/render-localizations.sh` | Writes locale screenshots under `build/localization-screenshots/`. See [Localization](localization.md). |
| `python3 scripts/review_queue.py` | Read-only queue summary. Never dispatches or edits. |
| `python3 scripts/probe_codex.py --codex /path/to/codex` | Read-only Codex handshake. Uses account quota. |
| `python3 scripts/send_test_webhook.py` | Sends the Grok Bot test payload using `SCREENCLIP_WEBHOOK_URL` and `SCREENCLIP_AUTHORIZATION`. |
| `bash scripts/sandbox-diagnostic.sh` | Builds a tiny sandboxed app and records whether `git` and `gh` can launch. CI runs this. |
| `ScreenClipProbe` (run with `swift run ScreenClipProbe`; not a SwiftPM product) | Manual Codex smoke test: two model turns, a synthetic image, a disposable repository. |

`scripts/create_integration_fixture.py` creates a private `OWNER/screenclip-integration-*` repository. `ScreenClip --integration-run` then performs real pull-request and merge operations in that fixture only. Do not point it at a repository you care about.

What those suites cover, and what they do not, is in [Validation](validation.md).

## CI

### macOS build and tests

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) runs on every push to `main` and on every pull request. The job is named `macos` and uses `macos-15`. Concurrency cancels an older run on the same ref. Permissions are `contents: read`.

The job runs, in order:

1. **Shell script syntax** — `bash -n` on every `scripts/*.sh`.
2. **App Sandbox diagnostic** — `bash scripts/sandbox-diagnostic.sh`. This is the check behind [why there is no Mac App Store build](release/app-store-sandbox.md).
3. **Native tests** — `bash scripts/test.sh` (catalog check, then `swift test`).
4. **Python tests** — `scripts/test_plugin.py`, `scripts/test_review_queue.py`, and `scripts/test_external_assistant.py`.
5. **Website build** — `python3 website/build.py`. This does not run Playwright or `website/test_locale.mjs`.
6. **Xcode Debug app build** — `bash scripts/build.sh debug`.
7. **Xcode Release app build** — `bash scripts/build.sh release`.
8. **Upload** the Release app as the artifact `ScreenClip-macOS`.

The upload is an unsigned CI product. It is not the notarized download.

### Website screenshots

[`.github/workflows/website-screenshots.yml`](../.github/workflows/website-screenshots.yml) is manual (`workflow_dispatch` only). It runs on `ubuntu-latest`, installs Playwright's Chromium, runs `node website/scripts/screenshots.mjs`, and uploads `website/screenshots`. It does not run on pull requests. The same command works locally. See [Website](website.md#screenshots).

### Release

A tag `vX.Y.Z` starts [`.github/workflows/release.yml`](../.github/workflows/release.yml) on `macos-15`. With none of the Apple secrets configured, that job exits green without publishing; a partial set fails its release gate. The full path is in [Direct distribution](release/direct-distribution.md). The secrets are listed under [Open TODOs](open-source.md#release-secrets).

## Contributing

The root [CONTRIBUTING.md](../CONTRIBUTING.md) is the short version of this workflow.

1. Branch from `main`. Use Xcode 16 or later on macOS 14 or later.
2. Copy `Config/LocalSigning.xcconfig.example` to `Config/LocalSigning.xcconfig` only if you will install the app. Ad-hoc signing is enough for `scripts/build.sh` and `scripts/test.sh`. Do not commit the local signing file. It is gitignored.
3. Run the local checks above before opening a pull request. The macOS workflow runs them again.
4. Interface copy goes through the String Catalogs. Follow [Localization](localization.md) when you add a string or a language, and commit the regenerated `.xcstrings` files.
5. Do not commit signing material, `.env` files, a `screenclip.sqlite` queue, `.screenclip/` evidence, or screenshots from a real queue. Localization and website screenshot output is gitignored (`build/` and `website/screenshots/`).
6. Open a pull request against `main`. CI cancels a superseded run on the same branch. Describe user-visible behavior and how you checked it.

The app is the only writer of a queue. Do not add a plugin tool that mutates reports. Grok Bot questions stay in Grok Bot's chat; the plugin is not installed there.

Website changes are covered by `python3 website/build.py`. A new locale also changes the Content-Security-Policy hashes in `website/vercel.json`. The build fails until those hashes match. Preview deploys of a pull request are created by the Vercel project `screenclip-website`, and those preview hostnames require a Vercel login. See [Website](website.md#deploy-on-vercel).
