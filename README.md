# Codex Bridge

Codex Bridge lets ChatGPT Web use a small set of local development tools through MCP: inspect a project, search and read files, patch or write safe files, run tests, inspect diffs, manage a tracked change session, and check local processes.

For guided configuration, open the hosted setup guide:

```text
https://codex-bridge.vercel.app/
```

Or open this local file in a browser after cloning:

```text
docs/setup.html
```

GitHub repository:

```text
https://github.com/baochipham942-eng/codex-bridge
```

## Supported Computers

- macOS on Apple Silicon
- macOS on Intel
- Windows 10/11

## Fast Setup On macOS

```bash
curl -fsSL https://raw.githubusercontent.com/baochipham942-eng/codex-bridge/main/install/macos.sh | bash -s -- "$HOME/Projects"
cd "$HOME/Downloads/codex-bridge"
bash scripts/start-local.sh
bash scripts/start-cloudflare.sh
```

## Fast Setup On Windows

Open Windows PowerShell:

```powershell
irm https://raw.githubusercontent.com/baochipham942-eng/codex-bridge/main/install/windows.ps1 | iex
cd "$HOME\Downloads\codex-bridge"
powershell -ExecutionPolicy Bypass -File scripts\start-local.ps1
powershell -ExecutionPolicy Bypass -File scripts\start-cloudflare.ps1
```

The tunnel script prints the URL to paste into ChatGPT Web:

```text
https://xxxx.trycloudflare.com/mcp
```

## Daily Commands On macOS

```bash
bash scripts/start-local.sh        # start local MCP service
bash scripts/start-cloudflare.sh   # expose it to ChatGPT Web
bash scripts/doctor.sh             # diagnose setup and connection issues
bash scripts/stop-local.sh         # stop local service and tunnel
```

## Daily Commands On Windows

```powershell
powershell -ExecutionPolicy Bypass -File scripts\start-local.ps1
powershell -ExecutionPolicy Bypass -File scripts\start-cloudflare.ps1
powershell -ExecutionPolicy Bypass -File scripts\doctor.ps1
powershell -ExecutionPolicy Bypass -File scripts\stop-local.ps1
```

## Policy

Each user should have a local policy file:

```text
bridge.policy.local.json
```

Generate it with:

```bash
bash scripts/bootstrap-macos.sh "/path/to/allowed/project/root"
```

or on Windows:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\bootstrap-windows.ps1 -ProjectRoot "C:\path\to\allowed\project\root"
```

Bootstrap checks Node.js 20+, cloudflared, and Git. Default protections deny `.env`, private keys, `.npmrc`, `.netrc`, `.ssh`, and dangerous shell command patterns.

## Tools Exposed To ChatGPT

- `bridge.status`
- `workspace.inspect`
- `code.search`
- `code.read`
- `file.patch`
- `file.write`
- `test.run`
- `git.diff`
- `change.start`
- `change.note`
- `change.finish`
- `process.start`
- `process.list`
- `process.stop`
- `port.check`

Broad shell access is not exposed as a standalone MCP tool.

## Build And Test

```bash
npm install
npm run typecheck
npm test
```

`npm test` builds the project and runs an MCP smoke test covering handshake, tool listing, workspace inspect, read, patch, test, diff, change finish, and policy denial.

## Packaging For Distribution

Send the source package without local runtime artifacts:

```bash
zip -r codex-bridge.zip codex-bridge \
  -x 'codex-bridge/node_modules/*' \
     'codex-bridge/dist/*' \
     'codex-bridge/bridge.policy.local.json' \
     'codex-bridge/logs/*'
```

On Windows, create the archive from the parent folder:

```powershell
tar -a -c -f codex-bridge.zip --exclude codex-bridge/node_modules --exclude codex-bridge/dist --exclude codex-bridge/bridge.policy.local.json --exclude codex-bridge/logs codex-bridge
```

Do not include local `bridge.policy.local.json`, `node_modules`, `dist`, or logs in the shared archive.
