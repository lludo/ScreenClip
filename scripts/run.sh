#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-debug}" in
    debug|Debug) configuration=Debug ;;
    release|Release) configuration=Release ;;
    *) printf '%s\n' 'Usage: bash scripts/run.sh [debug|release]' >&2; exit 2 ;;
esac
bash scripts/build.sh "$configuration"
bash scripts/install.sh "$PWD/build/DerivedData/Build/Products/$configuration/ScreenClip.app"
open /Applications/ScreenClip.app --args --show-queue
