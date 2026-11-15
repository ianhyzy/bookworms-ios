#!/usr/bin/env bash
# Regenerates Bookworms/SpineFontAtlas.lzfse from the catalog families and every other Google
# Fonts family that passes the filter in script/spine-font-atlas.swift, then
# Bookworms/SpineFontTags.json for the families in the new atlas (script/spine-font-tags.py).
# Usage: script/spine-font-atlas.sh [report.tsv]
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
xcrun swiftc -O -parse-as-library -o "$BUILD/spine-font-atlas" \
    "$ROOT_DIR/script/spine-font-atlas.swift" "$ROOT_DIR/Bookworms/Models/SpineFontCatalog.swift"
"$BUILD/spine-font-atlas" "$ROOT_DIR/Bookworms/SpineFontAtlas.lzfse" "$@"
python3 "$ROOT_DIR/script/spine-font-tags.py"
