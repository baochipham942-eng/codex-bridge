$ErrorActionPreference = "Stop"

$Owner = "baochipham942-eng"
$Repo = "codex-bridge"
$Branch = if ($env:CODEX_BRIDGE_BRANCH) { $env:CODEX_BRIDGE_BRANCH } else { "main" }
$ProjectRoot = if ($env:CODEX_BRIDGE_PROJECT_ROOT) { $env:CODEX_BRIDGE_PROJECT_ROOT } else { Join-Path $HOME "Projects" }
$InstallDir = if ($env:CODEX_BRIDGE_INSTALL_DIR) { $env:CODEX_BRIDGE_INSTALL_DIR } else { Join-Path (Join-Path $HOME "Downloads") "codex-bridge" }
$ArchiveUrl = "https://github.com/$Owner/$Repo/archive/refs/heads/$Branch.zip"

function Info($Message) { Write-Host "[INFO] $Message" }
function Ok($Message) { Write-Host "[OK] $Message" -ForegroundColor Green }
function Fail($Message) { Write-Host "[FAIL] $Message" -ForegroundColor Red; exit 1 }

$TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-bridge-install-" + [System.Guid]::NewGuid().ToString("N"))
$ZipPath = Join-Path $TempDir "codex-bridge.zip"

try {
  New-Item -ItemType Directory -Force -Path $TempDir | Out-Null

  Info "Downloading Codex Bridge from GitHub."
  Invoke-WebRequest -UseBasicParsing -Uri $ArchiveUrl -OutFile $ZipPath
  Expand-Archive -Path $ZipPath -DestinationPath $TempDir -Force

  $ExtractedDir = Get-ChildItem -Path $TempDir -Directory | Where-Object { $_.Name -like "$Repo-*" } | Select-Object -First 1
  if (-not $ExtractedDir) {
    Fail "Downloaded archive did not contain Codex Bridge source."
  }

  $InstallParent = Split-Path -Parent $InstallDir
  New-Item -ItemType Directory -Force -Path $InstallParent | Out-Null

  if (Test-Path $InstallDir) {
    $BackupDir = "$InstallDir.backup.$(Get-Date -Format 'yyyyMMddHHmmss')"
    Info "Existing install found. Moving it to $BackupDir"
    Move-Item -Path $InstallDir -Destination $BackupDir
  }

  Move-Item -Path $ExtractedDir.FullName -Destination $InstallDir
  Ok "Installed source to $InstallDir"

  powershell -ExecutionPolicy Bypass -File (Join-Path $InstallDir "scripts\bootstrap-windows.ps1") -ProjectRoot $ProjectRoot

  Write-Host ""
  Ok "Codex Bridge is ready."
  Write-Host ""
  Write-Host "Daily start commands:"
  Write-Host "  cd `"$InstallDir`"; powershell -ExecutionPolicy Bypass -File scripts\start-local.ps1"
  Write-Host "  cd `"$InstallDir`"; powershell -ExecutionPolicy Bypass -File scripts\start-cloudflare.ps1"
  Write-Host ""
  Write-Host "Setup guide:"
  Write-Host "  $InstallDir\docs\setup.html"
} finally {
  if (Test-Path $TempDir) {
    Remove-Item -Recurse -Force $TempDir -ErrorAction SilentlyContinue
  }
}
