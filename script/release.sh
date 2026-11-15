#!/usr/bin/env bash
# Archives, checks, and uploads a release candidate of the iPhone and Mac app (docs/RELEASING.md,
# Before each archive). Keep each candidate folder under the Git-ignored .local/releases/.
# Usage:
#   script/release.sh archive <candidate folder> <iOS|macOS>
#       archives the Bookworms scheme in Release and exports it for App Store Connect to the
#       folder's export-<platform>/; the export's destination is `export`, so it never uploads
#   script/release.sh check <candidate folder>
#       prints the entitlement and bundle checks for the folder's exports
#   script/release.sh upload <candidate folder> <iOS|macOS>
#       uploads that platform's archive to App Store Connect
#
# Authentication: with ASC_KEY_PATH, ASC_KEY_ID, and ASC_ISSUER_ID set (`. ~/.appstoreconnect/
# bookworms.env`), every xcodebuild call signs in with the team's App Store Connect API key, which
# needs the Admin role. With none of them set, xcodebuild uses the account signed in to Xcode.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

usage() {
    sed -n '/^# Usage:/,/^#$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

# Sets AUTH to the xcodebuild options for the App Store Connect API key, or to nothing when no
# key variable is set.
AUTH=()
read_authentication() {
    local key_path="${ASC_KEY_PATH:-}" key_id="${ASC_KEY_ID:-}" issuer="${ASC_ISSUER_ID:-}"
    if [[ -z "$key_path$key_id$issuer" ]]; then
        return
    fi
    if [[ -z "$key_path" || -z "$key_id" || -z "$issuer" ]]; then
        echo "Set all three ASC_KEY_PATH, ASC_KEY_ID, and ASC_ISSUER_ID, or none." >&2
        exit 1
    fi
    key_path="${key_path/#\~/$HOME}"
    if [[ -f "$key_path" ]]; then
        key_path="$(cd "$(dirname "$key_path")" && pwd -P)/$(basename "$key_path")"
    fi
    if [[ ! -f "$key_path" || "$key_path" == "$ROOT_DIR"/* ]]; then
        echo "ASC_KEY_PATH must point to a private key outside this repository." >&2
        exit 1
    fi
    AUTH=(-authenticationKeyPath "$key_path" -authenticationKeyID "$key_id"
        -authenticationKeyIssuerID "$issuer")
}

# Runs xcodebuild with provisioning updates and AUTH, writes its output to <log>, and prints its
# exit status and the log's lines that match <pattern>. Returns xcodebuild's exit status.
xcodebuild_logged() {  # <log> <pattern> <xcodebuild arguments>...
    local log="$1" pattern="$2" status=0
    shift 2
    # macOS's bash 3.2 treats an empty array as unset under `set -u`, hence the + expansion.
    xcodebuild "$@" -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} > "$log" 2>&1 || status=$?
    echo "$(basename "$log" .log) exit $status"
    grep -E "$pattern" "$log" | head -20 || true
    return "$status"
}

# Writes the App Store Connect export options with <destination> (export or upload) and prints
# the file's path.
export_options() {  # <destination>
    local plist="$OUT/ExportOptions-$1.plist"
    cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>destination</key><string>$1</string>
	<key>teamID</key><string>KSZ7QR8Y88</string>
	<key>signingStyle</key><string>automatic</string>
	<key>uploadSymbols</key><true/>
	<key>manageAppVersionAndBuildNumber</key><false/>
	<key>iCloudContainerEnvironment</key><string>Production</string>
</dict>
</plist>
PLIST
    echo "$plist"
}

# Exports the platform's archive with <destination> to <destination>-<platform>/.
export_archive() {  # <destination>
    xcodebuild_logged "$OUT/$1-$PLATFORM.log" "EXPORT (SUCCEEDED|FAILED)|Upload succeeded|error:|Error" \
        -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/$1-$PLATFORM" \
        -exportOptionsPlist "$(export_options "$1")"
}

archive() {
    mkdir -p "$OUT/dd-archive-$PLATFORM"
    (cd "$ROOT_DIR" && xcodebuild_logged "$OUT/archive-$PLATFORM.log" "ARCHIVE (SUCCEEDED|FAILED)|error:" \
        archive -project Bookworms.xcodeproj -scheme Bookworms -configuration Release \
        -destination "generic/platform=$PLATFORM" -archivePath "$ARCHIVE" \
        -derivedDataPath "$OUT/dd-archive-$PLATFORM" OTHER_SWIFT_FLAGS=-disable-sandbox)
    export_archive export
    ls "$OUT/export-$PLATFORM"
}

upload() {
    if [[ ! -d "$ARCHIVE" || ! -d "$OUT/export-$PLATFORM" ]]; then
        echo "No exported $PLATFORM archive in $OUT. Run archive and check first." >&2
        exit 1
    fi
    export_archive upload
}

# Prints one app bundle's version, privacy manifest, binary, example profile, and signature.
check_bundle() {  # <app> <Info.plist> <privacy manifest> <binary> <resources>
    echo "version: $(plutil -extract CFBundleShortVersionString raw "$2")  build: $(plutil -extract CFBundleVersion raw "$2")  bundle ID: $(plutil -extract CFBundleIdentifier raw "$2")"
    echo "NSLocalNetworkUsageDescription: $(plutil -extract NSLocalNetworkUsageDescription raw "$2")"
    if [[ -f "$3" ]]; then
        echo "PrivacyInfo.xcprivacy: present at ${3#"$1"/}; reasons: $(plutil -p "$3" | grep -oE '"[A-Z0-9]{4}\.[0-9]"' | tr '\n' ' ')"
    else
        echo "PrivacyInfo.xcprivacy: MISSING at $3"
    fi
    echo "LLVM coverage or profile sections in the binary: $(otool -l "$4" | grep -cE '__llvm_(cov|prf)')"
    echo "architectures: $(lipo -archs "$4")"
    echo "example profile: $([[ -f "$5/ExampleProfile/library-v1.json" ]] && echo present || echo MISSING)"
    codesign -dvv "$1" 2>&1 | grep -E "^Authority=|^TeamIdentifier=" | head -2
    codesign --verify --deep --strict "$1" && echo "codesign --verify: ok"
}

check() {
    # The checks print a missing value or a failed verification instead of stopping, so one run
    # shows every result.
    set +e
    cd "$OUT"
    rm -rf ipa pkg
    echo "== iPhone .ipa"
    unzip -q export-iOS/Bookworms.ipa -d ipa
    local app=ipa/Payload/Bookworms.app
    codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -p -
    check_bundle "$app" "$app/Info.plist" "$app/PrivacyInfo.xcprivacy" "$app/Bookworms" "$app"
    echo
    if [[ -f export-macOS/Bookworms.pkg ]]; then
        echo "== Mac .pkg"
        pkgutil --expand-full export-macOS/Bookworms.pkg pkg
        app="$(find pkg -type d -name Bookworms.app | head -n 1)"
    else
        echo "== Mac archive, development-signed (no exported .pkg): its entitlements are NOT the distribution values"
        app=Bookworms-macOS.xcarchive/Products/Applications/Bookworms.app
    fi
    codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -p -
    check_bundle "$app" "$app/Contents/Info.plist" "$app/Contents/Resources/PrivacyInfo.xcprivacy" \
        "$app/Contents/MacOS/Bookworms" "$app/Contents/Resources"
    [[ -f export-macOS/Bookworms.pkg ]] && pkgutil --check-signature export-macOS/Bookworms.pkg | sed -n 1,6p
    rm -rf ipa pkg
}

COMMAND="${1:-}"
case "$COMMAND" in
    archive | upload)
        [[ $# == 3 && ( "$3" == iOS || "$3" == macOS ) ]] || usage
        PLATFORM="$3"
        [[ "$COMMAND" == archive ]] && mkdir -p "$2"
        ;;
    check) [[ $# == 2 ]] || usage ;;
    *) usage ;;
esac
[[ -d "$2" ]] || { echo "No candidate folder at $2." >&2; exit 1; }
OUT="$(cd "$2" && pwd -P)"
if [[ "$COMMAND" != check ]]; then
    ARCHIVE="$OUT/Bookworms-$PLATFORM.xcarchive"
    read_authentication
fi
"$COMMAND"
