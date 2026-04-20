#!/bin/bash
set -euo pipefail

ENV_FILE="${MFUSE_RELEASE_ENV_FILE:-$PWD/.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  exit 0
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
