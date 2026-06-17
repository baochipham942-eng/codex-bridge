param(
  [string]$ProjectRoot = $(if ($env:CODEX_BRIDGE_PROJECT_ROOT) { $env:CODEX_BRIDGE_PROJECT_ROOT } elseif ($env:LOCAL_DEV_BRIDGE_PROJECT_ROOT) { $env:LOCAL_DEV_BRIDGE_PROJECT_ROOT } else { Join-Path $HOME "Projects" })
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$PolicyPath = Join-Path $Root "bridge.policy.local.json"
$DataDir = if ($env:CODEX_BRIDGE_DATA_DIR) { $env:CODEX_BRIDGE_DATA_DIR } elseif ($env:LOCAL_DEV_BRIDGE_DATA_DIR) { $env:LOCAL_DEV_BRIDGE_DATA_DIR } else { Join-Path $env:USERPROFILE ".codex-bridge" }
$LogDir = if ($env:CODEX_BRIDGE_LOG_DIR) { $env:CODEX_BRIDGE_LOG_DIR } elseif ($env:LOCAL_DEV_BRIDGE_LOG_DIR) { $env:LOCAL_DEV_BRIDGE_LOG_DIR } else { Join-Path $DataDir "logs" }

function Info($Message) { Write-Host "[INFO] $Message" }
function Ok($Message) { Write-Host "[OK] $Message" -ForegroundColor Green }
function Fail($Message) { Write-Host "[FAIL] $Message" -ForegroundColor Red; exit 1 }

function Test-Command($Name) {
  return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Test-VersionAtLeast($Current, $Minimum) {
  try {
    return ([version]$Current) -ge ([version]$Minimum)
  } catch {
    return $false
  }
}

function Install-WithWinget($Id, $Name) {
  if (-not (Test-Command "winget")) {
    Fail "$Name is missing. Install it manually, or install Windows App Installer so winget is available."
  }
  Info "Installing $Name with winget."
  winget install --id $Id --exact --accept-package-agreements --accept-source-agreements
}

Info "Codex Bridge Windows setup"
Info "Allowed project folder: $ProjectRoot"

New-Item -ItemType Directory -Force -Path $ProjectRoot, $LogDir | Out-Null

if (-not (Test-Command "node")) {
  Install-WithWinget "OpenJS.NodeJS.LTS" "Node.js 20+"
  if (-not (Test-Command "node")) {
    Fail "Node.js was installed, but this PowerShell window cannot see it yet. Close PowerShell, open it again, and rerun this script."
  }
}

$NodeVersion = (& node -p "process.versions.node").Trim()
if (-not (Test-VersionAtLeast $NodeVersion "20.0.0")) {
  Fail "Node.js $NodeVersion found, but Codex Bridge needs Node 20+. Install a newer Node and rerun this script."
}
Ok "Node.js $NodeVersion"

if (-not (Test-Command "npm")) {
  Fail "npm is missing even though node exists. Reinstall Node.js 20+."
}
Ok "npm $((& npm -v).Trim())"

if (-not (Test-Command "cloudflared")) {
  Install-WithWinget "Cloudflare.cloudflared" "cloudflared"
  if (-not (Test-Command "cloudflared")) {
    Fail "cloudflared was installed, but this PowerShell window cannot see it yet. Close PowerShell, open it again, and rerun this script."
  }
}
Ok ((& cloudflared --version | Select-Object -First 1).Trim())

if (-not (Test-Command "git")) {
  Install-WithWinget "Git.Git" "Git"
  if (-not (Test-Command "git")) {
    Fail "Git was installed, but this PowerShell window cannot see it yet. Close PowerShell, open it again, and rerun this script."
  }
}
Ok ((& git --version).Trim())

Set-Location $Root
Info "Installing project dependencies."
npm install

Info "Building Codex Bridge."
npm run build

$Policy = [ordered]@{
  allowedProjectRoots = @($ProjectRoot)
  denyGlobs = @(
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
    '**/id_ed25519'
  )
  shell = [ordered]@{
    enabled = $true
    denyPatterns = @(
      'sudo',
      'rm\s+-rf\s+/',
      'rm\s+-rf\s+~',
      'rm\s+-rf\s+\$HOME',
      'chmod\s+-R',
      'chown\s+-R',
      'security\s+find-',
      'launchctl\s+bootout\s+system',
      'curl\s+[^|;]*\|\s*(sh|bash|zsh)',
      'wget\s+[^|;]*\|\s*(sh|bash|zsh)'
    )
  }
}

$Policy | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 $PolicyPath
Ok "Wrote local policy: $PolicyPath"

Info "Running MCP smoke test."
$env:CODEX_BRIDGE_POLICY_PATH = $PolicyPath
npm run smoke

Write-Host ""
Ok "Setup finished."
Write-Host ""
Write-Host "Next:"
Write-Host "1. Start local service:"
Write-Host "   powershell -ExecutionPolicy Bypass -File scripts\start-local.ps1"
Write-Host ""
Write-Host "2. Start ChatGPT Web tunnel:"
Write-Host "   powershell -ExecutionPolicy Bypass -File scripts\start-cloudflare.ps1"
Write-Host ""
Write-Host "3. Open the visual setup guide:"
Write-Host "   docs\setup.html"
