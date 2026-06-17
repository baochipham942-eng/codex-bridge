#!/bin/bash
set -euo pipefail

DATADIR="${CODEX_BRIDGE_DATA_DIR:-${LOCAL_DEV_BRIDGE_DATA_DIR:-$HOME/.codex-bridge}}"
BRIDGE_PIDFILE="${CODEX_BRIDGE_PID_FILE:-${LOCAL_DEV_BRIDGE_PID_FILE:-$DATADIR/codex-bridge.pid}}"
CLOUDFLARED_PIDFILE="${CODEX_BRIDGE_CLOUDFLARED_PID_FILE:-${LOCAL_DEV_BRIDGE_CLOUDFLARED_PID_FILE:-$DATADIR/cloudflared.pid}}"

stop_pidfile() {
  local name="$1"
  local pidfile="$2"
  if [ ! -f "$pidfile" ]; then
    echo "[INFO] $name pid file not found."
    return
  fi
  local pid
  pid="$(cat "$pidfile" 2>/dev/null || true)"
  if [ -z "$pid" ]; then
    rm -f "$pidfile"
    echo "[INFO] $name pid file was empty."
    return
  fi
  if kill -0 "$pid" >/dev/null 2>&1; then
    kill "$pid" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
      if ! kill -0 "$pid" >/dev/null 2>&1; then
        break
      fi
      sleep 0.2
    done
    if kill -0 "$pid" >/dev/null 2>&1; then
      kill -9 "$pid" >/dev/null 2>&1 || true
    fi
    echo "[OK] Stopped $name pid=$pid"
  else
    echo "[INFO] $name was not running."
  fi
  rm -f "$pidfile"
}

stop_pidfile "cloudflared tunnel" "$CLOUDFLARED_PIDFILE"
stop_pidfile "local bridge" "$BRIDGE_PIDFILE"

launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.localdev.bridge.plist" >/dev/null 2>&1 || true

echo "[OK] Codex Bridge services stopped."
