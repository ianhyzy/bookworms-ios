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
# The app targets iOS 27, so only iOS 27 iPhones qualify; a booted one wins. Otherwise the
# script takes an iPhone on the newest iOS 27 runtime, which simctl lists last, since iPhone
# owners update quickly. The iPhone Duo runs on runtime builds of its own, so it isn't taken.
SIMULATOR="${1:-$(xcrun simctl list devices available 'iOS 27' | grep -m1 -E 'iPhone .*\(Booted\)' \
    | grep -oE '[0-9A-F-]{36}' || true)}"
if [[ -z "$SIMULATOR" ]]; then
    SIMULATOR="$(xcrun simctl list devices available 'iOS 27' | grep -E 'iPhone ' | grep -v 'iPhone Duo' \
        | tail -1 | grep -oE '[0-9A-F-]{36}' || true)"
    if [[ -z "$SIMULATOR" ]]; then
        echo "No iOS 27 iPhone Simulator found. Create one in Xcode or pass its UDID." >&2
        exit 1
    fi
    # Boots the Simulator slim, a setting that lasts until `simslim off`. The app uses
    # CloudKit, on-device models, and the Photos library, so those categories stay on. If
    # slimming fails, `simslim off` boots the Simulator stock.
    if command -v simslim >/dev/null; then
        simslim on "$SIMULATOR" --except icloud,siri,photos || simslim off "$SIMULATOR"
    else
        xcrun simctl boot "$SIMULATOR"
    fi
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
