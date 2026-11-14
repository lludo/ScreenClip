#!/bin/bash
# Render the menu bar, queue, report, settings, and Connect Grok Bot sheet
# for every supported locale in light and dark mode.
# Output: build/localization-screenshots/ (gitignored) plus a contact sheet.
set -euo pipefail
cd "$(dirname "$0")/.."
export SCREENCLIP_RENDER_LOCALIZATIONS=1
exec bash scripts/test.sh --filter LocalizationSnapshotTests
