param(
  [int]$Port = $(if ($env:CODEX_BRIDGE_PORT) { [int]$env:CODEX_BRIDGE_PORT } elseif ($env:LOCAL_DEV_BRIDGE_PORT) { [int]$env:LOCAL_DEV_BRIDGE_PORT } else { 3848 })
)

$ErrorActionPreference = "Continue"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$DataDir = if ($env:CODEX_BRIDGE_DATA_DIR) { $env:CODEX_BRIDGE_DATA_DIR } elseif ($env:LOCAL_DEV_BRIDGE_DATA_DIR) { $env:LOCAL_DEV_BRIDGE_DATA_DIR } else { Join-Path $env:USERPROFILE ".codex-bridge" }
$LogDir = if ($env:CODEX_BRIDGE_LOG_DIR) { $env:CODEX_BRIDGE_LOG_DIR } elseif ($env:LOCAL_DEV_BRIDGE_LOG_DIR) { $env:LOCAL_DEV_BRIDGE_LOG_DIR } else { Join-Path $DataDir "logs" }
$PolicyPath = if ($env:CODEX_BRIDGE_POLICY_PATH) { $env:CODEX_BRIDGE_POLICY_PATH } elseif ($env:LOCAL_DEV_BRIDGE_POLICY_PATH) { $env:LOCAL_DEV_BRIDGE_POLICY_PATH } else { Join-Path $Root "bridge.policy.local.json" }
$UrlFile = if ($env:CODEX_BRIDGE_URL_FILE) { $env:CODEX_BRIDGE_URL_FILE } elseif ($env:LOCAL_DEV_BRIDGE_URL_FILE) { $env:LOCAL_DEV_BRIDGE_URL_FILE } else { Join-Path $DataDir "mcp-url.txt" }
$Failures = 0

function Pass($Message) { Write-Host "[OK] $Message" -ForegroundColor Green }
function Warn($Message) { Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Fail($Message) { Write-Host "[FAIL] $Message" -ForegroundColor Red; $script:Failures++ }
function Section($Message) { Write-Host ""; Write-Host $Message }
function Test-VersionAtLeast($Current, $Minimum) {
  try { return ([version]$Current) -ge ([version]$Minimum) } catch { return $false }
}

Section "System"
if ($IsWindows -or $env:OS -eq "Windows_NT") { Pass "Windows" } else { Warn "This doctor script is for Windows PowerShell." }

if (Get-Command node -ErrorAction SilentlyContinue) {
  $NodeVersion = (& node -p "process.versions.node").Trim()
  if (Test-VersionAtLeast $NodeVersion "20.0.0") { Pass "Node.js $NodeVersion" } else { Fail "Node.js $NodeVersion is too old. Need 20+." }
} else {
  Fail "Node.js is missing."
}

if (Get-Command npm -ErrorAction SilentlyContinue) { Pass "npm $((& npm -v).Trim())" } else { Fail "npm is missing." }
if (Get-Command cloudflared -ErrorAction SilentlyContinue) { Pass ((& cloudflared --version | Select-Object -First 1).Trim()) } else { Warn "cloudflared is missing. ChatGPT Web cannot connect until tunnel is installed." }
if (Get-Command git -ErrorAction SilentlyContinue) { Pass ((& git --version).Trim()) } else { Warn "git is missing. Diff and change-session verification need Git." }

Section "Project"
if (Test-Path (Join-Path $Root "package.json")) { Pass "package.json found" } else { Fail "package.json missing" }
if (Test-Path (Join-Path $Root "node_modules")) { Pass "node_modules installed" } else { Warn "node_modules missing. Run: npm install" }
if (Test-Path (Join-Path $Root "dist\index.js")) { Pass "dist\index.js built" } else { Warn "dist\index.js missing. Run: npm run build" }

if (Test-Path $PolicyPath) {
  Pass "policy file: $PolicyPath"
  try {
    $Policy = Get-Content $PolicyPath -Raw | ConvertFrom-Json
    if ($Policy.allowedProjectRoots.Count -gt 0) {
      Pass "allowed roots: $($Policy.allowedProjectRoots -join ', ')"
    } else {
      Fail "allowedProjectRoots is empty."
    }
  } catch {
    Fail "policy file cannot be parsed."
  }
} else {
  Warn "local policy missing. Run: powershell -ExecutionPolicy Bypass -File scripts\bootstrap-windows.ps1"
}

Section "Local service"
try {
  $Health = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 3
  Pass "health endpoint: http://127.0.0.1:$Port/health"
  Write-Host $Health.Content
} catch {
  Fail "local bridge is not healthy on port $Port. Run: powershell -ExecutionPolicy Bypass -File scripts\start-local.ps1"
}

$Listening = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($Listening) { Pass "port $Port is listening" } else { Warn "port $Port is not listening" }

Section "MCP tools"
try {
  $Body = '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}'
  $ToolsResponse = Invoke-WebRequest -UseBasicParsing -Method Post -Uri "http://127.0.0.1:$Port/mcp" -ContentType "application/json" -Headers @{ Accept = "application/json, text/event-stream" } -Body $Body -TimeoutSec 5
  $Line = ($ToolsResponse.Content -split "`n" | Where-Object { $_.StartsWith("data: ") } | Select-Object -First 1)
  if (-not $Line) { throw "no SSE data line" }
  $Msg = $Line.Substring(6) | ConvertFrom-Json
  $Names = @($Msg.result.tools | ForEach-Object { $_.name })
  foreach ($Expected in @("workspace.inspect", "code.read", "file.patch", "test.run", "change.finish")) {
    if ($Names -notcontains $Expected) { throw "missing $Expected" }
  }
  Pass "tools/list returned $($Names.Count) tools"
  Write-Host ($Names -join ", ")
} catch {
  Fail "tools/list failed. Local service may not be running."
}

Section "Tunnel"
if (Test-Path $UrlFile) {
  Pass "last MCP URL: $(Get-Content $UrlFile)"
} else {
  Warn "no tunnel URL saved yet. Run: powershell -ExecutionPolicy Bypass -File scripts\start-cloudflare.ps1"
}

if (Test-Path (Join-Path $LogDir "codex-bridge.out.log")) { Pass "local stdout log: $(Join-Path $LogDir "codex-bridge.out.log")" }
if (Test-Path (Join-Path $LogDir "codex-bridge.err.log")) { Pass "local stderr log: $(Join-Path $LogDir "codex-bridge.err.log")" }
if (Test-Path (Join-Path $LogDir "cloudflared.out.log")) { Pass "cloudflared stdout log: $(Join-Path $LogDir "cloudflared.out.log")" }
if (Test-Path (Join-Path $LogDir "cloudflared.err.log")) { Pass "cloudflared stderr log: $(Join-Path $LogDir "cloudflared.err.log")" }

Section "Result"
if ($Failures -eq 0) {
  Pass "Doctor found no blocking issue."
} else {
  Fail "$Failures blocking issue(s) found."
}

exit $Failures
