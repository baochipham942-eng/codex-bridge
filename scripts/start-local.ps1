param(
  [int]$Port = $(if ($env:CODEX_BRIDGE_PORT) { [int]$env:CODEX_BRIDGE_PORT } elseif ($env:LOCAL_DEV_BRIDGE_PORT) { [int]$env:LOCAL_DEV_BRIDGE_PORT } else { 3848 })
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$DataDir = if ($env:CODEX_BRIDGE_DATA_DIR) { $env:CODEX_BRIDGE_DATA_DIR } elseif ($env:LOCAL_DEV_BRIDGE_DATA_DIR) { $env:LOCAL_DEV_BRIDGE_DATA_DIR } else { Join-Path $env:USERPROFILE ".codex-bridge" }
$LogDir = if ($env:CODEX_BRIDGE_LOG_DIR) { $env:CODEX_BRIDGE_LOG_DIR } elseif ($env:LOCAL_DEV_BRIDGE_LOG_DIR) { $env:LOCAL_DEV_BRIDGE_LOG_DIR } else { Join-Path $DataDir "logs" }
$PidFile = if ($env:CODEX_BRIDGE_PID_FILE) { $env:CODEX_BRIDGE_PID_FILE } elseif ($env:LOCAL_DEV_BRIDGE_PID_FILE) { $env:LOCAL_DEV_BRIDGE_PID_FILE } else { Join-Path $DataDir "codex-bridge.pid" }
$PolicyPath = if ($env:CODEX_BRIDGE_POLICY_PATH) { $env:CODEX_BRIDGE_POLICY_PATH } elseif ($env:LOCAL_DEV_BRIDGE_POLICY_PATH) { $env:LOCAL_DEV_BRIDGE_POLICY_PATH } else { Join-Path $Root "bridge.policy.local.json" }

function Ok($Message) { Write-Host "[OK] $Message" -ForegroundColor Green }
function Info($Message) { Write-Host "[INFO] $Message" }
function Fail($Message) { Write-Host "[FAIL] $Message" -ForegroundColor Red; exit 1 }
function Test-Healthy() {
  try {
    Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 2 | Out-Null
    return $true
  } catch {
    return $false
  }
}

New-Item -ItemType Directory -Force -Path $DataDir, $LogDir | Out-Null

if (-not (Test-Path $PolicyPath)) {
  $Fallback = Join-Path $Root "bridge.policy.json"
  if (Test-Path $Fallback) {
    $PolicyPath = $Fallback
  } else {
    Fail "No policy file found. Run: powershell -ExecutionPolicy Bypass -File scripts\bootstrap-windows.ps1"
  }
}

if (Test-Path $PidFile) {
  $OldPid = (Get-Content $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
  if ($OldPid -and (Get-Process -Id $OldPid -ErrorAction SilentlyContinue)) {
    Ok "Codex Bridge is already running."
    Write-Host "PID: $OldPid"
    Write-Host "Local MCP URL: http://127.0.0.1:$Port/mcp"
    exit 0
  }
}

Set-Location $Root
if (-not (Test-Path (Join-Path $Root "dist\index.js"))) {
  Info "dist\index.js is missing. Building first."
  npm run build
}

$Listening = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($Listening) {
  Fail "Port $Port is already in use. Run scripts\doctor.ps1 or set CODEX_BRIDGE_PORT."
}

$OutLog = Join-Path $LogDir "codex-bridge.out.log"
$ErrLog = Join-Path $LogDir "codex-bridge.err.log"
$env:CODEX_BRIDGE_PORT = "$Port"
$env:CODEX_BRIDGE_DATA_DIR = "$DataDir"
$env:CODEX_BRIDGE_LOG_DIR = "$LogDir"
$env:CODEX_BRIDGE_POLICY_PATH = "$PolicyPath"

$Proc = Start-Process -FilePath "node" -ArgumentList @("dist/index.js", "--http", "$Port") -WorkingDirectory $Root -RedirectStandardOutput $OutLog -RedirectStandardError $ErrLog -WindowStyle Hidden -PassThru
$Proc.Id | Set-Content -Encoding ASCII $PidFile

for ($i = 0; $i -lt 30; $i++) {
  if (Test-Healthy) {
    Ok "Codex Bridge started."
    Write-Host "PID: $($Proc.Id)"
    Write-Host "Local MCP URL: http://127.0.0.1:$Port/mcp"
    Write-Host "Health: http://127.0.0.1:$Port/health"
    Write-Host "Logs: $OutLog ; $ErrLog"
    exit 0
  }
  Start-Sleep -Milliseconds 500
}

Write-Host "[FAIL] Codex Bridge did not become healthy." -ForegroundColor Red
if (Test-Path $ErrLog) { Get-Content $ErrLog -Tail 80 }
exit 1
