#!/usr/bin/env bash
# Builds the app for a Simulator, installs it, and launches it.
# Usage: script/build_and_run.sh [--preview] [simulator-udid]
#   --preview  reads the private preview library loaded by script/load-preview-data.py
set -euo pipefail

PREVIEW=0
if [[ "${1:-}" == "--preview" ]]; then PREVIEW=1; shift; fi
BUNDLE_ID="gay.ian.Bookworms.iOS"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/DerivedData"
SIMULATOR="${1:-$(xcrun simctl list devices available | grep -m1 -E 'iPhone .*\(Booted\)' \
    | grep -oE '[0-9A-F-]{36}' || true)}"
if [[ -z "$SIMULATOR" ]]; then
    SIMULATOR="$(xcrun simctl list devices available 'iOS 27' | grep -m1 -oE '[0-9A-F-]{36}')"
    xcrun simctl boot "$SIMULATOR"
fi

cd "$ROOT_DIR"
xcodegen generate --spec project.yml --quiet
# Restricted development shells block Xcode's first-party Swift macro plugin sandbox.
xcodebuild -quiet -project Bookworms.xcodeproj -scheme Bookworms -configuration Debug \
    -destination "platform=iOS Simulator,id=$SIMULATOR" -derivedDataPath "$DERIVED_DATA" \
    OTHER_SWIFT_FLAGS='-disable-sandbox' build
xcrun simctl install "$SIMULATOR" "$DERIVED_DATA/Build/Products/Debug-iphonesimulator/Bookworms.app"
if [[ $PREVIEW == 1 ]]; then
    xcrun simctl launch "$SIMULATOR" "$BUNDLE_ID" -BookwormsPreviewFolder preview
else
    xcrun simctl launch "$SIMULATOR" "$BUNDLE_ID"
fi
