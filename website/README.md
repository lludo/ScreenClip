# ScreenClip landing page

A small, responsive, one-page site. Lead message: **capture feedback as you notice it, then keep going**. Notes, screenshots, and context stay together; agent follow-up (Codex or Claude Code) is a secondary benefit. The product reasoning is in [the product specification](../docs/product-spec.md#problem-and-intended-outcome).

The site uses plain HTML, CSS, and a small script for the accessible screenshot tabs. It has no package dependencies, third-party fonts, trackers, or remote assets. The app screenshots are real demo previews; the hero is labeled as an illustration.

## Build and preview

From the repository root:

```sh
python3 website/build.py
python3 -m http.server 4173 --bind 127.0.0.1 --directory website/dist
```

Open `http://127.0.0.1:4173`. Publish the **contents of `website/dist/`** to any static host. Python 3 is only needed to build; the hosted page needs no server runtime. `dist/` is generated and ignored by Git.

## Release links and domain

Edit `site.config.json`, then rebuild:

```json
{
  "siteUrl": "",
  "appStoreUrl": "",
  "downloadUrl": ""
}
```

All three values are intentionally empty today. Empty download URLs render as non-clickable **Coming soon** options. Adding a real HTTPS URL enables that download and updates the availability copy. Configure each channel only once it is actually available; no App Store acceptance, pricing, or public release is implied by a placeholder.

Set `siteUrl` to the final HTTPS site address, including a subdirectory if applicable. The build then adds the canonical URL, absolute social-image URL, Open Graph URL, app URL, `sitemap.xml`, and sitemap reference in `robots.txt`. No domain is invented while it is unset.

## Search and sharing

- Static, indexable HTML with one H1, descriptive headings, visible product copy, and semantic landmarks.
- A concise title and description focused on screenshot feedback for Mac.
- Open Graph and Twitter cards with a checked-in 1200 × 630 PNG.
- `SoftwareApplication` JSON-LD with verified capabilities and requirements; no invented price, reviews, or ratings.
- SVG favicon, touch icon, image dimensions, lazy-loaded app screenshots, and responsive layouts.
- Keyboard-operated tabs, visible focus, skip link, reduced-motion support, native FAQ disclosure controls, and descriptive image alt text.

Before public launch, set the real domain and release links, build again, and upload `dist/`. Submit the generated sitemap to the search engines you use after the domain is live. Metadata supports discovery; ranking depends on public indexing and other factors beyond the page.

The generated images can optionally be refreshed on a Mac with `swift website/render-assets.swift`. This is not required to build or host the site.
