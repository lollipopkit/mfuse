#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
ENV_FILE="${MFUSE_RELEASE_ENV_FILE:-$REPO_ROOT/.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "error: release environment file not found at '$ENV_FILE'; environment loading was skipped." >&2
  if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 1
  fi
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
