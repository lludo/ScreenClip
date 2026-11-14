#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/check_localizations.py
mkdir -p .build/ModuleCache .build/cache .build/config .build/security
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFT_MODULECACHE_PATH="$PWD/.build/ModuleCache"
swift test --disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security" "$@"
