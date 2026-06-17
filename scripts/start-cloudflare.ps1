param(
  [int]$Port = $(if ($env:CODEX_BRIDGE_PORT) { [int]$env:CODEX_BRIDGE_PORT } elseif ($env:LOCAL_DEV_BRIDGE_PORT) { [int]$env:LOCAL_DEV_BRIDGE_PORT } else { 3848 })
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$DataDir = if ($env:CODEX_BRIDGE_DATA_DIR) { $env:CODEX_BRIDGE_DATA_DIR } elseif ($env:LOCAL_DEV_BRIDGE_DATA_DIR) { $env:LOCAL_DEV_BRIDGE_DATA_DIR } else { Join-Path $env:USERPROFILE ".codex-bridge" }
$LogDir = if ($env:CODEX_BRIDGE_LOG_DIR) { $env:CODEX_BRIDGE_LOG_DIR } elseif ($env:LOCAL_DEV_BRIDGE_LOG_DIR) { $env:LOCAL_DEV_BRIDGE_LOG_DIR } else { Join-Path $DataDir "logs" }
$PidFile = if ($env:CODEX_BRIDGE_CLOUDFLARED_PID_FILE) { $env:CODEX_BRIDGE_CLOUDFLARED_PID_FILE } elseif ($env:LOCAL_DEV_BRIDGE_CLOUDFLARED_PID_FILE) { $env:LOCAL_DEV_BRIDGE_CLOUDFLARED_PID_FILE } else { Join-Path $DataDir "cloudflared.pid" }
$UrlFile = if ($env:CODEX_BRIDGE_URL_FILE) { $env:CODEX_BRIDGE_URL_FILE } elseif ($env:LOCAL_DEV_BRIDGE_URL_FILE) { $env:LOCAL_DEV_BRIDGE_URL_FILE } else { Join-Path $DataDir "mcp-url.txt" }
$OutLog = Join-Path $LogDir "cloudflared.out.log"
$ErrLog = Join-Path $LogDir "cloudflared.err.log"

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

if (-not (Get-Command cloudflared -ErrorAction SilentlyContinue)) {
  Fail "cloudflared is not installed. Run: powershell -ExecutionPolicy Bypass -File scripts\bootstrap-windows.ps1"
}

if (-not (Test-Healthy)) {
  Info "Local bridge is not running. Starting it first."
  & "$Root\scripts\start-local.ps1" -Port $Port
}

if (Test-Path $PidFile) {
  $OldPid = (Get-Content $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
  if ($OldPid -and (Get-Process -Id $OldPid -ErrorAction SilentlyContinue)) {
    if (Test-Path $UrlFile) {
      Ok "Cloudflare tunnel is already running."
      Write-Host "MCP URL: $(Get-Content $UrlFile)"
      Write-Host "Use this URL in ChatGPT Web."
      exit 0
    }
    Info "Found an old cloudflared process without a saved URL. Restarting it."
    Stop-Process -Id $OldPid -Force -ErrorAction SilentlyContinue
  }
}

"" | Set-Content -Encoding UTF8 $OutLog
"" | Set-Content -Encoding UTF8 $ErrLog
$Proc = Start-Process -FilePath "cloudflared" -ArgumentList @("tunnel", "--protocol", "http2", "--url", "http://127.0.0.1:$Port") -RedirectStandardOutput $OutLog -RedirectStandardError $ErrLog -WindowStyle Hidden -PassThru
$Proc.Id | Set-Content -Encoding ASCII $PidFile

for ($i = 0; $i -lt 90; $i++) {
  $Combined = ""
  if (Test-Path $OutLog) { $Combined += Get-Content $OutLog -Raw -ErrorAction SilentlyContinue }
  if (Test-Path $ErrLog) { $Combined += "`n" + (Get-Content $ErrLog -Raw -ErrorAction SilentlyContinue) }
  $Match = [regex]::Match($Combined, "https://[-a-zA-Z0-9]+\.trycloudflare\.com")
  if ($Match.Success) {
    $McpUrl = "$($Match.Value)/mcp"
    $McpUrl | Set-Content -Encoding ASCII $UrlFile
    Ok "Cloudflare tunnel started."
    Write-Host "MCP URL: $McpUrl"
    Write-Host "Use this URL in ChatGPT Web."
    Write-Host "Logs: $OutLog ; $ErrLog"
    exit 0
  }
  if (-not (Get-Process -Id $Proc.Id -ErrorAction SilentlyContinue)) {
    Write-Host "[FAIL] cloudflared exited early. Logs:" -ForegroundColor Red
    if (Test-Path $OutLog) { Get-Content $OutLog }
    if (Test-Path $ErrLog) { Get-Content $ErrLog }
    exit 1
  }
  Start-Sleep -Milliseconds 500
}

Write-Host "[FAIL] Could not find trycloudflare URL in cloudflared output. Logs:" -ForegroundColor Red
if (Test-Path $OutLog) { Get-Content $OutLog }
if (Test-Path $ErrLog) { Get-Content $ErrLog }
exit 1
