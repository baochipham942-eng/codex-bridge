#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
mkdir -p logs "$HOME/Library/LaunchAgents"
RUNTIME_DIR="$HOME/.codex-bridge/bridge-runtime"

if [ ! -f bridge.policy.local.json ]; then
  echo "[FAIL] bridge.policy.local.json is missing. Run: bash scripts/bootstrap-macos.sh" >&2
  exit 1
fi

npm run build >/dev/null
mkdir -p "$RUNTIME_DIR"
rsync -a --delete dist package.json package-lock.json bridge.policy.local.json node_modules "$RUNTIME_DIR/"

launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.codexweb.bridge.plist" >/dev/null 2>&1 || true
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.localdev.bridge.plist" >/dev/null 2>&1 || true
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.codex.bridge.plist" >/dev/null 2>&1 || true

sed \
  -e "s#__HOME__#$HOME#g" \
  -e "s#__ROOT__#$ROOT#g" \
  launchd/com.codex.bridge.plist > "$HOME/Library/LaunchAgents/com.codex.bridge.plist"

launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.codex.bridge.plist"

echo "Installed launchd services:"
launchctl print "gui/$(id -u)/com.codex.bridge" | sed -n '1,12p'
echo "Local URL: http://127.0.0.1:3848/mcp"
