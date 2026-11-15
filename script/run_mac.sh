#!/usr/bin/env bash
# Builds a signed, optimized Mac app that reads your real iCloud library, installs it in ~/Applications,
# and opens it.
# Usage: script/run_mac.sh [--preview] [--no-pcc] [--spine-batch books.json [--batch-tier tier]]
#   --preview  reads the private preview library instead of iCloud
#   --no-pcc   builds the variant without Private Cloud Compute
#   --spine-batch books.json  compiles SPINE_BATCH and designs the CloudBook records in
#              books.json in memory (`SpineBatch`), in a preview launch with --batch-tier's
#              tier (pcc, backup, onDevice, or local; default: the best available). The batch
#              build runs from .local/spine-batch/Bookworms-batch.app, so the installed app
#              stays as it is. The script waits for the batch to quit, copies its output to
#              .local/spine-batch/, and deletes the batch build.
#
# Xcode's account is not needed: the app is signed with the team's Apple Development
# certificate and the newest cached Xcode-managed "Mac Team Provisioning Profile:
# gay.ian.Bookworms.Mac", which grants the shared iCloud container and push. The build signs
# with Bookworms/Bookworms-macOS.entitlements, which includes the managed Private Cloud Compute
# entitlement, so the profile must grant it too; the script checks before it builds and stops
# with what to do when the profile doesn't. With --no-pcc, the build signs with
# config/NoPCC-macOS.entitlements and compiles with NO_PCC: the provider chosen in Settings >
# Design Model designs spines, else Apple's on-device model, else default styling. A
# development-signed build uses the CloudKit Development environment, as the other apps'
# development builds do.
set -euo pipefail

PREVIEW=0
PCC=1
BATCH=""
BATCH_TIER=""
USAGE="Usage: script/run_mac.sh [--preview] [--no-pcc] [--spine-batch books.json [--batch-tier tier]]"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --preview) PREVIEW=1 ;;
        --no-pcc) PCC=0 ;;
        --spine-batch)
            # Checked before the build, which takes minutes, rather than at the batch's first use.
            if [[ ! -f "${2-}" ]]; then
                echo "--spine-batch needs an existing books.json file. $USAGE" >&2
                exit 2
            fi
            BATCH="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; PREVIEW=1; shift ;;
        --batch-tier)
            case "${2-}" in pcc | backup | onDevice | local) ;; *) echo "$USAGE" >&2; exit 2 ;; esac
            BATCH_TIER="$2"; shift ;;
        *)
            echo "$USAGE" >&2
            exit 2
            ;;
    esac
    shift
done
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT_DIR/DerivedData-mac"
INSTALLED="$HOME/Applications/Bookworms.app"
PROFILES="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
if [[ $PCC == 1 ]]; then
    ENTITLEMENTS_SOURCE=Bookworms/Bookworms-macOS.entitlements
    CONDITIONS=""
else
    ENTITLEMENTS_SOURCE=config/NoPCC-macOS.entitlements
    CONDITIONS=NO_PCC
fi
if [[ -n "$BATCH" ]]; then
    CONDITIONS="$CONDITIONS SPINE_BATCH"
fi

# The profile is Xcode managed, which xcodebuild's manual signing refuses, so codesign signs
# the app with it after the build. A refreshed profile is a new file, so the newest one wins.
PROFILE=""
while IFS= read -r candidate; do
    if grep -q 'gay.ian.Bookworms.Mac' "$candidate"; then
        PROFILE="$candidate"
        break
    fi
done < <(ls -t "$PROFILES"/*.provisionprofile 2>/dev/null)
if [[ -z "$PROFILE" ]]; then
    echo "No cached provisioning profile for gay.ian.Bookworms.Mac. With the team's account in Xcode > Settings > Accounts, run: xcodebuild -project Bookworms.xcodeproj -scheme Bookworms -destination 'platform=macOS,arch=arm64' -allowProvisioningUpdates PRODUCT_BUNDLE_IDENTIFIER=gay.ian.Bookworms.Mac build" >&2
    exit 1
fi
# Decoded into a variable, not piped: grep -q closing the pipe early would fail it under pipefail.
if [[ $PCC == 1 ]] && [[ "$(security cms -D -i "$PROFILE" 2>/dev/null)" \
    != *'<key>com.apple.developer.private-cloud-compute</key>'* ]]; then
    echo "The provisioning profile for gay.ian.Bookworms.Mac lacks the Private Cloud Compute entitlement. In Certificates, Identifiers & Profiles (https://developer.apple.com/account/resources/identifiers/list), open the App ID gay.ian.Bookworms.Mac, turn on Private Cloud Compute, and save. Then let Xcode refresh the profile, which needs the team's account in Xcode > Settings > Accounts: xcodebuild -project Bookworms.xcodeproj -scheme Bookworms -destination 'platform=macOS,arch=arm64' -allowProvisioningUpdates PRODUCT_BUNDLE_IDENTIFIER=gay.ian.Bookworms.Mac build. To build without Private Cloud Compute, run script/run_mac.sh --no-pcc." >&2
    exit 1
fi

cd "$ROOT_DIR"
xcodegen generate --spec project.yml --quiet
# Restricted development shells block Xcode's first-party Swift macro plugin sandbox.
xcodebuild -quiet -project Bookworms.xcodeproj -scheme Bookworms -configuration Release \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED_DATA" \
    PRODUCT_BUNDLE_IDENTIFIER=gay.ian.Bookworms.Mac CODE_SIGNING_ALLOWED=NO \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS="$CONDITIONS" OTHER_SWIFT_FLAGS='-disable-sandbox' build
APP="$DERIVED_DATA/Build/Products/Release/Bookworms.app"
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
# The entitlements add the identifiers the profile grants.
ENTITLEMENTS="$DERIVED_DATA/Bookworms.entitlements"
cp "$ENTITLEMENTS_SOURCE" "$ENTITLEMENTS"
/usr/libexec/PlistBuddy -c 'Add :com.apple.application-identifier string KSZ7QR8Y88.gay.ian.Bookworms.Mac' \
    -c 'Add :com.apple.developer.team-identifier string KSZ7QR8Y88' "$ENTITLEMENTS"
codesign --force --sign 'Apple Development' --entitlements "$ENTITLEMENTS" --timestamp=none "$APP"
# Quits only the installed Mac app, not a Simulator copy that has the same process name.
quit_installed() { pkill -f "^$INSTALLED/Contents/MacOS/Bookworms" 2>/dev/null || true; }
if [[ -n "$BATCH" ]]; then
    # The bundle ID, team, and entitlements, not the location, give the batch build the app's
    # container, Keychain items, and Private Cloud Compute, so it runs beside the installed app.
    TARGET="$ROOT_DIR/.local/spine-batch/Bookworms-batch.app"
    mkdir -p "$(dirname "$TARGET")"
else
    TARGET="$INSTALLED"
    quit_installed
    mkdir -p "$HOME/Applications"
fi
rm -rf "$TARGET"
cp -R "$APP" "$TARGET"
if [[ $PREVIEW == 1 ]]; then
    # The sandboxed app reads the preview from its own container's Caches folder.
    CACHES="$HOME/Library/Containers/gay.ian.Bookworms.Mac/Data/Library/Caches/Bookworms"
    mkdir -p "$CACHES"
    # A batch needs a preview launch but not the private library, so it can start from an
    # empty preview folder.
    if [[ -z "$BATCH" || -d "$ROOT_DIR/.local/preview" ]]; then
        cp -R "$ROOT_DIR/.local/preview" "$CACHES/"
    else
        mkdir -p "$CACHES/preview"
    fi
    if [[ -n "$BATCH" ]]; then
        cp "$BATCH" "$CACHES/spine-batch-books.json"
        BEFORE="$(ls "$CACHES/spine-batch" 2>/dev/null || true)"
        TIER_ARGS=()
        if [[ -n "$BATCH_TIER" ]]; then TIER_ARGS=(-BookwormsSpineBatchTier "$BATCH_TIER"); fi
        # -n starts this copy even while the installed app runs; -W waits until the batch quits.
        open -n -W "$TARGET" --args -BookwormsPreviewFolder preview \
            -BookwormsSpineBatch spine-batch-books.json ${TIER_ARGS[@]+"${TIER_ARGS[@]}"}
        WROTE=0
        for run in $(ls "$CACHES/spine-batch" 2>/dev/null); do
            if ! grep -qx "$run" <<<"$BEFORE"; then
                mkdir -p "$ROOT_DIR/.local/spine-batch"
                cp -R "$CACHES/spine-batch/$run" "$ROOT_DIR/.local/spine-batch/"
                echo "Spine batch output: $ROOT_DIR/.local/spine-batch/$run"
                if [[ -f "$CACHES/spine-batch/$run/results.json" ]]; then WROTE=1; fi
            fi
        done
        rm -rf "$TARGET"
        if [[ $WROTE == 0 ]]; then
            echo "The spine batch wrote no results; see the app's spine-batch log in Console." >&2
            exit 1
        fi
    else
        open "$INSTALLED" --args -BookwormsPreviewFolder preview
    fi
else
    open "$INSTALLED"
fi
