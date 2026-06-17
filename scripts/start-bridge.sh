#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
exec node dist/index.js --http "${CODEX_BRIDGE_PORT:-${LOCAL_DEV_BRIDGE_PORT:-3848}}"
