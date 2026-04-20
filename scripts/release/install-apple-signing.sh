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

require_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    echo "File not found: $path" >&2
    exit 1
  fi
}

require_var "APPLE_DEVELOPER_ID_APP_P12_PATH"
require_var "APPLE_DEVELOPER_ID_APP_P12_PASSWORD"
require_var "APPLE_DEVELOPER_ID_APP_PROFILE_PATH"
require_var "APPLE_DEVELOPER_ID_EXTENSION_PROFILE_PATH"

require_file "$APPLE_DEVELOPER_ID_APP_P12_PATH"
require_file "$APPLE_DEVELOPER_ID_APP_PROFILE_PATH"
require_file "$APPLE_DEVELOPER_ID_EXTENSION_PROFILE_PATH"

STATE_PATH="${APPLE_SIGNING_STATE_PATH:-$PWD/build/release-signing-state.env}"
KEYCHAIN_PATH="${APPLE_SIGNING_KEYCHAIN_PATH:-${TMPDIR:-/tmp}/mfuse-signing-$(uuidgen).keychain-db}"
KEYCHAIN_PASSWORD="${APPLE_SIGNING_KEYCHAIN_PASSWORD:-$(uuidgen)}"
APP_PROFILE_PLIST="$(mktemp "${TMPDIR:-/tmp}/mfuse-app-profile.XXXXXX.plist")"
EXT_PROFILE_PLIST="$(mktemp "${TMPDIR:-/tmp}/mfuse-extension-profile.XXXXXX.plist")"
PREVIOUS_DEFAULT_KEYCHAIN="$(security default-keychain -d user | sed 's/[[:space:]]//g' | tr -d '"')"
USER_KEYCHAIN_FALLBACK="${PREVIOUS_DEFAULT_KEYCHAIN:-login.keychain-db}"
INSTALL_COMPLETED=false
CLEANUP_RAN=false

cleanup() {
  local exit_status=$?
  if [[ "$CLEANUP_RAN" == true ]]; then
    return
  fi
  CLEANUP_RAN=true

  if [[ "$INSTALL_COMPLETED" != true ]]; then
    if [[ -n "$PREVIOUS_DEFAULT_KEYCHAIN" ]]; then
      security default-keychain -d user -s "$PREVIOUS_DEFAULT_KEYCHAIN" >/dev/null 2>&1 || true
    fi
    security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
  fi

  rm -f "$APP_PROFILE_PLIST" "$EXT_PROFILE_PLIST"
  return "$exit_status"
}

trap cleanup EXIT ERR

mkdir -p "$(dirname "$STATE_PATH")"

cat > "$STATE_PATH" <<EOF
PREVIOUS_DEFAULT_KEYCHAIN='$PREVIOUS_DEFAULT_KEYCHAIN'
KEYCHAIN_PATH='$KEYCHAIN_PATH'
EOF

security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security import "$APPLE_DEVELOPER_ID_APP_P12_PATH" \
  -P "$APPLE_DEVELOPER_ID_APP_P12_PASSWORD" \
  -T "/usr/bin/codesign" \
  -T "/usr/bin/productbuild" \
  -t cert \
  -f pkcs12 \
  -k "$KEYCHAIN_PATH"
security set-key-partition-list -S apple-tool:,apple: -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security list-keychains -d user -s "$KEYCHAIN_PATH" "$USER_KEYCHAIN_FALLBACK"
security default-keychain -d user -s "$KEYCHAIN_PATH"

mkdir -p "$HOME/Library/MobileDevice/Provisioning Profiles"
security cms -D -i "$APPLE_DEVELOPER_ID_APP_PROFILE_PATH" > "$APP_PROFILE_PLIST"
security cms -D -i "$APPLE_DEVELOPER_ID_EXTENSION_PROFILE_PATH" > "$EXT_PROFILE_PLIST"

APP_PROFILE_UUID="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$APP_PROFILE_PLIST")"
EXT_PROFILE_UUID="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$EXT_PROFILE_PLIST")"

APP_INSTALLED_PROFILE_PATH="$HOME/Library/MobileDevice/Provisioning Profiles/${APP_PROFILE_UUID}.provisionprofile"
EXT_INSTALLED_PROFILE_PATH="$HOME/Library/MobileDevice/Provisioning Profiles/${EXT_PROFILE_UUID}.provisionprofile"

cp "$APPLE_DEVELOPER_ID_APP_PROFILE_PATH" \
  "$APP_INSTALLED_PROFILE_PATH"
cp "$APPLE_DEVELOPER_ID_EXTENSION_PROFILE_PATH" \
  "$EXT_INSTALLED_PROFILE_PATH"

cat > "$STATE_PATH" <<EOF
PREVIOUS_DEFAULT_KEYCHAIN='$PREVIOUS_DEFAULT_KEYCHAIN'
KEYCHAIN_PATH='$KEYCHAIN_PATH'
APP_INSTALLED_PROFILE_PATH='$APP_INSTALLED_PROFILE_PATH'
EXT_INSTALLED_PROFILE_PATH='$EXT_INSTALLED_PROFILE_PATH'
EOF

INSTALL_COMPLETED=true

echo "Installed signing identities:"
security find-identity -v -p codesigning "$KEYCHAIN_PATH"
echo "Signing keychain: $KEYCHAIN_PATH"
echo "Signing state: $STATE_PATH"
