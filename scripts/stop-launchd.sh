#!/bin/bash
set -euo pipefail

launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.codex.bridge.plist" >/dev/null 2>&1 || true
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.localdev.bridge.plist" >/dev/null 2>&1 || true

echo "Stopped Codex Bridge launchd services."
