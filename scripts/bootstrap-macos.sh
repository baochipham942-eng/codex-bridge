#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_ROOT="${1:-${CODEX_BRIDGE_PROJECT_ROOT:-${LOCAL_DEV_BRIDGE_PROJECT_ROOT:-$HOME/Projects}}}"
POLICY_PATH="$ROOT/bridge.policy.local.json"
PORT="${CODEX_BRIDGE_PORT:-${LOCAL_DEV_BRIDGE_PORT:-3848}}"

info() {
  printf '[INFO] %s\n' "$1"
}

ok() {
  printf '[OK] %s\n' "$1"
}

fail() {
  printf '[FAIL] %s\n' "$1" >&2
  exit 1
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

ensure_command() {
  command -v "$1" >/dev/null 2>&1
}

if [ "$(uname -s)" != "Darwin" ]; then
  fail "This bootstrap script is for macOS. Other systems can still run npm install && npm run build manually."
fi

info "Codex Bridge setup"
info "Allowed project folder: $PROJECT_ROOT"

mkdir -p "$PROJECT_ROOT" "$HOME/.codex-bridge/logs"

if ! ensure_command node; then
  if ensure_command brew; then
    info "Node.js is missing. Installing Node with Homebrew."
    brew install node
  else
    fail "Node.js is missing. Install Node 20+ from https://nodejs.org, then run this script again."
  fi
fi

NODE_VERSION="$(node -p "process.versions.node")"
if ! version_ge "$NODE_VERSION" "20.0.0"; then
  fail "Node.js $NODE_VERSION found, but Codex Bridge needs Node 20+. Install a newer Node and run this again."
fi
ok "Node.js $NODE_VERSION"

if ! ensure_command npm; then
  fail "npm is missing even though node exists. Reinstall Node.js 20+."
fi
ok "npm $(npm -v)"

if ! ensure_command cloudflared; then
  if ensure_command brew; then
    info "cloudflared is missing. Installing it with Homebrew so ChatGPT Web can reach your local bridge."
    brew install cloudflared
  else
    info "cloudflared is missing and Homebrew is not installed."
    info "You can still use the local bridge, but ChatGPT Web needs a public tunnel."
    info "Install cloudflared later from https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/"
  fi
fi

if ensure_command cloudflared; then
  ok "cloudflared $(cloudflared --version | head -n1)"
fi

if ! ensure_command git; then
  if ensure_command brew; then
    info "Git is missing. Installing Git with Homebrew."
    brew install git
  else
    fail "Git is missing. Install Git or Xcode Command Line Tools, then run this script again."
  fi
fi
ok "git $(git --version | awk '{print $3}')"

info "Installing project dependencies."
cd "$ROOT"
npm install

info "Building Codex Bridge."
npm run build

node - "$POLICY_PATH" "$PROJECT_ROOT" <<'NODE'
const fs = require('fs');
const [policyPath, projectRoot] = process.argv.slice(2);
const policy = {
  allowedProjectRoots: [projectRoot],
  denyGlobs: [
    '**/.env',
    '**/.env.*',
    '**/*.pem',
    '**/*.key',
    '**/*.p12',
    '**/*.pfx',
    '**/.npmrc',
    '**/.netrc',
    '**/.ssh/**',
    '**/id_rsa',
    '**/id_ed25519',
  ],
  shell: {
    enabled: true,
    denyPatterns: [
      'sudo',
      'rm\\s+-rf\\s+/',
      'rm\\s+-rf\\s+~',
      'rm\\s+-rf\\s+\\$HOME',
      'chmod\\s+-R',
      'chown\\s+-R',
      'security\\s+find-',
      'launchctl\\s+bootout\\s+system',
      'curl\\s+[^|;]*\\|\\s*(sh|bash|zsh)',
      'wget\\s+[^|;]*\\|\\s*(sh|bash|zsh)',
    ],
  },
};
fs.writeFileSync(policyPath, JSON.stringify(policy, null, 2) + '\n');
NODE
ok "Wrote local policy: $POLICY_PATH"

info "Running MCP smoke test."
CODEX_BRIDGE_POLICY_PATH="$POLICY_PATH" npm run smoke

cat <<EOF

[OK] Setup finished.

Next:
1. Start local service:
   bash scripts/start-local.sh

2. Start ChatGPT Web tunnel:
   bash scripts/start-cloudflare.sh

3. Open the visual setup guide:
   docs/setup.html

Local service URL:
   http://127.0.0.1:$PORT/mcp
EOF
