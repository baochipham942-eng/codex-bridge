$ErrorActionPreference = "Continue"
$DataDir = if ($env:CODEX_BRIDGE_DATA_DIR) { $env:CODEX_BRIDGE_DATA_DIR } elseif ($env:LOCAL_DEV_BRIDGE_DATA_DIR) { $env:LOCAL_DEV_BRIDGE_DATA_DIR } else { Join-Path $env:USERPROFILE ".codex-bridge" }
$BridgePidFile = if ($env:CODEX_BRIDGE_PID_FILE) { $env:CODEX_BRIDGE_PID_FILE } elseif ($env:LOCAL_DEV_BRIDGE_PID_FILE) { $env:LOCAL_DEV_BRIDGE_PID_FILE } else { Join-Path $DataDir "codex-bridge.pid" }
$CloudflaredPidFile = if ($env:CODEX_BRIDGE_CLOUDFLARED_PID_FILE) { $env:CODEX_BRIDGE_CLOUDFLARED_PID_FILE } elseif ($env:LOCAL_DEV_BRIDGE_CLOUDFLARED_PID_FILE) { $env:LOCAL_DEV_BRIDGE_CLOUDFLARED_PID_FILE } else { Join-Path $DataDir "cloudflared.pid" }

function Stop-PidFile($Name, $PidFile) {
  if (-not (Test-Path $PidFile)) {
    Write-Host "[INFO] $Name pid file not found."
    return
  }
  $PidValue = (Get-Content $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
  if (-not $PidValue) {
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
    Write-Host "[INFO] $Name pid file was empty."
    return
  }
  $Proc = Get-Process -Id $PidValue -ErrorAction SilentlyContinue
  if ($Proc) {
    Stop-Process -Id $PidValue -Force -ErrorAction SilentlyContinue
    Write-Host "[OK] Stopped $Name pid=$PidValue" -ForegroundColor Green
  } else {
    Write-Host "[INFO] $Name was not running."
  }
  Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
}

Stop-PidFile "cloudflared tunnel" $CloudflaredPidFile
Stop-PidFile "local bridge" $BridgePidFile
Write-Host "[OK] Codex Bridge services stopped." -ForegroundColor Green
