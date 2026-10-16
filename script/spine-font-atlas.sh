#!/usr/bin/env bash
# Regenerates Bookworms/SpineFontAtlas.lzfse from the Google Fonts catalog families.
# Usage: script/spine-font-atlas.sh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
xcrun swiftc -O -parse-as-library -o "$BUILD/spine-font-atlas" \
    "$ROOT_DIR/script/spine-font-atlas.swift" "$ROOT_DIR/Bookworms/Models/SpineFontCatalog.swift"
"$BUILD/spine-font-atlas" "$ROOT_DIR/Bookworms/SpineFontAtlas.lzfse"
