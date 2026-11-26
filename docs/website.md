# Website

Static pages for [screenclipai.com](https://screenclipai.com). The copy describes the Mac app as it works today: capture a region, annotate or redact it, hand it to Codex, Claude Code, or Grok Bot, then track the GitHub pull request through an optional merge and retest. The home page leads with the headline, the ⌘⇧2 keycaps, and the four-step **How it works** timeline (`loop.*` and `flow.*` strings: who does each step, with the agent's step highlighted) above the report queue. Type is the system font stack. Plain HTML and CSS, plus three small scripts: one for the language choice, one that keeps the demo caption in step with the video, and `analytics-events.js`, which counts clicks on the download link. No framework and no third-party fonts. Every page also loads Vercel Web Analytics from the site’s own origin (`/_vercel/insights/script.js`) to count visitors, page views, and download clicks without cookies. The page follows the system light and dark setting. Beside the headline, a short silent screen recording shows a capture going from selection to a tracked report.

`website/build.py` reads `website/site.config.json`, `website/src/`, and the committed SDK documentation in `website/sdk/`, then writes `website/dist/`. Python’s standard library is enough. `dist/` is generated and gitignored.

The site is configured for the current release: it links the GitHub repository and the latest release download. What must be true before this configuration reaches production, plus public support and the empty donate URL, is tracked in [Publishing checklist](release/publishing-checklist.md#open-todos). This page describes how the site is built and deployed.

## Build and preview

From the repository root:

```sh
python3 website/build.py
python3 website/build.py --preview
```

`--preview` serves `dist/` at `http://127.0.0.1:4173` with the same clean URLs as production (`/privacy`, not `/privacy.html`), a trailing-slash redirect, and `404.html` for unknown paths. Pass a port if 4173 is taken: `python3 website/build.py --preview 4180`.

A plain `python3 -m http.server` only exposes the files as they are named (`/privacy.html`).

Locale matching, without a browser:

```sh
node website/test_locale.mjs
```

CI runs `python3 website/build.py` only. It does not run the locale test or the screenshot script. See [Development](development.md#ci).

## iOS page and SDK documentation

`/ios` (and `/<locale>/ios`) is the iPhone and iPad page: what testers do, pairing, a three-step developer setup with code, and links into the SDK documentation. Its template is `website/src/pages/ios.html` and its copy is the `iosPage.*` strings. The header's **iPhone & iPad** link and the home page's iOS section point to it. Code samples on the page are not translated.

Its images live in `website/src/assets/ios/`:

- `composer.png`: the report sheet over the demo app, from `python3 scripts/sdk_screenshots.py`. The script runs `WebsiteScreenshotTests` in the demo's UI tests on an iPhone simulator, in light mode with a 9:41 status bar. It also writes the full-size copy that the documentation uses.
- `mac-pairing.png` (optional): ScreenClip **Settings › iOS** on the Mac, confirming a pairing code. It is supplied by the owner. The **Pair once** block shows it when the file exists and is text-only otherwise.

`/sdk` is the ScreenClipKit DocC site, at `/sdk/documentation/screenclipkit`. Vercel cannot run Swift, so `python3 scripts/build_sdk_docs.py` builds it on a Mac into `website/sdk/`, which is committed. `build.py` copies it to `dist/sdk/`. The script:

- builds the iOS Debug symbol graph, because the real API exists only there;
- converts `Sources/ScreenClipKit/ScreenClipKit.docc` for static hosting under `/sdk`, failing on any DocC warning;
- moves DocC's one inline script into `/sdk/base-url.js`, because the Content-Security-Policy allows no inline scripts. `build.py` refuses an `sdk/` with inline scripts.

Rerun the script after changing the SDK's public API, its doc comments, or the catalog, and commit `website/sdk/`. `vercel.json` redirects `/sdk` and `/sdk/documentation` to the landing page and caches DocC's hashed `/sdk/css` and `/sdk/js` files for a year. The DocC pages are English only and are not in the sitemap.

## Links

Edit `website/site.config.json`, then rebuild. Every value is either an absolute `https://` URL or an empty string.

| Key | Empty | Set |
| --- | --- | --- |
| `siteUrl` | No canonical URL, and `sitemap.xml` is omitted | Canonical URLs, Open Graph image URL, sitemap, and the sitemap line in `robots.txt` |
| `githubUrl` | Source is described as not public yet | “View on GitHub”, the repository link, and the issues link on Support |
| `downloadUrl` | “Mac download coming soon.” | Primary button: **Download for Mac** |
| `donateUrl` | Link is omitted | **Support the project** |

Current values:

- `siteUrl` is `https://screenclipai.com`.
- `githubUrl` is `https://github.com/lludo/ScreenClip`.
- `downloadUrl` is `https://github.com/lludo/ScreenClip/releases/latest/download/ScreenClip.dmg`, which tracks the newest published release. ScreenClip is not on the Mac App Store.
- `donateUrl` is empty, so the site shows no tip link.

The header **Download** button scrolls to the download section on every page, in every availability state. Production deploys from `main`.

The structured data includes a zero-price offer and the current version (`softwareVersion` in `build.py`) only when a download URL is configured. Each release updates that value and the version in the `download.title`, `download.noteReady` and `support.statusReady` strings of every locale (plus `iosPage.setupIntro` when the SDK needs a newer ScreenClip), then regenerates the CSP hashes in `vercel.json` (`python3 website/build.py` prints the expected header when they are stale). The site explains the noncommercial-use restriction.

There is no monitored support inbox yet. With `githubUrl` set, the support page sends people to GitHub issues; with it empty, the page says public support is not available rather than showing an unusable address.

## Languages

`website/locales/*.json` holds one string file per language. `website/i18n.py` is the list `build.py` uses. The same pages are written for each locale:

| Locale | Path |
| --- | --- |
| English (default) | `/`, `/ios`, `/privacy`, `/support` |
| Chinese Simplified | `/zh-hans/` |
| Spanish | `/es/` |
| Japanese | `/ja/` |
| Portuguese (Brazil) | `/pt-br/` |
| German | `/de/` |
| French | `/fr/` |
| Korean | `/ko/` |
| Russian | `/ru/` |
| Chinese Traditional | `/zh-hant/` |

`hero.title` is the tagline, “File bugs as you go, without breaking your flow.” Keep it. `build.py` breaks it after its first comma, and `styles.css` sizes it per language so each half stays on one line. Update the social preview image and its `meta.ogAlt` description when the headline changes. Product names, `Cmd` / `Shift` / `2`, setting labels, and `{code:…}` paths stay as written.

The footer lists every language as a normal link. Choosing one stores `screenclip_lang` in a cookie and in local storage.

### Browser locale detection

On `/` only, `website/middleware.js` (a Vercel function using `@vercel/functions`) reads `Accept-Language` when the `screenclip_lang` cookie is absent and redirects with **307** to the best match from `website/locale-match.js`. The matcher is case-insensitive. `zh-CN` and `zh` go to `/zh-hans`. `zh-TW`, `zh-HK`, and `zh-Hant` go to `/zh-hant`. `pt` and `pt-PT` go to `/pt-br`. English, and any tag with no match, stay at `/` with no redirect.

It does not redirect known crawlers (the list includes common bots and Lighthouse). It does not redirect any path except `/`, so a shared `/privacy` link stays put. The response sets `Vary: Accept-Language, Cookie` and `Cache-Control: private, no-store`.

The page script repeats the choice with `navigator.languages` when the edge redirect did not run. A footer link sets the cookie, so the next visit to `/` follows that choice even if `Accept-Language` differs.

Adding a language is part of [Localization](localization.md#adding-a-language). A new locale changes the home-page JSON-LD hashes. `python3 website/build.py` fails until `website/vercel.json` carries the new `script-src` hashes. The error prints the expected header.

## Screenshots

`website/scripts/screenshots.mjs` builds the site, serves it, and saves a full-page capture of home, iOS, privacy, and support for every locale, in light and dark, at 1440×900 and 390×844. The window size is the viewport. Each file is the whole page, so the hero is the top of the image. Output is gitignored:

```text
website/screenshots/<locale>/<theme>-<viewport>-<page>.png
website/screenshots/index.html
```

`theme` is `light` or `dark`. `viewport` is `desktop` or `mobile`. `page` is `home`, `ios`, `privacy`, or `support`. The index is a contact sheet: each card shows the top of a capture and links to the full image.

From the repository root, after installing the screenshot tool once:

```sh
cd website
npm install
npx playwright install chromium
cd ..
node website/scripts/screenshots.mjs
```

Pass a base URL to shoot a preview or production instead of building locally. The script sets the `screenclip_lang` cookie so a preview’s language redirect does not move the English home page.

```sh
node website/scripts/screenshots.mjs --url https://screenclipai.com
node website/scripts/screenshots.mjs --url http://127.0.0.1:4173
```

To use an existing Chromium-compatible browser, set `SCREENCLIP_CHROMIUM_PATH` to its executable when running the script.

Playwright is a dev dependency. Vercel installs with `npm install --omit=dev`, so deploys still only install `@vercel/functions`.

GitHub Actions can run the same script when someone starts it: **Website screenshots** is a manual `workflow_dispatch` job on `ubuntu-latest`. It uploads `website/screenshots` as an artifact. It does not run on push or on pull requests.

These shots are of the marketing site. App UI shots for the ten locales come from `scripts/render-localizations.sh`. See [Localization](localization.md#app-screenshots).

## Search and sharing

The build writes:

- One `h1` per page, a canonical URL per locale, and `hreflang` alternates including `x-default` (English at `/`).
- Open Graph and Twitter tags, including `og:locale`. The image is `website/src/assets/og.png` (1200×630), copied to `/assets/og.png`.
- `SoftwareApplication` JSON-LD (`operatingSystem` includes macOS and `inLanguage`; offer and `downloadUrl` appear when configured) and `FAQPage` JSON-LD on each home page.
- `robots.txt` and `sitemap.xml`. The sitemap lists `/`, `/ios`, `/privacy`, and `/support` in every locale, each with `xhtml:link` alternates. The sitemap is omitted when `siteUrl` is empty.
- `manifest.webmanifest`, `favicon.ico`, an SVG icon, a 32×32 PNG, and an Apple touch icon. The icons in `dist/` are drawn by `build.py`.
- `/privacy`, `/support`, and `404.html`. Localized privacy and support pages use the same paths under each locale prefix.

CSS, the hero demo video (`website/src/assets/demo.mp4`), and its poster frame (`demo-poster.jpg`) are fingerprinted under `/assets/h/`. The video is an owner-supplied screen recording, re-encoded as silent H.264 at 1280 by 888; its interface is in English on every locale, with a localized caption and description (`demo.*` strings). It autoplays muted and loops with no browser controls; clicking the video pauses and resumes it. To replace it, re-encode the new recording without audio, export its first frame as the poster, and update the `width` and `height` in `home.html` and the `aspect-ratio` in `styles.css` if the shape changes. The caption under the video follows playback: `website/src/demo.js` swaps in the step (`demo.step1` to `demo.step8`) whose `data-at` start time, in seconds, was most recently passed; the times live on the hidden step list in `home.html`. Without JavaScript the static `demo.caption` stays. A new recording needs new `data-at` times. Review the visible content before replacing or publishing it. `website/vercel.json` gives those files a one-year immutable cache. HTML, `og.png`, and the stable icons stay revalidated. The queue section also shows `report-queue-example.png`, a real screenshot supplied by the owner; its interface is in English, and visitors can open it at full size. The older capture-editor and queue PNGs in `website/src/assets/` (`composer-preview.png`, `queue-preview.png`) are not part of the page.

On a Mac, `swift website/render-assets.swift` redraws `website/src/assets/og.png`. Its availability line reads “Free download”; change it back if the download is ever withdrawn.

`website/vercel.json` sends a Content-Security-Policy (script sources are `'self'` plus the hash of each locale’s home page JSON-LD), `X-Content-Type-Options`, `Referrer-Policy`, `Permissions-Policy`, and HSTS (`max-age=63072000; includeSubDomains; preload`). `build.py` fails if those hashes are not in that policy. The `preload` token does not by itself submit the domain to the HSTS preload list.

Unknown paths serve `dist/404.html` with status 404.

## Deploy on Vercel

The live project is **`screenclip-website`** (team `ludos-projects`), connected to `lludo/ScreenClip`. No tokens or secrets belong in the repo or in the build.

What is configured:

- **Root Directory** is `website`. The framework preset is **Other**. `website/vercel.json` sets the install command to `npm install --omit=dev`, the build command to `python3 build.py`, and the output directory to `dist`, with `cleanUrls` and `trailingSlash: false`. Vercel’s build image provides `python3`. `website/package.json` installs `@vercel/functions` for `middleware.js`.
- **Production** deploys automatically when `main` changes.
- **Preview** deploys are created for other branches. Those `*.vercel.app` hostnames are behind Vercel Authentication (`ssoProtection` is on for every deployment except the custom domains). A preview URL opens a Vercel login unless you are signed in to the team. `screenclipai.com` is not behind that login. Shooting a preview with `website/scripts/screenshots.mjs --url` needs a session that can pass that login; the production site and `python3 website/build.py --preview` do not.
- **Web Analytics.** `build.py` puts `<script defer src="/_vercel/insights/script.js"></script>` in every page head. Vercel serves that path, and the event endpoint beside it, from the site’s own origin, so the Content-Security-Policy needs no change. It only records once **Web Analytics** is enabled for the project in the Vercel dashboard; until then, and in the local preview, the script is a harmless 404. The privacy page (`privacy.site1` and `privacy.site2`) says what it records. Keep the two in step.
- **Domains.** `screenclipai.com` is the production domain. `www.screenclipai.com` is attached and redirects to the apex with status **308**. `website/vercel.json` also redirects the `www` host to `https://screenclipai.com` (path and query). Both custom domains are verified.

A manual deploy from a linked checkout is `npx vercel deploy` inside `website/`, or `npx vercel deploy --prod` for production. The Git integration is the path that runs on push.

### DNS

DNS stays at Cloudflare. The nameservers are `tessa.ns.cloudflare.com` and `patrick.ns.cloudflare.com`. Do not switch them to Vercel. Do not proxy the Vercel records (grey cloud, DNS only). An orange-cloud proxy, especially with Flexible SSL, is a common cause of redirect loops and failed certificate checks.

Records observed on November 14, 2026. They are Vercel’s addresses for this project, returned directly (not Cloudflare proxy addresses):

| Type | Name | Value |
| --- | --- | --- |
| `A` | `@` | `216.150.1.1` |
| `A` | `@` | `216.150.16.1` |
| `CNAME` | `www` | `88d72ff9f6889dc5.vercel-dns-016.com` |

There is no `AAAA` record on the apex. `76.76.21.21` and `cname.vercel-dns.com` still appear in Vercel’s general docs. They are not the records this project uses. If the Vercel **Settings → Domains** page later shows different values, copy those. An address from another project can stay in “Invalid Configuration”.

Leave mail `MX` and verification `TXT` records alone. If Vercel asks for a `TXT` record at `_vercel`, add that too, DNS only.

Submit `https://screenclipai.com/sitemap.xml` to a search engine when you want it crawled. The sitemap is already being served with the site.
