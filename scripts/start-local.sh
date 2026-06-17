#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${CODEX_BRIDGE_PORT:-${LOCAL_DEV_BRIDGE_PORT:-3848}}"
DATADIR="${CODEX_BRIDGE_DATA_DIR:-${LOCAL_DEV_BRIDGE_DATA_DIR:-$HOME/.codex-bridge}}"
LOGDIR="${CODEX_BRIDGE_LOG_DIR:-${LOCAL_DEV_BRIDGE_LOG_DIR:-$DATADIR/logs}}"
PIDFILE="${CODEX_BRIDGE_PID_FILE:-${LOCAL_DEV_BRIDGE_PID_FILE:-$DATADIR/codex-bridge.pid}}"
POLICY_PATH="${CODEX_BRIDGE_POLICY_PATH:-${LOCAL_DEV_BRIDGE_POLICY_PATH:-$ROOT/bridge.policy.local.json}}"

mkdir -p "$DATADIR" "$LOGDIR"

if [ ! -f "$POLICY_PATH" ]; then
  if [ -f "$ROOT/bridge.policy.json" ]; then
    POLICY_PATH="$ROOT/bridge.policy.json"
  else
    echo "[FAIL] No policy file found. Run: bash scripts/bootstrap-macos.sh" >&2
    exit 1
  fi
fi

if [ -f "$PIDFILE" ]; then
  OLD_PID="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [ -n "${OLD_PID:-}" ] && kill -0 "$OLD_PID" >/dev/null 2>&1; then
    echo "[OK] Codex Bridge is already running."
    echo "PID: $OLD_PID"
    echo "Local MCP URL: http://127.0.0.1:$PORT/mcp"
    exit 0
  fi
fi

cd "$ROOT"
if [ ! -f "$ROOT/dist/index.js" ]; then
  echo "[INFO] dist/index.js is missing. Building first."
  npm run build
fi

if command -v lsof >/dev/null 2>&1 && lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "[FAIL] Port $PORT is already in use. Run scripts/doctor.sh to inspect it, or set CODEX_BRIDGE_PORT." >&2
  exit 1
fi

LOGFILE="$LOGDIR/codex-bridge.log"
CODEX_BRIDGE_PORT="$PORT" \
CODEX_BRIDGE_DATA_DIR="$DATADIR" \
CODEX_BRIDGE_LOG_DIR="$LOGDIR" \
CODEX_BRIDGE_POLICY_PATH="$POLICY_PATH" \
  nohup node dist/index.js --http "$PORT" >"$LOGFILE" 2>&1 &
PID="$!"
echo "$PID" > "$PIDFILE"

for _ in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
    echo "[OK] Codex Bridge started."
    echo "PID: $PID"
    echo "Local MCP URL: http://127.0.0.1:$PORT/mcp"
    echo "Health: http://127.0.0.1:$PORT/health"
    echo "Log: $LOGFILE"
    exit 0
  fi
  sleep 0.5
done

echo "[FAIL] Codex Bridge did not become healthy. Log:" >&2
tail -n 80 "$LOGFILE" >&2 || true
exit 1
