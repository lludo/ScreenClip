# ScreenClip website

Static pages for [screenclipai.com](https://screenclipai.com). The copy describes the Mac app as it works today: capture a region, annotate or redact it, hand it to Codex, Claude Code, or Grok Bot, then track the GitHub pull request through an optional merge and retest. Plain HTML and CSS, plus one small script for the language choice. No framework, no third-party fonts, and no analytics. The page follows the system light and dark setting, and the menu bar demo uses the matching screenshot.

`build.py` reads `site.config.json` and `src/`, then writes `dist/`. Python’s standard library is enough. `dist/` is generated and gitignored.

## Build and preview

From the repository root:

```sh
python3 website/build.py
python3 website/build.py --preview
```

`--preview` serves `dist/` at `http://127.0.0.1:4173` with the same clean URLs as production (`/privacy`, not `/privacy.html`), a trailing-slash redirect, and `404.html` for unknown paths. Pass a port if 4173 is taken: `python3 website/build.py --preview 4180`.

A plain `python3 -m http.server` only exposes the files as they are named (`/privacy.html`).

## Links

Edit `site.config.json`, then rebuild. Every value is either an absolute `https://` URL or an empty string.

| Key | Empty | Set |
| --- | --- | --- |
| `siteUrl` | No canonical URL, and `sitemap.xml` is omitted | Canonical URLs, Open Graph image URL, sitemap, and the sitemap line in `robots.txt` |
| `githubUrl` | “Source coming soon” | “View on GitHub”, the repository link, and the issues link on Support |
| `downloadUrl` | “Direct Mac download coming soon.” | Primary button: **Download for Mac (free)** |
| `donateUrl` | Link is omitted | **Support the project** |

`downloadUrl` is `https://github.com/lludo/ScreenClip/releases/latest/download/ScreenClip.dmg`, the notarized disk image attached to GitHub Releases. The asset exists after a version tag is published; the page says so. ScreenClip is not distributed on the Mac App Store. `donateUrl` stays empty until a donation profile is chosen, so the site shows no tip link. The structured data offer is `"price": "0"` and `"priceCurrency": "USD"`.

`githubUrl` is `https://github.com/lludo/ScreenClip`. The support email on `/support` is the literal placeholder **TODO** until a monitored inbox exists.

## Languages

`locales/*.json` holds one string file per language. `build.py` writes the same pages for each locale:

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

The footer lists every language as a normal link. Choosing one stores `screenclip_lang` in a cookie and in local storage. On `/`, `middleware.js` reads `Accept-Language` when that cookie is absent and redirects (307) to the best match. It does not redirect known crawlers, and it does not redirect any path except `/`. The page script repeats that choice with `navigator.languages` when the edge redirect did not run. English stays at `/`.

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
node website/scripts/screenshots.mjs --url https://your-preview.vercel.app
```

Playwright is a dev dependency. Vercel installs with `npm install --omit=dev`, so deploys still only install `@vercel/functions`.

GitHub Actions can run the same script when minutes are available: **Website screenshots** is a manual `workflow_dispatch` job on `ubuntu-latest`. It uploads `website/screenshots` as an artifact. The local command does not need Actions.

## Search and sharing

The build writes:

- One `h1` per page, a canonical URL per locale, and `hreflang` alternates including `x-default`.
- Open Graph and Twitter tags, including `og:locale`. The image is `src/assets/og.png` (1200×630), copied to `/assets/og.png`.
- `SoftwareApplication` JSON-LD (`operatingSystem` includes macOS, free offer, `downloadUrl`, `inLanguage`) and `FAQPage` JSON-LD on each home page.
- `robots.txt` and `sitemap.xml`. The sitemap lists `/`, `/privacy`, and `/support` in every locale, each with `xhtml:link` alternates.
- `manifest.webmanifest`, `favicon.ico`, an SVG icon, a 32×32 PNG, and an Apple touch icon.
- `/privacy`, `/support`, and `404.html`. Localized privacy and support pages use the same paths under each locale prefix.

CSS and the menu bar screenshots are fingerprinted under `/assets/h/`. Each screenshot is an AVIF, a WebP, and a PNG. The home page picks the light or dark set with `prefers-color-scheme`. `vercel.json` gives those files a one-year immutable cache. HTML, `og.png`, and the stable icons stay revalidated. The older capture-editor and queue PNGs in `src/assets/` are not part of the page.

On a Mac, `swift website/render-assets.swift` redraws `src/assets/og.png`. The icons in `dist/` are drawn by `build.py`.

## Deploy on Vercel

Do this from the GitHub repository. No tokens or secrets belong in the repo or in the build.

1. In Vercel, import `https://github.com/lludo/ScreenClip`.
2. Set **Root Directory** to `website`. Framework preset: **Other**. `website/vercel.json` sets the build command to `python3 build.py` and the output directory to `dist`, with `cleanUrls` and `trailingSlash: false`. Vercel’s build image provides `python3`. `package.json` only installs `@vercel/functions` for the locale redirect in `middleware.js`.
3. Deploy with Vercel’s Git integration (or `npx vercel deploy` from `website/` once the project is linked). Production deploy is `npx vercel deploy --prod` from that directory.
4. In the project’s **Settings → Domains**, add `screenclipai.com`. When Vercel offers `www.screenclipai.com`, add it and set it to **redirect to `screenclipai.com`**. `vercel.json` also redirects `www.screenclipai.com` to the apex (path and, by Vercel’s redirect default, query string) if both hostnames are attached to the deployment.
5. Keep DNS at Cloudflare. Do not switch the domain’s nameservers to Vercel, and do not proxy these records (grey cloud, DNS only). After the domains are added, copy the records from **Settings → Domains**. Vercel’s current docs ([apex and www records](https://vercel.com/docs/domains/troubleshooting)) say the values are per project:

   | Type | Name | Value |
   | --- | --- | --- |
   | `A` | `@` | The A record shown for the apex. Many projects still show `76.76.21.21`. Newer projects often show a different anycast address, such as `216.198.79.1`. |
   | `CNAME` | `www` | The CNAME target shown for `www`, a name like `<id>.vercel-dns-017.com`. |

   `76.76.21.21` and the older shared target `cname.vercel-dns.com` still come up in Vercel’s docs and still resolve for many projects. They are not guaranteed for a new project. If the dashboard shows a different A record or a project-specific CNAME, use that. An address copied from another project can stay in “DNS Change Recommended” or “Invalid Configuration”. Remove other `A` or `AAAA` records on the apex before adding the new one. Leave mail `MX` and verification `TXT` records alone. If Vercel asks for a `TXT` record at `_vercel`, add that too, DNS only.

6. Turn Cloudflare’s proxy **off** for both records. Vercel’s docs say to use DNS only when the DNS host is Cloudflare. An orange-cloud proxy, especially with Flexible SSL, is a common cause of redirect loops and failed certificate checks.

`vercel.json` sends a Content-Security-Policy (script sources are `'self'` plus the hash of each locale’s home page JSON-LD), `X-Content-Type-Options`, `Referrer-Policy`, `Permissions-Policy`, and HSTS (`max-age=63072000; includeSubDomains; preload`). `build.py` fails if those hashes are not in that policy. The `preload` token does not by itself submit the domain to the HSTS preload list.

Unknown paths serve `dist/404.html` with status 404. Submit `https://screenclipai.com/sitemap.xml` to a search engine after the domain is serving the site.
