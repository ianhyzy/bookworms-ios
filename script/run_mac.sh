#!/usr/bin/env bash
# Builds a signed, optimized Mac app that reads your real iCloud library, installs it in ~/Applications,
# and opens it.
# Usage: script/run_mac.sh [--preview]
#   --preview  reads the private preview library instead of iCloud
#
# Xcode's account is not needed: the app is signed with the team's Apple Development
# certificate and the existing "Mac Team Provisioning Profile: gay.ian.Bookworms.Mac", which
# grants the shared iCloud container and push. Until Apple assigns the managed Private Cloud
# Compute capability, no profile can include it, so this build signs with
# config/NoPCC-macOS.entitlements and compiles with NO_PCC: Apple's model reports itself
# unavailable, and a third-party model chosen in Settings designs spines. A development-signed
# build uses the CloudKit Development environment, as the other apps' development builds do.
set -euo pipefail

PREVIEW=0
if [[ "${1:-}" == "--preview" ]]; then PREVIEW=1; fi
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/DerivedData-mac"
INSTALLED="$HOME/Applications/Bookworms.app"

cd "$ROOT_DIR"
xcodegen generate --spec project.yml --quiet
# Restricted development shells block Xcode's first-party Swift macro plugin sandbox.
xcodebuild -quiet -project Bookworms.xcodeproj -scheme Bookworms -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED_DATA" \
    PRODUCT_BUNDLE_IDENTIFIER=gay.ian.Bookworms.Mac CODE_SIGNING_ALLOWED=NO \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS=NO_PCC OTHER_SWIFT_FLAGS='-disable-sandbox' build
APP="$DERIVED_DATA/Build/Products/Release/Bookworms.app"
# The profile is Xcode managed, which xcodebuild's manual signing refuses, so codesign signs
# the app with it directly. The entitlements add the identifiers the profile grants.
PROFILE="$(grep -l 'gay.ian.Bookworms.Mac' "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/"*.provisionprofile | head -1)"
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
ENTITLEMENTS="$DERIVED_DATA/Bookworms.entitlements"
cp config/NoPCC-macOS.entitlements "$ENTITLEMENTS"
/usr/libexec/PlistBuddy -c 'Add :com.apple.application-identifier string KSZ7QR8Y88.gay.ian.Bookworms.Mac' \
    -c 'Add :com.apple.developer.team-identifier string KSZ7QR8Y88' "$ENTITLEMENTS"
codesign --force --sign 'Apple Development' --entitlements "$ENTITLEMENTS" --timestamp=none "$APP"
pkill -x Bookworms 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$INSTALLED"
cp -R "$APP" "$INSTALLED"
if [[ $PREVIEW == 1 ]]; then
    # The sandboxed app reads the preview from its own container's Caches folder.
    CACHES="$HOME/Library/Containers/gay.ian.Bookworms.Mac/Data/Library/Caches/Bookworms"
    mkdir -p "$CACHES"
    cp -R "$ROOT_DIR/.local/preview" "$CACHES/"
    open "$INSTALLED" --args -BookwormsPreviewFolder preview
else
    open "$INSTALLED"
fi
