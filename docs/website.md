# Website

Static pages for [screenclipai.com](https://screenclipai.com). The copy describes the Mac app as it works today: capture a region, annotate or redact it, hand it to Codex, Claude Code, or Grok Bot, then track the GitHub pull request through an optional merge and retest. Plain HTML and CSS, plus one small script for the language choice. No framework, no third-party fonts, and no analytics. The page follows the system light and dark setting, and the menu bar demo uses the matching screenshot.

`website/build.py` reads `website/site.config.json` and `website/src/`, then writes `website/dist/`. Python’s standard library is enough. `dist/` is generated and gitignored.

The support-email placeholder and the empty donate URL are tracked in [Open source](open-source.md#open-todos). This page describes how the site is built and deployed.

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

## Links

Edit `website/site.config.json`, then rebuild. Every value is either an absolute `https://` URL or an empty string.

| Key | Empty | Set |
| --- | --- | --- |
| `siteUrl` | No canonical URL, and `sitemap.xml` is omitted | Canonical URLs, Open Graph image URL, sitemap, and the sitemap line in `robots.txt` |
| `githubUrl` | “Source coming soon” | “View on GitHub”, the repository link, and the issues link on Support |
| `downloadUrl` | “Direct Mac download coming soon.” | Primary button: **Download for Mac (free)** |
| `donateUrl` | Link is omitted | **Support the project** |

Current values:

- `siteUrl` is `https://screenclipai.com`.
- `githubUrl` is `https://github.com/lludo/ScreenClip`.
- `downloadUrl` is `https://github.com/lludo/ScreenClip/releases/latest/download/ScreenClip.dmg`. The asset exists after a version tag is published. The page says so. ScreenClip is not on the Mac App Store.
- `donateUrl` is empty, so the site shows no tip link.

The structured data offer is `"price": "0"` and `"priceCurrency": "USD"`.

The support email on `/support` is the literal placeholder **TODO** in `website/src/pages/support.html`. It is copied into every locale. There is no monitored inbox yet.

## Languages

`website/locales/*.json` holds one string file per language. `website/i18n.py` is the list `build.py` uses. The same pages are written for each locale:

| Locale | Path |
| --- | --- |
| English (default) | `/`, `/privacy`, `/support` |
| Chinese Simplified | `/zh-hans/` |
| Spanish | `/es/` |
| Japanese | `/ja/` |
| Portuguese (Brazil) | `/pt-br/` |
| German | `/de/` |
| French | `/fr/` |
| Korean | `/ko/` |
| Russian | `/ru/` |
| Chinese Traditional | `/zh-hant/` |

`hero.title` is the whole headline. `[[this part]]` is the optional accent; the brackets are not shown. Replace that one key when the tagline changes. Product names, `Cmd` / `Shift` / `2`, setting labels, and `{code:…}` paths stay as written.

The footer lists every language as a normal link. Choosing one stores `screenclip_lang` in a cookie and in local storage.

### Browser locale detection

On `/` only, `website/middleware.js` (a Vercel function using `@vercel/functions`) reads `Accept-Language` when the `screenclip_lang` cookie is absent and redirects with **307** to the best match from `website/locale-match.js`. The matcher is case-insensitive. `zh-CN` and `zh` go to `/zh-hans`. `zh-TW`, `zh-HK`, and `zh-Hant` go to `/zh-hant`. `pt` and `pt-PT` go to `/pt-br`. English, and any tag with no match, stay at `/` with no redirect.

It does not redirect known crawlers (the list includes common bots and Lighthouse). It does not redirect any path except `/`, so a shared `/privacy` link stays put. The response sets `Vary: Accept-Language, Cookie` and `Cache-Control: private, no-store`.

The page script repeats the choice with `navigator.languages` when the edge redirect did not run. A footer link sets the cookie, so the next visit to `/` follows that choice even if `Accept-Language` differs.

Adding a language is part of [Localization](localization.md#adding-a-language). A new locale changes the home-page JSON-LD hashes. `python3 website/build.py` fails until `website/vercel.json` carries the new `script-src` hashes. The error prints the expected header.

## Screenshots

`website/scripts/screenshots.mjs` builds the site, serves it, and saves a full-page capture of home, privacy, and support for every locale, in light and dark, at 1440×900 and 390×844. The window size is the viewport. Each file is the whole page, so the hero is the top of the image. Output is gitignored:

```text
website/screenshots/<locale>/<theme>-<viewport>-<page>.png
website/screenshots/index.html
```

`theme` is `light` or `dark`. `viewport` is `desktop` or `mobile`. `page` is `home`, `privacy`, or `support`. The index is a contact sheet: each card shows the top of a capture and links to the full image.

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

Playwright is a dev dependency. Vercel installs with `npm install --omit=dev`, so deploys still only install `@vercel/functions`.

GitHub Actions can run the same script when someone starts it: **Website screenshots** is a manual `workflow_dispatch` job on `ubuntu-latest`. It uploads `website/screenshots` as an artifact. It does not run on push or on pull requests.

These shots are of the marketing site. App UI shots for the ten locales come from `scripts/render-localizations.sh`. See [Localization](localization.md#app-screenshots).

## Search and sharing

The build writes:

- One `h1` per page, a canonical URL per locale, and `hreflang` alternates including `x-default` (English at `/`).
- Open Graph and Twitter tags, including `og:locale`. The image is `website/src/assets/og.png` (1200×630), copied to `/assets/og.png`.
- `SoftwareApplication` JSON-LD (`operatingSystem` includes macOS, free offer, `downloadUrl`, `inLanguage`) and `FAQPage` JSON-LD on each home page.
- `robots.txt` and `sitemap.xml`. The sitemap lists `/`, `/privacy`, and `/support` in every locale, each with `xhtml:link` alternates. The sitemap is omitted when `siteUrl` is empty.
- `manifest.webmanifest`, `favicon.ico`, an SVG icon, a 32×32 PNG, and an Apple touch icon. The icons in `dist/` are drawn by `build.py`.
- `/privacy`, `/support`, and `404.html`. Localized privacy and support pages use the same paths under each locale prefix.

CSS and the synthetic menu bar screenshots (`popup-light.png`, `popup-dark.png`) are fingerprinted under `/assets/h/`. The home page picks the light or dark PNG with `prefers-color-scheme`. `website/vercel.json` gives those files a one-year immutable cache. HTML, `og.png`, and the stable icons stay revalidated. The older capture-editor and queue PNGs in `website/src/assets/` (`composer-preview.png`, `queue-preview.png`) are not part of the page.

On a Mac, `swift website/render-assets.swift` redraws `website/src/assets/og.png`.

`website/vercel.json` sends a Content-Security-Policy (script sources are `'self'` plus the hash of each locale’s home page JSON-LD), `X-Content-Type-Options`, `Referrer-Policy`, `Permissions-Policy`, and HSTS (`max-age=63072000; includeSubDomains; preload`). `build.py` fails if those hashes are not in that policy. The `preload` token does not by itself submit the domain to the HSTS preload list.

Unknown paths serve `dist/404.html` with status 404.

## Deploy on Vercel

The live project is **`screenclip-website`** (team `ludos-projects`), connected to `lludo/ScreenClip`. No tokens or secrets belong in the repo or in the build.

What is configured:

- **Root Directory** is `website`. The framework preset is **Other**. `website/vercel.json` sets the install command to `npm install --omit=dev`, the build command to `python3 build.py`, and the output directory to `dist`, with `cleanUrls` and `trailingSlash: false`. Vercel’s build image provides `python3`. `website/package.json` installs `@vercel/functions` for `middleware.js`.
- **Production** deploys automatically when `main` changes.
- **Preview** deploys are created for other branches. Those `*.vercel.app` hostnames are behind Vercel Authentication (`ssoProtection` is on for every deployment except the custom domains). A preview URL opens a Vercel login unless you are signed in to the team. `screenclipai.com` is not behind that login. Shooting a preview with `website/scripts/screenshots.mjs --url` needs a session that can pass that login; the production site and `python3 website/build.py --preview` do not.
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
