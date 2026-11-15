#!/usr/bin/env bash
# Builds an optimized test build and installs it on a connected iPhone.
# Usage: script/install_on_device.sh [--no-pcc] [device-identifier], in either order
#   --no-pcc  builds the variant without Private Cloud Compute
#
# The build signs with Bookworms/Bookworms.entitlements, which includes the managed Private Cloud
# Compute entitlement, so Xcode's automatic signing needs Private Cloud Compute turned on for the
# App ID gay.ian.Bookworms.iOS and the team's account in Xcode > Settings > Accounts. A build
# that fails on either says what to do. With --no-pcc, the build signs with
# config/NoPCC.entitlements and compiles with NO_PCC, so the app never creates the Private Cloud
# Compute model: the provider chosen with Choose model in the Spines tab designs spines, else
# Apple's on-device model, else default styling. Everything else works against iCloud either way.
# A development-signed build uses the CloudKit Development environment.
set -euo pipefail

PCC=1
DEVICE_ARG=""
for arg in "$@"; do
    case "$arg" in
        --no-pcc) PCC=0 ;;
        *) DEVICE_ARG="$arg" ;;
    esac
done
BUNDLE_ID="gay.ian.Bookworms.iOS"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/DerivedData-device"
DEVICE="${DEVICE_ARG:-$(xcrun devicectl list devices 2>/dev/null \
    | awk '/iPhone/ && / physical/ && (/ available \(paired\)/ || / connected /) { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) { print $i; exit } }')}"
if [[ -z "$DEVICE" ]]; then
    echo "No paired iPhone found. Connect one and turn on Developer Mode." >&2
    exit 1
fi
if [[ $PCC == 1 ]]; then
    ENTITLEMENTS=Bookworms/Bookworms.entitlements
    CONDITIONS=""
else
    ENTITLEMENTS=config/NoPCC.entitlements
    CONDITIONS=NO_PCC
fi

cd "$ROOT_DIR"
xcodegen generate --spec project.yml --quiet
LOG="$(mktemp -t bookworms-install)"
trap 'rm -f "$LOG"' EXIT
# Restricted development shells block Xcode's first-party Swift macro plugin sandbox.
if ! xcodebuild -quiet -project Bookworms.xcodeproj -scheme Bookworms -configuration Release \
    -destination "id=$DEVICE" -derivedDataPath "$DERIVED_DATA" \
    -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    CODE_SIGN_ENTITLEMENTS="$ENTITLEMENTS" SWIFT_ACTIVE_COMPILATION_CONDITIONS="$CONDITIONS" \
    OTHER_SWIFT_FLAGS='-disable-sandbox' build 2>&1 | tee "$LOG"; then
    if grep -q 'No Account' "$LOG"; then
        echo "Xcode has no account to sign with. In Xcode > Settings > Accounts, add the Apple Account of team KSZ7QR8Y88, then run this script again." >&2
    elif [[ $PCC == 1 ]] && grep -q 'private-cloud-compute' "$LOG"; then
        echo "The provisioning profile lacks the Private Cloud Compute entitlement. In Certificates, Identifiers & Profiles (https://developer.apple.com/account/resources/identifiers/list), open the App ID $BUNDLE_ID, turn on Private Cloud Compute, and save. Then run this script again, and Xcode fetches a new profile. To install without Private Cloud Compute, run script/install_on_device.sh --no-pcc." >&2
    fi
    exit 1
fi
APP="$DERIVED_DATA/Build/Products/Release-iphoneos/Bookworms.app"
xcrun devicectl device install app --device "$DEVICE" "$APP"
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID"
