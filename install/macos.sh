#!/bin/bash
set -euo pipefail

OWNER="baochipham942-eng"
REPO="codex-bridge"
BRANCH="${CODEX_BRIDGE_BRANCH:-main}"
PROJECT_ROOT="${1:-${CODEX_BRIDGE_PROJECT_ROOT:-$HOME/Projects}}"
INSTALL_DIR="${CODEX_BRIDGE_INSTALL_DIR:-$HOME/Downloads/codex-bridge}"
ARCHIVE_URL="https://github.com/$OWNER/$REPO/archive/refs/heads/$BRANCH.zip"

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

command -v curl >/dev/null 2>&1 || fail "curl is missing."
command -v unzip >/dev/null 2>&1 || fail "unzip is missing."

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

ZIP_PATH="$TMPDIR/codex-bridge.zip"

info "Downloading Codex Bridge from GitHub."
curl -fsSL "$ARCHIVE_URL" -o "$ZIP_PATH"
unzip -q "$ZIP_PATH" -d "$TMPDIR"

EXTRACTED_DIR="$(find "$TMPDIR" -maxdepth 1 -type d -name "$REPO-*" | head -n1)"
if [ -z "$EXTRACTED_DIR" ] || [ ! -d "$EXTRACTED_DIR" ]; then
  fail "Downloaded archive did not contain Codex Bridge source."
fi

mkdir -p "$(dirname "$INSTALL_DIR")"
if [ -e "$INSTALL_DIR" ]; then
  BACKUP_DIR="$INSTALL_DIR.backup.$(date +%Y%m%d%H%M%S)"
  info "Existing install found. Moving it to $BACKUP_DIR"
  mv "$INSTALL_DIR" "$BACKUP_DIR"
fi

mv "$EXTRACTED_DIR" "$INSTALL_DIR"
ok "Installed source to $INSTALL_DIR"

bash "$INSTALL_DIR/scripts/bootstrap-macos.sh" "$PROJECT_ROOT"

cat <<EOF

[OK] Codex Bridge is ready.

Daily start commands:
  cd "$INSTALL_DIR" && bash scripts/start-local.sh
  cd "$INSTALL_DIR" && bash scripts/start-cloudflare.sh

Setup guide:
  $INSTALL_DIR/docs/setup.html
EOF
