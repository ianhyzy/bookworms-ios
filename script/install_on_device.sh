#!/usr/bin/env bash
# Builds an optimized test build and installs it on a connected iPhone.
# Usage: script/install_on_device.sh [device-identifier]
#
# Until Apple assigns the managed Private Cloud Compute entitlement to the team, a provisioning
# profile cannot include it. This build signs with config/NoPCC.entitlements and compiles with
# NO_PCC, so the app never creates the Private Cloud Compute model: the backup model chosen with
# Choose Backup Model in the Spines tab designs spines, else Apple's on-device model, else local
# defaults, and everything else works against iCloud. A development-signed build uses the CloudKit Development environment.
set -euo pipefail

BUNDLE_ID="gay.ian.Bookworms.iOS"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/DerivedData-device"
DEVICE="${1:-$(xcrun devicectl list devices 2>/dev/null \
    | awk '/iPhone/ && / physical/ && (/ available \(paired\)/ || / connected /) { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) { print $i; exit } }')}"
if [[ -z "$DEVICE" ]]; then
    echo "No paired iPhone found. Connect one and turn on Developer Mode." >&2
    exit 1
fi

cd "$ROOT_DIR"
xcodegen generate --spec project.yml --quiet
# Restricted development shells block Xcode's first-party Swift macro plugin sandbox.
xcodebuild -quiet -project Bookworms.xcodeproj -scheme Bookworms -configuration Release \
    -destination "id=$DEVICE" -derivedDataPath "$DERIVED_DATA" \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    CODE_SIGN_ENTITLEMENTS=config/NoPCC.entitlements SWIFT_ACTIVE_COMPILATION_CONDITIONS=NO_PCC \
    OTHER_SWIFT_FLAGS='-disable-sandbox' build
APP="$DERIVED_DATA/Build/Products/Release-iphoneos/Bookworms.app"
xcrun devicectl device install app --device "$DEVICE" "$APP"
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID"
