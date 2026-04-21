#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PROJECT_PATH="${PROJECT_PATH:-$REPO_ROOT/MFuse.xcodeproj}"
SCHEME="${SCHEME:-MFuse}"
CONFIGURATION="${CONFIGURATION:-Release}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$REPO_ROOT/build/release-install/MFuse.xcarchive}"
INSTALL_PATH="${INSTALL_PATH:-/Applications/MFuse.app}"
REQUIRED_APP_GROUP="${REQUIRED_APP_GROUP:-group.com.lollipopkit.mfuse.shared}"

if [[ ! -d "$PROJECT_PATH" ]]; then
  echo "Project not found: $PROJECT_PATH" >&2
  echo "Run 'make generate' first if MFuse.xcodeproj has not been generated yet." >&2
  exit 1
fi

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

  profile_plist="$(mktemp "${TMPDIR:-/tmp}/mfuse-embedded-profile.XXXXXX.plist")"
  security cms -D -i "$embedded_profile" > "$profile_plist"
  groups="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.security.application-groups' "$profile_plist" 2>/dev/null || true)"
  rm -f "$profile_plist"

  if [[ "$groups" != *"$REQUIRED_APP_GROUP"* ]]; then
    echo "$bundle_name embedded provisioning profile does not authorize $REQUIRED_APP_GROUP" >&2
    echo "Refusing to install a broken build because macOS will prompt for cross-app data access and hide the File Provider extension." >&2
    exit 1
  fi
}

rm -rf "$ARCHIVE_PATH"
mkdir -p "$(dirname "$ARCHIVE_PATH")"

echo "Archiving $SCHEME ($CONFIGURATION) using current Xcode project signing settings..."
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  archive

APP_PATH="$ARCHIVE_PATH/Products/Applications/$SCHEME.app"
if [[ ! -d "$APP_PATH" ]]; then
  echo "Archived app not found: $APP_PATH" >&2
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
