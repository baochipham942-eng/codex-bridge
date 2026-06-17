#!/bin/bash
# Smoke-test the Codex Bridge MCP server over stdio.

set -euo pipefail
cd "$(dirname "$0")/.."

TMPROOT=$(mktemp -d)
TESTPROJ="$TMPROOT/test-project"
LOGDIR="$TMPROOT/logs"
POLICY="$TMPROOT/bridge.policy.json"
DATADIR="$TMPROOT/data"

cleanup() {
  rm -rf "$TMPROOT"
}
trap cleanup EXIT

mkdir -p "$TESTPROJ" "$LOGDIR" "$DATADIR"
cat > "$POLICY" <<JSON
{
  "allowedProjectRoots": ["$TMPROOT"],
  "denyGlobs": ["**/.env", "**/.env.*", "**/*.pem", "**/*.key", "**/.ssh/**"],
  "shell": {
    "enabled": true,
    "denyPatterns": [
      "sudo",
      "rm\\\\s+-rf\\\\s+/",
      "rm\\\\s+-rf\\\\s+~",
      "rm\\\\s+-rf\\\\s+\\\\$HOME",
      "chmod\\\\s+-R",
      "chown\\\\s+-R",
      "security\\\\s+find-",
      "curl\\\\s+[^|;]*\\\\|\\\\s*(sh|bash|zsh)",
      "wget\\\\s+[^|;]*\\\\|\\\\s*(sh|bash|zsh)"
    ]
  }
}
JSON

cd "$TESTPROJ"
git init -q
git config user.email test@example.com
git config user.name test
cat > package.json <<'JSON'
{
  "type": "module",
  "scripts": {
    "test": "node test.js",
    "typecheck": "node -e \"console.log('typecheck ok')\""
  }
}
JSON
cat > math.js <<'JS'
export function add(a, b) {
  return a + b;
}
JS
cat > test.js <<'JS'
import { add } from './math.js';
if (add('2', 3) !== 5) throw new Error('add failed');
console.log('test ok');
JS
git add . && git commit -q -m "init"
cd - > /dev/null

call_tool() {
  local name="$1"
  local args="$2"
  printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0.1.0"}}}\n{"jsonrpc":"2.0","method":"notifications/initialized"}\n{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"%s","arguments":%s}}\n' "$name" "$args" \
    | CODEX_WEB_DATA_DIR="$DATADIR" CODEX_WEB_LOG_DIR="$LOGDIR" CODEX_WEB_POLICY_PATH="$POLICY" node dist/index.js 2>/dev/null
}

echo "== tools/list =="
printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0.1.0"}}}\n{"jsonrpc":"2.0","method":"notifications/initialized"}\n{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}\n' \
  | CODEX_WEB_DATA_DIR="$DATADIR" CODEX_WEB_LOG_DIR="$LOGDIR" CODEX_WEB_POLICY_PATH="$POLICY" node dist/index.js 2>/dev/null \
  | python3 -c "
import json, sys
expected = {
  'bridge.status', 'workspace.inspect', 'code.search', 'code.read',
  'file.patch', 'file.write', 'test.run', 'git.diff',
  'change.start', 'change.note', 'change.finish',
  'process.start', 'process.list', 'process.stop', 'port.check'
}
for line in sys.stdin:
    msg = json.loads(line)
    if msg.get('id') == 1:
        si = msg['result']['serverInfo']
        assert si['name'] == 'codex-bridge'
        print(f\"server={si['name']} version={si['version']}\")
    if msg.get('id') == 2:
        tools = {tool['name'] for tool in msg['result']['tools']}
        missing = expected - tools
        extra_old = {'shell.exec', 'codex_app_start', 'workspace.add', 'task.start', 'project.snapshot'} & tools
        assert not missing, f'missing: {missing}'
        assert not extra_old, f'old/high-risk tools still exposed: {extra_old}'
        print('tools=' + ', '.join(sorted(tools)))
"

echo "== inspect/read/patch/test/diff/change =="
CHANGE_ID=$(call_tool "change.start" "{\"projectPath\":\"$TESTPROJ\",\"title\":\"smoke change\",\"note\":\"start\"}" \
  | python3 -c "
import json, sys
for line in sys.stdin:
    msg = json.loads(line)
    if msg.get('id') == 2:
        print(msg['result']['structuredContent']['id'])
")

call_tool "workspace.inspect" "{\"projectPath\":\"$TESTPROJ\",\"maxDepth\":3,\"maxFiles\":80}" \
  | python3 -c "
import json, sys
for line in sys.stdin:
    msg = json.loads(line)
    if msg.get('id') == 2:
        sc = msg['result']['structuredContent']
        print(f\"inspect files={sc['totalFiles']} scripts={len(sc['scripts'])} tests={len(sc['testCommands'])}\")
        assert sc['isGitRepo'] is True
        assert any(t['command'] == 'npm test' for t in sc['testCommands'])
"

call_tool "code.read" "{\"projectPath\":\"$TESTPROJ\",\"files\":[{\"path\":\"math.js\"}],\"maxLinesPerFile\":20}" \
  | python3 -c "
import json, sys
for line in sys.stdin:
    msg = json.loads(line)
    if msg.get('id') == 2:
        content = msg['result']['structuredContent']['files'][0]['content']
        print(content)
        assert 'return a + b' in content
"

call_tool "file.patch" "{\"projectPath\":\"$TESTPROJ\",\"file\":\"math.js\",\"oldText\":\"  return a + b;\",\"newText\":\"  return Number(a) + Number(b);\"}" \
  | python3 -c "
import json, sys
for line in sys.stdin:
    msg = json.loads(line)
    if msg.get('id') == 2:
        sc = msg['result']['structuredContent']
        print(f\"patched replacements={sc['replacements']} changed={len(sc['changedFiles'])}\")
        assert sc['replacements'] == 1
"

call_tool "test.run" "{\"projectPath\":\"$TESTPROJ\"}" \
  | python3 -c "
import json, sys
for line in sys.stdin:
    msg = json.loads(line)
    if msg.get('id') == 2:
        sc = msg['result']['structuredContent']
        print(f\"test exit={sc['exitCode']} stdout={sc['stdout'].strip()}\")
        assert sc['exitCode'] == 0
        assert 'test ok' in sc['stdout']
"

call_tool "git.diff" "{\"projectPath\":\"$TESTPROJ\"}" \
  | python3 -c "
import json, sys
for line in sys.stdin:
    msg = json.loads(line)
    if msg.get('id') == 2:
        sc = msg['result']['structuredContent']
        print(f\"diff files={sc['stats']['files']} insertions={sc['stats']['insertions']} deletions={sc['stats']['deletions']}\")
        assert sc['stats']['files'] == 1
        assert 'Number(a)' in sc['patch']
"

call_tool "change.finish" "{\"changeId\":\"$CHANGE_ID\",\"status\":\"done\",\"note\":\"finish\",\"runTests\":true}" \
  | python3 -c "
import json, sys
for line in sys.stdin:
    msg = json.loads(line)
    if msg.get('id') == 2:
        sc = msg['result']['structuredContent']
        print(f\"finish status={sc['status']} verification={sc['verification']['status']}\")
        assert sc['status'] == 'done'
        assert sc['verification']['status'] == 'passed'
"

echo "== policy denial =="
printf 'SECRET=1\n' > "$TESTPROJ/.env"
set +e
DENIED=$(call_tool "code.read" "{\"projectPath\":\"$TESTPROJ\",\"files\":[{\"path\":\".env\"}]}" 2>/dev/null)
set -e
python3 - "$DENIED" <<'PY'
import json, sys
payload = sys.argv[1]
assert payload, 'expected MCP error payload'
found = False
for line in payload.splitlines():
    msg = json.loads(line)
    if msg.get('id') == 2:
        result = msg.get('result', {})
        text = '\n'.join(item.get('text', '') for item in result.get('content', []))
        found = result.get('isError') is True and 'Access denied' in text
        print('denied=' + text)
assert found
PY

echo "== bridge.status =="
call_tool "bridge.status" "{}" \
  | python3 -c "
import json, sys
for line in sys.stdin:
    msg = json.loads(line)
    if msg.get('id') == 2:
        sc = msg['result']['structuredContent']
        print(f\"status service={sc['service']} changes={sc['changeCount']} processes={sc['processCount']}\")
        assert sc['service'] == 'codex-bridge'
"

echo "Codex Bridge MCP smoke passed."
