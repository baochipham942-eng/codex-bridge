#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${CODEX_BRIDGE_PORT:-${LOCAL_DEV_BRIDGE_PORT:-3848}}"
DATADIR="${CODEX_BRIDGE_DATA_DIR:-${LOCAL_DEV_BRIDGE_DATA_DIR:-$HOME/.codex-bridge}}"
LOGDIR="${CODEX_BRIDGE_LOG_DIR:-${LOCAL_DEV_BRIDGE_LOG_DIR:-$DATADIR/logs}}"
PIDFILE="${CODEX_BRIDGE_CLOUDFLARED_PID_FILE:-${LOCAL_DEV_BRIDGE_CLOUDFLARED_PID_FILE:-$DATADIR/cloudflared.pid}}"
URLFILE="${CODEX_BRIDGE_URL_FILE:-${LOCAL_DEV_BRIDGE_URL_FILE:-$DATADIR/mcp-url.txt}}"
LOGFILE="$LOGDIR/cloudflared.log"

mkdir -p "$DATADIR" "$LOGDIR"

if ! command -v cloudflared >/dev/null 2>&1; then
  echo "[FAIL] cloudflared is not installed. Run: bash scripts/bootstrap-macos.sh" >&2
  exit 1
fi

if ! curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
  echo "[INFO] Local bridge is not running. Starting it first."
  bash "$ROOT/scripts/start-local.sh"
fi

if [ -f "$PIDFILE" ]; then
  OLD_PID="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [ -n "${OLD_PID:-}" ] && kill -0 "$OLD_PID" >/dev/null 2>&1; then
    if [ -f "$URLFILE" ]; then
      echo "[OK] Cloudflare tunnel is already running."
      echo "MCP URL: $(cat "$URLFILE")"
      echo "Use this URL in ChatGPT Web."
      exit 0
    fi
    echo "[INFO] Found an old cloudflared process without a saved URL. Restarting it."
    kill "$OLD_PID" >/dev/null 2>&1 || true
  fi
fi

: > "$LOGFILE"
cloudflared tunnel --protocol http2 --url "http://127.0.0.1:$PORT" >"$LOGFILE" 2>&1 &
PID="$!"
echo "$PID" > "$PIDFILE"

URL=""
for _ in $(seq 1 60); do
  URL="$(grep -Eo 'https://[-a-zA-Z0-9]+\.trycloudflare\.com' "$LOGFILE" | tail -n1 || true)"
  if [ -n "$URL" ]; then
    MCP_URL="$URL/mcp"
    echo "$MCP_URL" > "$URLFILE"
    echo "[OK] Cloudflare tunnel started."
    echo "MCP URL: $MCP_URL"
    echo "Use this URL in ChatGPT Web."
    echo "Log: $LOGFILE"
    exit 0
  fi
  if ! kill -0 "$PID" >/dev/null 2>&1; then
    echo "[FAIL] cloudflared exited early. Log:" >&2
    cat "$LOGFILE" >&2
    exit 1
  fi
  sleep 0.5
done

echo "[FAIL] Could not find trycloudflare URL in cloudflared output. Log:" >&2
cat "$LOGFILE" >&2
exit 1
