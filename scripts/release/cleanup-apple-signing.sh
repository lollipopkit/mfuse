#!/bin/bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/load-dotenv.sh"

STATE_PATH="${APPLE_SIGNING_STATE_PATH:-$PWD/build/release-signing-state.env}"

if [[ ! -f "$STATE_PATH" ]]; then
  echo "No signing state found at $STATE_PATH"
  exit 0
fi

# shellcheck disable=SC1090
source "$STATE_PATH"

if [[ -n "${PREVIOUS_DEFAULT_KEYCHAIN:-}" ]]; then
  if ! security default-keychain -d user -s "$PREVIOUS_DEFAULT_KEYCHAIN" >/dev/null; then
    echo "Warning: failed to restore previous default keychain: $PREVIOUS_DEFAULT_KEYCHAIN" >&2
  fi
fi

if [[ -n "${KEYCHAIN_PATH:-}" ]]; then
  security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
fi

if [[ -n "${APP_INSTALLED_PROFILE_PATH:-}" ]]; then
  rm -f "$APP_INSTALLED_PROFILE_PATH"
fi

if [[ -n "${EXT_INSTALLED_PROFILE_PATH:-}" ]]; then
  rm -f "$EXT_INSTALLED_PROFILE_PATH"
fi

rm -f "$STATE_PATH"

echo "Cleaned temporary signing assets"
