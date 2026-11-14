# Localization

ScreenClip's interface is English, plus Chinese (Simplified and Traditional), Spanish, Japanese, Brazilian Portuguese, German, French, Korean, and Russian. User-written report text, project names, agent replies, commands, and text sent to agents or pull requests stay exactly as stored.

## Catalogs

- `Sources/ScreenClip/Localizable.xcstrings` — menus, windows, settings, and activity lines the app itself writes.
- `Sources/ScreenClipCore/Localizable.xcstrings` — status names and agent-detection sentences. The core package looks these up with `Bundle.module`.
- `Resources/InfoPlist.xcstrings` — the Screen Recording and Automation permission prompts.

Product names stay untranslated: ScreenClip, Grok Bot, Claude Code, Codex, and GitHub. So do keyboard glyphs, the `screenclip/` branch prefix, and the `screenclip.external.v1.test` schema.

Counts such as “1 Open” and “19 To retest” use plural forms. Dates and numbers use the locale formatters already on the views (`Text(date, style:)` and `Text(count, format: .number)`).

## Screenshots

The checked-in queue is `Fixtures/ScreenshotData`. It is a reduced copy of a real Application Support snapshot: `screenclip.sqlite`, `assets/`, `originals/`, and `runs/`. Worktrees are not included. The snapshot still contains the owner's local paths, GitHub account, and project names (ScreenClip, Genealogy, and MemoVault), plus screenshots of those apps. See the pull request that added the fixture for the list. Rendering copies that folder to a temporary directory, rewrites only screenshot paths, and never opens `~/Library/Application Support/ScreenClip`.

Connection lines are fixed for the shots: Codex connected, Claude Code ready, Grok Bot not configured. The clock used for layout is 14 November 2026, 12:40 PM Pacific, and dates are formatted in `America/Los_Angeles`, which matches the capture times in the fixture.

```sh
bash scripts/render-localizations.sh
```

That runs:

```sh
SCREENCLIP_RENDER_LOCALIZATIONS=1 bash scripts/test.sh --filter LocalizationSnapshotTests
```

PNGs land in `build/localization-screenshots/`, which is gitignored, with one contact sheet. Each locale is rendered in light and dark for the main window, the selected report, the menu bar popover, Settings, and the Connect Grok Bot sheet.

You can also launch the app against the same temporary copy:

```sh
open /Applications/ScreenClip.app --args --screenshot-fixture --locale de
```

## Checks

```sh
python3 scripts/check_localizations.py
```

The script fails when a visible string has no translation, a translation is empty, a placeholder (`%@`, `%lld`, or a product token) differs from English, or the screenshot fixture grows past 10 MB. `bash scripts/test.sh` runs it before `swift test`. A pseudolocalization helper wraps a string as `⟦…⟧` with accented vowels so a missing-translation pass can see expansion without shipping a fake language.

Regenerate the catalogs after editing `scripts/l10n_part1.py`, `scripts/l10n_part2.py`, `scripts/l10n_part3.py`, or `scripts/l10n_formats.py`:

```sh
python3 scripts/build_string_catalogs.py
```
