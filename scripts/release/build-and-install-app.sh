#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PROJECT_PATH="${PROJECT_PATH:-$REPO_ROOT/MFuse.xcodeproj}"
SCHEME="${SCHEME:-MFuse}"
CONFIGURATION="${CONFIGURATION:-Release}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$REPO_ROOT/build/release-install/MFuse.xcarchive}"
EXPORT_PATH="${EXPORT_PATH:-$REPO_ROOT/build/release-install/export}"
INSTALL_PATH="${INSTALL_PATH:-/Applications/MFuse.app}"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-com.lollipopkit.mfuse}"
EXTENSION_BUNDLE_ID="${EXTENSION_BUNDLE_ID:-com.lollipopkit.mfuse.provider}"
REQUIRED_APP_GROUP="${REQUIRED_APP_GROUP:-group.com.lollipopkit.mfuse.shared}"
PROVISIONING_PROFILES_DIR="${PROVISIONING_PROFILES_DIR:-$HOME/Library/MobileDevice/Provisioning Profiles}"

if [[ ! -d "$PROJECT_PATH" ]]; then
  echo "Project not found: $PROJECT_PATH" >&2
  echo "Run 'make generate' first if MFuse.xcodeproj has not been generated yet." >&2
  exit 1
fi

profile_has_provisioned_devices() {
  local profile_plist="$1"
  /usr/libexec/PlistBuddy -c 'Print :ProvisionedDevices:0' "$profile_plist" >/dev/null 2>&1
}

find_profile_metadata() {
  local distribution_kind="$1"
  local bundle_id="$2"
  local profile
  local profile_plist
  local team_id
  local app_identifier
  local profile_name
  local groups
  local has_devices

  if [[ ! -d "$PROVISIONING_PROFILES_DIR" ]]; then
    return 1
  fi

  while IFS= read -r -d '' profile; do
    profile_plist="$(mktemp "${TMPDIR:-/tmp}/mfuse-profile.XXXXXX.plist")"
    security cms -D -i "$profile" > "$profile_plist"

    team_id="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$profile_plist" 2>/dev/null || true)"
    app_identifier="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$profile_plist" 2>/dev/null || true)"
    profile_name="$(/usr/libexec/PlistBuddy -c 'Print :Name' "$profile_plist" 2>/dev/null || true)"
    groups="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.security.application-groups' "$profile_plist" 2>/dev/null || true)"
    has_devices=false
    if profile_has_provisioned_devices "$profile_plist"; then
      has_devices=true
    fi

    rm -f "$profile_plist"

    if [[ -z "$team_id" || -z "$profile_name" ]]; then
      continue
    fi

    if [[ "$app_identifier" != "${team_id}.${bundle_id}" ]]; then
      continue
    fi

    if [[ "$groups" != *"$REQUIRED_APP_GROUP"* ]]; then
      continue
    fi

    case "$distribution_kind" in
      development)
        [[ "$has_devices" == true ]] || continue
        ;;
      distribution)
        [[ "$has_devices" == false ]] || continue
        ;;
      *)
        echo "Unknown distribution kind: $distribution_kind" >&2
        exit 1
        ;;
    esac

    printf '%s\t%s\n' "$team_id" "$profile_name"
    return 0
  done < <(find "$PROVISIONING_PROFILES_DIR" -name '*.provisionprofile' -print0)

  return 1
}

has_signing_identity() {
  local identity_name="$1"
  security find-identity -v -p codesigning 2>/dev/null | grep -Fq "$identity_name"
}

validate_embedded_profile() {
  local bundle_path="$1"
  local bundle_name="$2"
  local embedded_profile="$bundle_path/Contents/embedded.provisionprofile"
  local profile_plist
  local groups

  if [[ ! -f "$embedded_profile" ]]; then
    echo "$bundle_name is missing embedded.provisionprofile" >&2
    exit 1
  fi

  profile_plist="$(mktemp "${TMPDIR:-/tmp}/mfuse-export-profile.XXXXXX.plist")"
  security cms -D -i "$embedded_profile" > "$profile_plist"
  groups="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.security.application-groups' "$profile_plist" 2>/dev/null || true)"
  rm -f "$profile_plist"

  if [[ "$groups" != *"$REQUIRED_APP_GROUP"* ]]; then
    echo "$bundle_name embedded provisioning profile does not authorize $REQUIRED_APP_GROUP" >&2
    echo "Refusing to install a broken build because macOS will prompt for cross-app data access and hide the File Provider extension." >&2
    exit 1
  fi
}

EXPORT_METHOD=""
SIGNING_CERTIFICATE=""
TEAM_ID=""
APP_PROFILE_NAME=""
EXTENSION_PROFILE_NAME=""
APP_METADATA=""
EXTENSION_METADATA=""

if has_signing_identity "Developer ID Application"; then
  APP_METADATA="$(find_profile_metadata distribution "$APP_BUNDLE_ID" || true)"
  EXTENSION_METADATA="$(find_profile_metadata distribution "$EXTENSION_BUNDLE_ID" || true)"
  if [[ -n "$APP_METADATA" && -n "$EXTENSION_METADATA" ]]; then
    EXPORT_METHOD="developer-id"
    SIGNING_CERTIFICATE="Developer ID Application"
  fi
fi

if [[ -z "$EXPORT_METHOD" ]] && has_signing_identity "Apple Development"; then
  APP_METADATA="$(find_profile_metadata development "$APP_BUNDLE_ID" || true)"
  EXTENSION_METADATA="$(find_profile_metadata development "$EXTENSION_BUNDLE_ID" || true)"
  if [[ -n "$APP_METADATA" && -n "$EXTENSION_METADATA" ]]; then
    EXPORT_METHOD="debugging"
    SIGNING_CERTIFICATE="Apple Development"
  fi
fi

if [[ -z "$EXPORT_METHOD" || -z "$APP_METADATA" || -z "$EXTENSION_METADATA" ]]; then
  cat >&2 <<EOF
No valid provisioning profiles were found for local installation.

MFuse requires explicit provisioning profiles for both:
  - $APP_BUNDLE_ID
  - $EXTENSION_BUNDLE_ID

Those profiles must authorize the App Group:
  - $REQUIRED_APP_GROUP

The generic "Mac Team Provisioning Profile: *" is not sufficient here.
It omits com.apple.security.application-groups, which causes:
  - launch prompt: "MFuse.app would like to access data from other apps"
  - File Provider settings entry missing
  - mounts opening as empty/shared-container folders
EOF
  exit 1
fi

IFS=$'\t' read -r APP_TEAM_ID APP_PROFILE_NAME <<< "$APP_METADATA"
IFS=$'\t' read -r EXTENSION_TEAM_ID EXTENSION_PROFILE_NAME <<< "$EXTENSION_METADATA"

if [[ "$APP_TEAM_ID" != "$EXTENSION_TEAM_ID" ]]; then
  echo "Provisioning profiles use different team identifiers: $APP_TEAM_ID vs $EXTENSION_TEAM_ID" >&2
  exit 1
fi

TEAM_ID="$APP_TEAM_ID"
EXPORT_OPTIONS_PATH="$(mktemp "${TMPDIR:-/tmp}/mfuse-export-options.XXXXXX.plist")"

cleanup() {
  rm -f "$EXPORT_OPTIONS_PATH"
}
trap cleanup EXIT

rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"
mkdir -p "$(dirname "$ARCHIVE_PATH")" "$EXPORT_PATH"
rm -f "$EXPORT_OPTIONS_PATH"

/usr/libexec/PlistBuddy -c 'Clear dict' "$EXPORT_OPTIONS_PATH"
/usr/libexec/PlistBuddy -c "Add :method string $EXPORT_METHOD" "$EXPORT_OPTIONS_PATH"
/usr/libexec/PlistBuddy -c 'Add :signingStyle string manual' "$EXPORT_OPTIONS_PATH"
/usr/libexec/PlistBuddy -c 'Add :stripSwiftSymbols bool true' "$EXPORT_OPTIONS_PATH"
/usr/libexec/PlistBuddy -c "Add :teamID string $TEAM_ID" "$EXPORT_OPTIONS_PATH"
/usr/libexec/PlistBuddy -c "Add :signingCertificate string $SIGNING_CERTIFICATE" "$EXPORT_OPTIONS_PATH"
/usr/libexec/PlistBuddy -c 'Add :provisioningProfiles dict' "$EXPORT_OPTIONS_PATH"
/usr/libexec/PlistBuddy -c "Add :provisioningProfiles:$APP_BUNDLE_ID string $APP_PROFILE_NAME" "$EXPORT_OPTIONS_PATH"
/usr/libexec/PlistBuddy -c "Add :provisioningProfiles:$EXTENSION_BUNDLE_ID string $EXTENSION_PROFILE_NAME" "$EXPORT_OPTIONS_PATH"

echo "Archiving $SCHEME ($CONFIGURATION)..."
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  archive

echo "Exporting signed app with $SIGNING_CERTIFICATE..."
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PATH"

APP_PATH="$EXPORT_PATH/$SCHEME.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Exported app not found: $APP_PATH" >&2
  exit 1
fi

validate_embedded_profile "$APP_PATH" "$SCHEME.app"
validate_embedded_profile "$APP_PATH/Contents/PlugIns/MFuseProvider.appex" "MFuseProvider.appex"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"

mkdir -p "$(dirname "$INSTALL_PATH")"

echo "Installing to $INSTALL_PATH..."
ditto "$APP_PATH" "$INSTALL_PATH"

PLUGIN_PATH="$INSTALL_PATH/Contents/PlugIns/MFuseProvider.appex"
if [[ -d "$PLUGIN_PATH" ]]; then
  echo "Registering File Provider extension..."
  if ! pluginkit -a "$PLUGIN_PATH"; then
    echo "Warning: pluginkit registration failed for $PLUGIN_PATH" >&2
  fi
fi

echo
echo "Installed app signature:"
codesign -d --verbose=4 "$INSTALL_PATH"
