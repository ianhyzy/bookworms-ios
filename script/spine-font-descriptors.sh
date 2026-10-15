#!/usr/bin/env bash
# Regenerates Bookworms/SpineFontDescriptors.json from the Google Fonts catalog families.
# Usage: script/spine-font-descriptors.sh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
xcrun swiftc -O -parse-as-library -o "$BUILD/spine-font-descriptors" \
    "$ROOT_DIR/script/spine-font-descriptors.swift" \
    "$ROOT_DIR/Bookworms/Services/TitleLettering.swift" \
    "$ROOT_DIR/Bookworms/Models/SpineFontCatalog.swift" \
    "$ROOT_DIR/Bookworms/Support/ColorValue.swift" \
    "$ROOT_DIR/Bookworms/Support/SpineContrast.swift"
"$BUILD/spine-font-descriptors" "$ROOT_DIR/Bookworms/SpineFontDescriptors.json"
