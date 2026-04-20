#!/bin/bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/load-dotenv.sh"

require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "$name is required" >&2
    exit 1
  fi
}

find_profile_name() {
  local bundle_id="$1"
  local expected_application_identifier="${APPLE_TEAM_ID}.${bundle_id}"
  local profile
  local profile_plist
  local application_identifier

  while IFS= read -r -d '' profile; do
    profile_plist="${TMPDIR:-/tmp}/$(basename "$profile").plist"
    security cms -D -i "$profile" > "$profile_plist"
    application_identifier="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$profile_plist" 2>/dev/null || true)"
    if [[ "$application_identifier" == "$expected_application_identifier" ]]; then
      /usr/libexec/PlistBuddy -c 'Print :Name' "$profile_plist"
      return 0
    fi
  done < <(find "$HOME/Library/MobileDevice/Provisioning Profiles" -name '*.provisionprofile' -print0)

  echo "Provisioning profile not found for $bundle_id" >&2
  exit 1
}

SCHEME="${SCHEME:-MFuse}"
PROJECT_PATH="${PROJECT_PATH:-MFuse.xcodeproj}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$PWD/build/MFuse.xcarchive}"
EXPORT_PATH="${EXPORT_PATH:-$PWD/build/export}"
ARTIFACTS_PATH="${ARTIFACTS_PATH:-$PWD/build/artifacts}"
EXPORT_OPTIONS_PATH="${EXPORT_OPTIONS_PATH:-$PWD/build/ExportOptions.plist}"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.lollipopkit.mfuse}"
EXTENSION_BUNDLE_ID="${EXTENSION_BUNDLE_ID:-com.lollipopkit.mfuse.provider}"
DMG_STAGING_PATH="${DMG_STAGING_PATH:-$PWD/build/dmg-root}"

require_var "APPLE_TEAM_ID"
require_var "APPLE_NOTARY_KEY_ID"
require_var "APPLE_NOTARY_ISSUER_ID"
require_var "APPLE_NOTARY_API_KEY_PATH"

if [[ ! -f "$APPLE_NOTARY_API_KEY_PATH" ]]; then
  echo "File not found: $APPLE_NOTARY_API_KEY_PATH" >&2
  exit 1
fi

APP_PROFILE_NAME="$(find_profile_name "$APP_BUNDLE_ID")"
EXTENSION_PROFILE_NAME="$(find_profile_name "$EXTENSION_BUNDLE_ID")"

mkdir -p "$EXPORT_PATH" "$ARTIFACTS_PATH" "$(dirname "$ARCHIVE_PATH")"
rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH" "$DMG_STAGING_PATH"

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' MFuse/Info.plist)"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' MFuse/Info.plist)"
DMG_BASENAME="MFuse-${APP_VERSION}-${APP_BUILD}"
DMG_PATH="$ARTIFACTS_PATH/${DMG_BASENAME}.dmg"

rm -f "$EXPORT_OPTIONS_PATH"
/usr/libexec/PlistBuddy -c 'Clear dict' "$EXPORT_OPTIONS_PATH"
/usr/libexec/PlistBuddy -c 'Add :method string developer-id' "$EXPORT_OPTIONS_PATH"
/usr/libexec/PlistBuddy -c 'Add :signingStyle string manual' "$EXPORT_OPTIONS_PATH"
/usr/libexec/PlistBuddy -c 'Add :stripSwiftSymbols bool true' "$EXPORT_OPTIONS_PATH"
/usr/libexec/PlistBuddy -c "Add :teamID string $APPLE_TEAM_ID" "$EXPORT_OPTIONS_PATH"
/usr/libexec/PlistBuddy -c 'Add :signingCertificate string Developer ID Application' "$EXPORT_OPTIONS_PATH"
/usr/libexec/PlistBuddy -c 'Add :provisioningProfiles dict' "$EXPORT_OPTIONS_PATH"
/usr/libexec/PlistBuddy -c "Add :provisioningProfiles:$APP_BUNDLE_ID string $APP_PROFILE_NAME" "$EXPORT_OPTIONS_PATH"
/usr/libexec/PlistBuddy -c "Add :provisioningProfiles:$EXTENSION_BUNDLE_ID string $EXTENSION_PROFILE_NAME" "$EXPORT_OPTIONS_PATH"

xcodebuild archive \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime"

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PATH"

APP_PATH="$EXPORT_PATH/MFuse.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Exported app not found at $APP_PATH" >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl -a -t exec -vv "$APP_PATH"

mkdir -p "$DMG_STAGING_PATH"
cp -R "$APP_PATH" "$DMG_STAGING_PATH/"
ln -s /Applications "$DMG_STAGING_PATH/Applications"

rm -f "$DMG_PATH"
hdiutil create \
  -volname "MFuse" \
  -srcfolder "$DMG_STAGING_PATH" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

codesign --force --sign "Developer ID Application" --timestamp "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"

xcrun notarytool submit "$DMG_PATH" \
  --key "$APPLE_NOTARY_API_KEY_PATH" \
  --key-id "$APPLE_NOTARY_KEY_ID" \
  --issuer "$APPLE_NOTARY_ISSUER_ID" \
  --wait

xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

echo "Created notarized DMG at $DMG_PATH"
