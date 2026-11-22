#!/usr/bin/env bash
# Signed iOS release: archive -> export (App Store Connect / TestFlight) -> optional upload.
#
#   scripts/release.sh                 archive + export an .ipa into dist/
#   scripts/release.sh --upload        ...and upload it to App Store Connect (TestFlight)
#
# Needs (once): Xcode signed in to the developer account (Xcode → Settings → Accounts),
# Config/Local.xcconfig with DEVELOPMENT_TEAM and BUNDLE_ID_PREFIX, and the app record
# created in App Store Connect for that bundle id. Signing is automatic: Xcode creates the
# Apple Distribution certificate and profiles on first run (-allowProvisioningUpdates).
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
UPLOAD=0; [[ "${1:-}" == "--upload" ]] && UPLOAD=1
TEAM=$(grep -E '^\s*DEVELOPMENT_TEAM' Config/Local.xcconfig 2>/dev/null | sed 's/.*= *//' | tr -d ' ')
[[ -n "$TEAM" && "$TEAM" != ABCDE12345 ]] || { echo "Set DEVELOPMENT_TEAM in Config/Local.xcconfig (see Local.xcconfig.example)"; exit 1; }
SCHEME="${SCHEME:-JoeBroMobile}"
ARCHIVE="build/$SCHEME.xcarchive"; OUT=dist
command -v xcodegen >/dev/null || PATH=/opt/homebrew/bin:$PATH
xcodegen generate -q
rm -rf "$ARCHIVE"
xcodebuild -project JoeBroMobile.xcodeproj -scheme "$SCHEME" -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic archive | grep -E "error:|ARCHIVE" || true
[[ -d "$ARCHIVE" ]] || { echo "Archive failed"; exit 1; }
DEST=export; [[ $UPLOAD == 1 ]] && DEST=upload
cat > build/ExportOptions.plist <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$DEST</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><true/>
</dict></plist>
PL
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist build/ExportOptions.plist \
  -exportPath "$OUT" -allowProvisioningUpdates | grep -E "error:|EXPORT" || true
[[ $UPLOAD == 1 ]] && echo "Uploaded to App Store Connect — it appears in TestFlight after processing." || ls -la "$OUT"/*.ipa
