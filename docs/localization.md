# Localization

The interface is English, plus Chinese (Simplified and Traditional), Spanish, Japanese, Brazilian Portuguese, German, French, Korean, and Russian. These ten languages are the Xcode `knownRegions` and the website locales.

User-written report text, project names, agent replies, commands, and text sent to agents or pull requests stay exactly as stored. `Chrome.stored` translates an English sentence only when that sentence is in the catalog. Anything else is returned unchanged.

Product names stay untranslated: ScreenClip, Grok Bot, Claude Code, Codex, and GitHub. So do keyboard glyphs, the `screenclip/` branch prefix, and the `screenclip.external.v1.test` schema.

Counts such as "1 Open" use plural forms. Dates and numbers use the formatters already on the views (`Text(date, style:)` and `Text(count, format: .number)`).

## String Catalogs

| Catalog | What it holds |
| --- | --- |
| `Sources/ScreenClip/Localizable.xcstrings` | Menus, windows, settings, and activity lines the app writes |
| `Sources/ScreenClipCore/Localizable.xcstrings` | Status names and agent-detection sentences. The core package looks these up with `Bundle.module` |
| `Resources/InfoPlist.xcstrings` | The Screen Recording and Automation permission prompts |

The catalogs are generated. Edit the Python sources, then regenerate. Do not hand-edit the `.xcstrings` files.

- `scripts/l10n_part1.py`, `scripts/l10n_part2.py`, and `scripts/l10n_part3.py` hold one row per plain string. Part 2 imports part 1, part 3 imports part 2, and `scripts/build_string_catalogs.py` imports part 3.
- `scripts/l10n_formats.py` holds format strings (`Chrome.format` / `localized:`) and the Info.plist usage strings, including plurals.

```sh
python3 scripts/build_string_catalogs.py
```

The generator exits with an error if a `chrome:` or `Chrome.text` key in `Sources/` has no row. It writes all three catalogs.

## Checks

```sh
python3 scripts/check_localizations.py
```

`bash scripts/test.sh` runs this before `swift test`, and the macOS CI job runs `scripts/test.sh`. The check fails when:

- a visible string is missing from the catalog
- a language is missing or a translation is empty
- a placeholder (`%@`, `%lld`, `%d`, and the other `printf` forms the script recognizes) differs from English
- a translation drops a product name, `screenclip/`, `screenclip.external.v1.test`, or `⌘` that the English string contains

`pseudolocalize()` in that script wraps a string as `⟦…⟧` and accents vowels (`Open queue` becomes a longer `⟦Ópéñ qúéúé⟧`-style string). The check calls it once on the fixed sample `"Open queue"` to confirm the helper still expands. It is not a language in the catalog, and the app has no pseudolocale switch. Missing translations are reported directly. The helper does not scan the catalogs.

## Adding a string

1. Put the English key in Swift with `Text(chrome:comment:)` or `Chrome.text`, and a `comment`. For a string with values, use `Chrome.format` (the key is a stable identifier such as `settings.parallel`, not the English sentence).
2. Add a plain string with `A("English", …)` in the `l10n_part*.py` file that already holds nearby keys. The nine arguments after English are zh-Hans, es, ja, pt-BR, de, fr, ko, ru, zh-Hant, in that order.
3. Add a format string in `FORMATS` with `S(...)` or a plural with `P(...)`. Set `bundle` to `"app"`, `"core"`, or `"both"`. Info.plist strings go in `INFO_PLIST`.
4. If the sentence is a core status that `CoreChrome` matches exactly, add it to the `exact` set in `Sources/ScreenClipCore/Localization.swift` as well. The core catalog only includes keys from that set plus format strings whose bundle is `core` or `both`.
5. Run `python3 scripts/build_string_catalogs.py` and `python3 scripts/check_localizations.py`.

Keep product names, `screenclip/`, and the test schema identical in every language.

## Adding a language

The language list is repeated. Update every copy, in this order: `en`, `zh-Hans`, `es`, `ja`, `pt-BR`, `de`, `fr`, `ko`, `ru`, `zh-Hant`.

1. Append the language to `LANGS` in `scripts/check_localizations.py`, `scripts/build_string_catalogs.py`, and `scripts/l10n_formats.py`. The same position has to be used in all three.
2. Add the argument to `A()` in `l10n_part1.py` and to every `A(...)` call in the three part files. Add it to `V()` and `S()` in `l10n_formats.py` and to every call, and teach `P()` the plural categories that language needs. Japanese, Korean, and both Chinese locales use `other` only. Russian uses `one`, `few`, `many`, and `other`.
3. Add the region to `knownRegions` in `ScreenClip.xcodeproj/project.pbxproj`.
4. Add the identifier to `locales` in `Tests/ScreenClipAppTests/LocalizationSnapshotTests.swift`.
5. For the website, add `website/locales/<id>.json` (copy `en.json` and translate), a row in `LOCALES` in `website/i18n.py`, and the tag in `website/locale-match.js` (`LOCALES` and `EXACT`). Path prefixes are lowercase (`zh-hans`, `pt-br`).
6. Regenerate the catalogs and run the check. Then `python3 website/build.py`. A new locale changes the home-page JSON-LD, so the Content-Security-Policy hashes in `website/vercel.json` no longer match. The build prints the expected header. Update `script-src` to that value and rebuild.
7. Run `node website/test_locale.mjs` after changing `locale-match.js`.

## App screenshots

There is no `Fixtures/` directory. The screenshot queue is built in code.

`ScreenshotFixture.materialize()` creates a fresh temporary directory and `PreviewSupport.seed` fills it with the synthetic **Demo storefront** project: three reports (working, needs you, merged), one annotated checkout image, and paused processing. No personal queue, screenshot, or local path is included. `ScreenshotFixture.configure` then pins the connection lines: Codex connected, Claude Code ready, Grok Bot not connected. Dates use `America/Los_Angeles` and a fixed instant (`timeIntervalSinceReferenceDate` 816381600).

```sh
bash scripts/render-localizations.sh
```

That is:

```sh
SCREENCLIP_RENDER_LOCALIZATIONS=1 bash scripts/test.sh --filter LocalizationSnapshotTests
```

`LocalizationSnapshotTests` skips unless that environment variable is `1`. PNGs land in `build/localization-screenshots/`, which is gitignored because `build/` is gitignored, plus one `contact-sheet.png`. Each of the ten locales is rendered in light and dark for five surfaces: the main window, the selected report, the menu bar popover, Settings, and the Connect Grok Bot sheet (100 images).

You can also launch the installed app against the same synthetic queue:

```sh
open /Applications/ScreenClip.app --args --screenshot-fixture --locale de
```

A different command, `ScreenClip --render-preview`, writes the marketing stills (composer, queue, menu) through `PreviewSupport.render`. That path is described in [Validation](validation.md#native-previews). It is not the locale matrix.

Website screenshots are a separate script. See [Website](website.md#screenshots).
