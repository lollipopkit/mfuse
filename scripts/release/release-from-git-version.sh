#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="${MFUSE_RELEASE_ENV_FILE:-$REPO_ROOT/.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "release environment file not found: $ENV_FILE" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "$name is required" >&2
    exit 1
  fi
}

require_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "file not found: $path" >&2
    exit 1
  fi
}

require_var APPLE_TEAM_ID
require_var APPLE_NOTARY_KEYCHAIN_PROFILE

SCHEME="${SCHEME:-MFuse}"
PROJECT_PATH="${PROJECT_PATH:-$REPO_ROOT/MFuse.xcodeproj}"
BASE_VERSION="${MFUSE_BASE_VERSION:-1.0}"
COMMIT_COUNT="$(git -C "$REPO_ROOT" rev-list --count HEAD)"
MARKETING_VERSION="${MARKETING_VERSION_OVERRIDE:-${BASE_VERSION}.${COMMIT_COUNT}}"
CURRENT_PROJECT_VERSION="${CURRENT_PROJECT_VERSION_OVERRIDE:-${COMMIT_COUNT}}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$REPO_ROOT/build/release/${SCHEME}-${MARKETING_VERSION}.xcarchive}"
EXPORT_PATH="${EXPORT_PATH:-$REPO_ROOT/build/export/${SCHEME}-${MARKETING_VERSION}}"
ARTIFACTS_PATH="${ARTIFACTS_PATH:-$REPO_ROOT/build/artifacts}"
EXPORT_OPTIONS_PATH="${EXPORT_OPTIONS_PATH:-$REPO_ROOT/build/ExportOptions-${MARKETING_VERSION}.plist}"
DMG_STAGING_PATH="${DMG_STAGING_PATH:-$REPO_ROOT/build/dmg-root}"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.lollipopkit.mfuse}"
EXTENSION_BUNDLE_ID="${EXTENSION_BUNDLE_ID:-com.lollipopkit.mfuse.provider}"
APP_NAME="${APP_NAME:-MFuse}"
VOLUME_NAME="${VOLUME_NAME:-MFuse}"
DMG_BASENAME="${DMG_BASENAME:-${APP_NAME}-${MARKETING_VERSION}-${CURRENT_PROJECT_VERSION}}"
DMG_PATH="${DMG_PATH:-$ARTIFACTS_PATH/${DMG_BASENAME}.dmg}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application}"
PROFILES_DIR="${PROFILES_DIR:-$HOME/Library/MobileDevice/Provisioning Profiles}"
APP_REPO_SLUG="${APP_REPO_SLUG:-lollipopkit/mfuse}"
RELEASE_TAG="${RELEASE_TAG:-v${MARKETING_VERSION}}"
RELEASE_TITLE="${RELEASE_TITLE:-$RELEASE_TAG}"
PUBLISH_GITHUB_RELEASE="${PUBLISH_GITHUB_RELEASE:-1}"

get_signing_identity_sha1() {
  security find-identity -v -p codesigning |
    grep -F "$SIGNING_IDENTITY" |
    head -n 1 |
    awk '{print $2}'
}

profile_contains_signing_identity() {
  local profile_plist="$1"
  local expected_sha1="$2"
  local cert_count
  local i
  local cert_path
  local cert_sha1

  cert_count="$(/usr/libexec/PlistBuddy -c 'Print :DeveloperCertificates' "$profile_plist" 2>/dev/null | awk 'NR>1 && /^\s*Data \{$/ {count++} END {print count+0}')"
  if [[ "$cert_count" == "0" ]]; then
    return 1
  fi

  for ((i = 0; i < cert_count; i++)); do
    cert_path="$(mktemp "${TMPDIR:-/tmp}/mfuse-cert.XXXXXX.cer")"
    /usr/libexec/PlistBuddy -x -c "Print :DeveloperCertificates:$i" "$profile_plist" |
      sed -n '/<data>/,/<\/data>/p' |
      sed '1d;$d' |
      tr -d ' \n\t' |
      base64 -D > "$cert_path"
    cert_sha1="$(openssl x509 -inform DER -in "$cert_path" -noout -fingerprint -sha1 | sed 's/^SHA1 Fingerprint=//' | tr -d ':')"
    rm -f "$cert_path"

    if [[ "$cert_sha1" == "$expected_sha1" ]]; then
      return 0
    fi
  done

  return 1
}

find_profile_name() {
  local bundle_id="$1"
  local expected_application_identifier="${APPLE_TEAM_ID}.${bundle_id}"
  local expected_signing_sha1="$2"
  local profile
  local profile_plist
  local application_identifier
  local is_xcode_managed
  local profile_name

  if [[ ! -d "$PROFILES_DIR" ]]; then
    echo "profiles directory not found: $PROFILES_DIR" >&2
    exit 1
  fi

  while IFS= read -r -d '' profile; do
    profile_plist="$(mktemp "${TMPDIR:-/tmp}/mfuse-profile.XXXXXX.plist")"
    security cms -D -i "$profile" > "$profile_plist"
    application_identifier="$(
      /usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$profile_plist" 2>/dev/null ||
      /usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$profile_plist" 2>/dev/null ||
      true
    )"
    is_xcode_managed="$(/usr/libexec/PlistBuddy -c 'Print :IsXcodeManaged' "$profile_plist" 2>/dev/null || echo false)"
    if [[ "$application_identifier" == "$expected_application_identifier" ]] &&
       [[ "$is_xcode_managed" == "false" ]] &&
       profile_contains_signing_identity "$profile_plist" "$expected_signing_sha1"; then
      profile_name="$(/usr/libexec/PlistBuddy -c 'Print :Name' "$profile_plist")"
      rm -f "$profile_plist"
      printf '%s\n' "$profile_name"
      return 0
    fi
    rm -f "$profile_plist"
  done < <(find "$PROFILES_DIR" -name '*.provisionprofile' -print0)

  echo "matching Developer ID provisioning profile not found for $bundle_id" >&2
  exit 1
}

mkdir -p "$ARTIFACTS_PATH" "$(dirname "$ARCHIVE_PATH")"

if ! security find-identity -v -p codesigning | grep -F "$SIGNING_IDENTITY" >/dev/null; then
  echo "signing identity not found in keychain: $SIGNING_IDENTITY" >&2
  exit 1
fi

if [[ -z "${APP_PROFILE_NAME:-}" || -z "${EXTENSION_PROFILE_NAME:-}" ]]; then
  SIGNING_IDENTITY_SHA1="$(get_signing_identity_sha1)"
  if [[ -z "$SIGNING_IDENTITY_SHA1" ]]; then
    echo "unable to resolve signing identity fingerprint for $SIGNING_IDENTITY" >&2
    exit 1
  fi
fi

APP_PROFILE_NAME="${APP_PROFILE_NAME:-$(find_profile_name "$APP_BUNDLE_ID" "$SIGNING_IDENTITY_SHA1")}"
EXTENSION_PROFILE_NAME="${EXTENSION_PROFILE_NAME:-$(find_profile_name "$EXTENSION_BUNDLE_ID" "$SIGNING_IDENTITY_SHA1")}"

rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH" "$DMG_STAGING_PATH"
rm -f "$EXPORT_OPTIONS_PATH" "$DMG_PATH"
/usr/libexec/PlistBuddy -c 'Clear dict' "$EXPORT_OPTIONS_PATH"
/usr/libexec/PlistBuddy -c 'Add :method string developer-id' "$EXPORT_OPTIONS_PATH"
/usr/libexec/PlistBuddy -c 'Add :signingStyle string manual' "$EXPORT_OPTIONS_PATH"
/usr/libexec/PlistBuddy -c 'Add :stripSwiftSymbols bool true' "$EXPORT_OPTIONS_PATH"
/usr/libexec/PlistBuddy -c "Add :teamID string $APPLE_TEAM_ID" "$EXPORT_OPTIONS_PATH"
/usr/libexec/PlistBuddy -c "Add :signingCertificate string $SIGNING_IDENTITY" "$EXPORT_OPTIONS_PATH"
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
  MARKETING_VERSION="$MARKETING_VERSION" \
  CURRENT_PROJECT_VERSION="$CURRENT_PROJECT_VERSION" \
  OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime"

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PATH"

APP_PATH="$EXPORT_PATH/${APP_NAME}.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "exported app not found at $APP_PATH" >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"

mkdir -p "$DMG_STAGING_PATH"
ditto "$APP_PATH" "$DMG_STAGING_PATH/${APP_NAME}.app"
ln -s /Applications "$DMG_STAGING_PATH/Applications"

hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$DMG_STAGING_PATH" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"

xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$APPLE_NOTARY_KEYCHAIN_PROFILE" \
  --wait

xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

if [[ "$PUBLISH_GITHUB_RELEASE" == "1" ]]; then
  if gh release view "$RELEASE_TAG" --repo "$APP_REPO_SLUG" >/dev/null 2>&1; then
    gh release edit "$RELEASE_TAG" \
      --repo "$APP_REPO_SLUG" \
      --title "$RELEASE_TITLE"
  else
    gh release create "$RELEASE_TAG" \
      --repo "$APP_REPO_SLUG" \
      --title "$RELEASE_TITLE" \
      --notes ""
  fi

  gh release upload "$RELEASE_TAG" "$DMG_PATH" \
    --repo "$APP_REPO_SLUG" \
    --clobber
fi

if [[ "${SYNC_HOMEBREW_CASK:-1}" == "1" ]]; then
  XCARCHIVE_PATH="$ARCHIVE_PATH" \
  DMG_PATH="$DMG_PATH" \
  TAP_REPO_PATH="${TAP_REPO_PATH:-$HOME/proj/homebrew-taps}" \
  bash "$SCRIPT_DIR/sync-homebrew-cask.sh"
fi

echo "Release complete"
echo "Marketing version: $MARKETING_VERSION"
echo "Build number: $CURRENT_PROJECT_VERSION"
echo "Commit count: $COMMIT_COUNT"
echo "Archive: $ARCHIVE_PATH"
echo "Exported app: $APP_PATH"
echo "DMG: $DMG_PATH"
echo "GitHub release: $APP_REPO_SLUG $RELEASE_TAG"
