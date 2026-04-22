#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/load-dotenv.sh"

cleanup() {
  bash "$SCRIPT_DIR/cleanup-apple-signing.sh"
}

trap cleanup EXIT

bash "$SCRIPT_DIR/install-apple-signing.sh"
bash "$SCRIPT_DIR/build-and-notarize-dmg.sh"
