#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${CODEX_BRIDGE_PORT:-${LOCAL_DEV_BRIDGE_PORT:-3848}}"
DATADIR="${CODEX_BRIDGE_DATA_DIR:-${LOCAL_DEV_BRIDGE_DATA_DIR:-$HOME/.codex-bridge}}"
LOGDIR="${CODEX_BRIDGE_LOG_DIR:-${LOCAL_DEV_BRIDGE_LOG_DIR:-$DATADIR/logs}}"
POLICY_PATH="${CODEX_BRIDGE_POLICY_PATH:-${LOCAL_DEV_BRIDGE_POLICY_PATH:-$ROOT/bridge.policy.local.json}}"
URLFILE="${CODEX_BRIDGE_URL_FILE:-${LOCAL_DEV_BRIDGE_URL_FILE:-$DATADIR/mcp-url.txt}}"
FAILURES=0

pass() {
  printf '[OK] %s\n' "$1"
}

warn() {
  printf '[WARN] %s\n' "$1"
}

fail() {
  printf '[FAIL] %s\n' "$1"
  FAILURES=$((FAILURES + 1))
}

section() {
  printf '\n%s\n' "$1"
}

version_ge() {
  local current="$1"
  local minimum="$2"
  node - "$current" "$minimum" <<'NODE'
const [current, minimum] = process.argv.slice(2);
const parse = (value) => value.split('.').map((part) => Number.parseInt(part, 10) || 0);
const a = parse(current);
const b = parse(minimum);
for (let i = 0; i < Math.max(a.length, b.length); i++) {
  if ((a[i] || 0) > (b[i] || 0)) process.exit(0);
  if ((a[i] || 0) < (b[i] || 0)) process.exit(1);
}
process.exit(0);
NODE
}

section "System"
if [ "$(uname -s)" = "Darwin" ]; then
  pass "macOS"
else
  warn "This script is optimized for macOS."
fi

if command -v node >/dev/null 2>&1; then
  NODE_VERSION="$(node -p "process.versions.node")"
  if version_ge "$NODE_VERSION" "20.0.0"; then
    pass "Node.js $NODE_VERSION"
  else
    fail "Node.js $NODE_VERSION is too old. Need 20+."
  fi
else
  fail "Node.js is missing."
fi

if command -v npm >/dev/null 2>&1; then
  pass "npm $(npm -v)"
else
  fail "npm is missing."
fi

if command -v cloudflared >/dev/null 2>&1; then
  pass "$(cloudflared --version | head -n1)"
else
  warn "cloudflared is missing. ChatGPT Web cannot connect until tunnel is installed."
fi

if command -v git >/dev/null 2>&1; then
  pass "$(git --version)"
else
  warn "git is missing. Diff and change-session verification need Git."
fi

section "Project"
if [ -f "$ROOT/package.json" ]; then
  pass "package.json found"
else
  fail "package.json missing"
fi

if [ -d "$ROOT/node_modules" ]; then
  pass "node_modules installed"
else
  warn "node_modules missing. Run: npm install"
fi

if [ -f "$ROOT/dist/index.js" ]; then
  pass "dist/index.js built"
else
  warn "dist/index.js missing. Run: npm run build"
fi

if [ -f "$POLICY_PATH" ]; then
  pass "policy file: $POLICY_PATH"
  node - "$POLICY_PATH" <<'NODE' || fail "policy file cannot be parsed"
const fs = require('fs');
const policy = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (!Array.isArray(policy.allowedProjectRoots) || policy.allowedProjectRoots.length === 0) {
  throw new Error('allowedProjectRoots is empty');
}
console.log('[OK] allowed roots: ' + policy.allowedProjectRoots.join(', '));
NODE
else
  warn "local policy missing. Run: bash scripts/bootstrap-macos.sh"
fi

section "Local service"
if curl -fsS "http://127.0.0.1:$PORT/health" >/tmp/codex-bridge-health.json 2>/dev/null; then
  pass "health endpoint: http://127.0.0.1:$PORT/health"
  cat /tmp/codex-bridge-health.json
  printf '\n'
else
  fail "local bridge is not healthy on port $PORT. Run: bash scripts/start-local.sh"
fi

if command -v lsof >/dev/null 2>&1; then
  if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/tmp/codex-bridge-port.txt 2>/dev/null; then
    pass "port $PORT is listening"
    sed -n '1,4p' /tmp/codex-bridge-port.txt
  else
    warn "port $PORT is not listening"
  fi
fi

section "MCP tools"
if curl -fsS -X POST "http://127.0.0.1:$PORT/mcp" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  --data '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' >/tmp/codex-bridge-tools.sse 2>/dev/null; then
  node - /tmp/codex-bridge-tools.sse <<'NODE' || fail "tools/list response could not be parsed"
const fs = require('fs');
const raw = fs.readFileSync(process.argv[2], 'utf8');
const line = raw.split(/\n/).find((item) => item.startsWith('data: '));
if (!line) throw new Error('no SSE data line');
const msg = JSON.parse(line.slice(6));
const names = msg.result.tools.map((tool) => tool.name);
for (const expected of ['workspace.inspect', 'code.read', 'file.patch', 'test.run', 'change.finish']) {
  if (!names.includes(expected)) throw new Error(`missing ${expected}`);
}
console.log('[OK] tools/list returned ' + names.length + ' tools');
console.log(names.join(', '));
NODE
else
  fail "tools/list failed. Local service may not be running."
fi

section "Tunnel"
if [ -f "$URLFILE" ]; then
  MCP_URL="$(cat "$URLFILE")"
  pass "last MCP URL: $MCP_URL"
else
  warn "no tunnel URL saved yet. Run: bash scripts/start-cloudflare.sh"
fi

if [ -f "$LOGDIR/codex-bridge.log" ]; then
  pass "local log: $LOGDIR/codex-bridge.log"
fi
if [ -f "$LOGDIR/cloudflared.log" ]; then
  pass "cloudflared log: $LOGDIR/cloudflared.log"
fi

section "Result"
if [ "$FAILURES" -eq 0 ]; then
  pass "Doctor found no blocking issue."
else
  fail "$FAILURES blocking issue(s) found."
fi

exit "$FAILURES"
