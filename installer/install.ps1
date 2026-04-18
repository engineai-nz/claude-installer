<#
.SYNOPSIS
  Engine AI Claude Installer - Windows

.DESCRIPTION
  Installs Claude Desktop + Claude Code CLI, configures MCP servers and
  skills for a chosen industry and productivity stack, and launches Claude
  Desktop. Designed for non-technical clients on personal/SMB Windows 10/11
  machines.

.EXAMPLE
  # One-liner
  iwr https://raw.githubusercontent.com/engineai-nz/claude-installer/main/installer/install.ps1 -OutFile $env:TEMP\install.ps1; & $env:TEMP\install.ps1 -Industry property -Stack microsoft

.EXAMPLE
  # Local
  .\installer\install.ps1 -Industry property -Stack microsoft
#>

[CmdletBinding()]
param(
  [ValidateSet("property")]
  [string] $Industry = "property",

  [ValidateSet("google", "microsoft")]
  [string] $Stack = "microsoft",

  [string] $BundleVersion = "latest",

  [switch] $DryRun,
  [switch] $DebugMode
)

$ErrorActionPreference = "Stop"
if ($DebugMode) { $VerbosePreference = "Continue" }

# ---------- Constants ----------
$InstallerVersion = "0.1.0"
$TemplatesRepo = "engineai-nz/claude-templates"
$WorkDir = Join-Path $env:USERPROFILE ".engineai-installer"
$LogDir = Join-Path $WorkDir "logs"
$BackupRoot = Join-Path $WorkDir "backups"
$BundleDir = Join-Path $WorkDir "bundle"
$ClaudeConfigDir = Join-Path $env:APPDATA "Claude"
$ClaudeCodeDir = Join-Path $env:USERPROFILE ".claude"

# ---------- Setup ----------
New-Item -ItemType Directory -Force -Path $LogDir, $BackupRoot, $BundleDir | Out-Null
$Ts = Get-Date -Format "yyyy-MM-dd-HHmmss"
$LogFile = Join-Path $LogDir "$Ts.log"
"" | Out-File -FilePath $LogFile -Encoding utf8

function Write-Log {
  param([string] $Message, [string] $Level = "INFO")
  $line = "$Message"
  Add-Content -Path $LogFile -Value $line
  switch ($Level) {
    "STEP"  { Write-Host ""; Write-Host "==> $Message" -ForegroundColor Yellow }
    "OK"    { Write-Host "  [OK] $Message" -ForegroundColor Green }
    "WARN"  { Write-Host "  [!]  $Message" -ForegroundColor DarkYellow }
    "ERR"   { Write-Host "  [X]  $Message" -ForegroundColor Red }
    "INFO"  { Write-Host "  $Message" -ForegroundColor Gray }
    default { Write-Host $Message }
  }
}

function Step  { param($m) Write-Log $m "STEP" }
function Info  { param($m) Write-Log $m "INFO" }
function Ok    { param($m) Write-Log $m "OK"   }
function Warn  { param($m) Write-Log $m "WARN" }
function ErrLog{ param($m) Write-Log $m "ERR"  }
function Fatal {
  param($m)
  ErrLog $m
  exit 1
}

function Invoke-Step {
  param([scriptblock] $Block, [string] $Description)
  if ($DryRun) {
    Info "[dry-run] $Description"
    return
  }
  & $Block
}

# ---------- Banner ----------
Write-Host ""
Write-Host "Engine AI Claude Installer" -ForegroundColor Yellow -NoNewline
Write-Host " v$InstallerVersion" -ForegroundColor DarkGray
Write-Host "Industry: $Industry   Stack: $Stack   Bundle: $BundleVersion" -ForegroundColor DarkGray
Write-Host "Log: $LogFile" -ForegroundColor DarkGray
Write-Host ""

# ---------- Phase 1: Preflight ----------
function Invoke-PhasePreflight {
  Step "Phase 1/8 - Preflight checks"

  $osVer = [System.Environment]::OSVersion.Version
  Info ("Windows {0}.{1} build {2}" -f $osVer.Major, $osVer.Minor, $osVer.Build)
  if ($osVer.Build -lt 18362) {
    Fatal "Windows build $($osVer.Build) is older than Windows 10 1903. Claude Desktop requires 1903 or later."
  }

  $arch = $env:PROCESSOR_ARCHITECTURE
  Info "Architecture: $arch"
  if ($arch -notin @("AMD64", "ARM64")) {
    Fatal "Unsupported architecture: $arch. Only 64-bit Windows is supported."
  }

  try {
    $null = Invoke-WebRequest -Uri "https://raw.githubusercontent.com" -Method Head -TimeoutSec 5
    Ok "Connectivity OK"
  } catch {
    Fatal "No connectivity to raw.githubusercontent.com - aborting."
  }

  if (Test-Path (Join-Path $env:LOCALAPPDATA "AnthropicClaude")) {
    Info "Claude Desktop is already installed - will reconfigure"
  }
  $existingMsix = Get-AppxPackage -Name "*Claude*" -ErrorAction SilentlyContinue
  if ($existingMsix) {
    Info "Claude Desktop MSIX install detected - config path differs from standard"
    $script:IsMsixInstall = $true
  } else {
    $script:IsMsixInstall = $false
  }

  if (Get-Command claude -ErrorAction SilentlyContinue) {
    Info "Claude Code CLI is already installed - will reconfigure"
  }

  $drive = (Get-Item $env:USERPROFILE).PSDrive
  $freeMb = [math]::Round($drive.Free / 1MB)
  if ($freeMb -lt 1024) {
    Fatal "Less than 1GB free on drive $($drive.Name). Free up space before continuing."
  }
  Ok "Preflight clean"
}

# ---------- Phase 2: Backup ----------
function Invoke-PhaseBackup {
  Step "Phase 2/8 - Backup existing configuration"
  $backupDir = Join-Path $BackupRoot $Ts
  Invoke-Step { New-Item -ItemType Directory -Force -Path $backupDir | Out-Null } "Create backup dir $backupDir"

  $backedUp = $false

  # Choose correct config dir for this install type
  $configDir = if ($IsMsixInstall) {
    $msixPkg = Get-AppxPackage -Name "*Claude*" | Select-Object -First 1
    if ($msixPkg) {
      Join-Path $env:LOCALAPPDATA "Packages\$($msixPkg.PackageFamilyName)\LocalCache\Roaming\Claude"
    } else { $ClaudeConfigDir }
  } else { $ClaudeConfigDir }

  $script:ActualClaudeConfigDir = $configDir
  Info "Claude Desktop config dir: $configDir"

  foreach ($file in @("claude_desktop_config.json", "developer_settings.json")) {
    $src = Join-Path $configDir $file
    if (Test-Path $src) {
      Invoke-Step { Copy-Item $src (Join-Path $backupDir $file) } "Backup $file"
      $backedUp = $true
    }
  }

  foreach ($file in @("settings.json", "permissions.json")) {
    $src = Join-Path $ClaudeCodeDir $file
    if (Test-Path $src) {
      Invoke-Step { Copy-Item $src (Join-Path $backupDir "claude_code_$file") } "Backup Claude Code $file"
      $backedUp = $true
    }
  }

  $skillsSrc = Join-Path $ClaudeCodeDir "skills"
  if (Test-Path $skillsSrc) {
    Invoke-Step { Copy-Item -Recurse $skillsSrc (Join-Path $backupDir "claude_code_skills") } "Backup skills"
    $backedUp = $true
  }

  # Restore script
  if (-not $DryRun) {
    $restoreScript = @"
# Restore script generated by Engine AI Claude Installer on $Ts
`$BackupDir = `$PSScriptRoot
if (Test-Path (Join-Path `$BackupDir 'claude_desktop_config.json')) {
  Copy-Item (Join-Path `$BackupDir 'claude_desktop_config.json') '$configDir\claude_desktop_config.json' -Force
}
if (Test-Path (Join-Path `$BackupDir 'developer_settings.json')) {
  Copy-Item (Join-Path `$BackupDir 'developer_settings.json') '$configDir\developer_settings.json' -Force
}
if (Test-Path (Join-Path `$BackupDir 'claude_code_settings.json')) {
  Copy-Item (Join-Path `$BackupDir 'claude_code_settings.json') '$ClaudeCodeDir\settings.json' -Force
}
if (Test-Path (Join-Path `$BackupDir 'claude_code_permissions.json')) {
  Copy-Item (Join-Path `$BackupDir 'claude_code_permissions.json') '$ClaudeCodeDir\permissions.json' -Force
}
if (Test-Path (Join-Path `$BackupDir 'claude_code_skills')) {
  Remove-Item -Recurse -Force '$ClaudeCodeDir\skills' -ErrorAction SilentlyContinue
  Copy-Item -Recurse (Join-Path `$BackupDir 'claude_code_skills') '$ClaudeCodeDir\skills'
}
Write-Host "Restored from `$BackupDir"
"@
    $restoreScript | Out-File -FilePath (Join-Path $backupDir "restore.ps1") -Encoding utf8
  }

  if ($backedUp) { Ok "Backed up to $backupDir" }
  else { Info "Nothing to back up (fresh install)" }
}

# ---------- Phase 3: Download bundle ----------
function Invoke-PhaseDownload {
  Step "Phase 3/8 - Download templates bundle"
  $tarball = "$Industry-$Stack.tar.gz"
  $downloadUrl = if ($BundleVersion -eq "latest") {
    "https://github.com/$TemplatesRepo/releases/latest/download/$tarball"
  } else {
    "https://github.com/$TemplatesRepo/releases/download/$BundleVersion/$tarball"
  }

  $bundleWork = Join-Path $BundleDir $Ts
  Invoke-Step { New-Item -ItemType Directory -Force -Path $bundleWork | Out-Null } "Create bundle work dir"

  Info "Fetching $tarball"
  $tarPath = Join-Path $bundleWork $tarball
  if (-not $DryRun) {
    try {
      Invoke-WebRequest -Uri $downloadUrl -OutFile $tarPath -TimeoutSec 60
    } catch {
      Fatal "Failed to download $downloadUrl. Is there a release tagged for $Industry-$Stack?"
    }
    # Windows 10 1803+ ships tar.exe (bsdtar). Should work for .tar.gz.
    tar -xzf $tarPath -C $bundleWork
  }

  $script:BundlePath = $bundleWork
  Ok "Unpacked to $bundleWork"
}

# ---------- Phase 4: Install Node.js ----------
function Invoke-PhaseInstallNode {
  Step "Phase 4/8 - Install Node.js runtime"
  if (Get-Command node -ErrorAction SilentlyContinue) {
    $nodeVer = & node --version
    Info "Node.js already present: $nodeVer"
    Ok "Node ready"
    return
  }

  Info "Node.js not found - installing via winget"
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    Invoke-Step {
      winget install --id OpenJS.NodeJS.LTS --silent --accept-package-agreements --accept-source-agreements --scope user 2>&1 | Out-Null
    } "winget install OpenJS.NodeJS.LTS"
    # Refresh PATH for this session
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
  } else {
    Warn "winget not available. Node.js install skipped - MCP servers may fail. Install Node LTS manually from https://nodejs.org"
    return
  }

  if (Get-Command node -ErrorAction SilentlyContinue) {
    Ok "Node.js installed: $(& node --version)"
  } else {
    Warn "Node.js not on PATH after install. Open a new terminal or restart to pick it up."
  }
}

# ---------- Phase 5: Install Claude Desktop ----------
function Invoke-PhaseInstallClaudeDesktop {
  Step "Phase 5/8 - Install Claude Desktop"
  $installed = (Test-Path (Join-Path $env:LOCALAPPDATA "AnthropicClaude")) -or $IsMsixInstall
  if ($installed) {
    Ok "Claude Desktop already installed"
    return
  }

  if (Get-Command winget -ErrorAction SilentlyContinue) {
    Info "Installing via winget"
    Invoke-Step {
      winget install --id Anthropic.Claude --silent --accept-package-agreements --accept-source-agreements --scope user 2>&1 | Out-Null
    } "winget install Anthropic.Claude"
  } else {
    Warn "winget not available. Install Claude Desktop manually from https://claude.ai/download"
    return
  }

  if (Test-Path (Join-Path $env:LOCALAPPDATA "AnthropicClaude")) {
    Ok "Claude Desktop installed"
  } else {
    Warn "Claude Desktop not found after install"
  }
}

# ---------- Phase 6: Install Claude Code CLI ----------
function Invoke-PhaseInstallClaudeCode {
  Step "Phase 6/8 - Install Claude Code CLI"
  if (Get-Command claude -ErrorAction SilentlyContinue) {
    Ok "Claude Code already installed"
    return
  }

  Info "Running official installer"
  if (-not $DryRun) {
    try {
      Invoke-RestMethod https://claude.ai/install.ps1 | Invoke-Expression
    } catch {
      Warn "Claude Code install failed. Run manually: irm https://claude.ai/install.ps1 | iex"
      return
    }
  }

  # Refresh PATH
  $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")

  if (Get-Command claude -ErrorAction SilentlyContinue) {
    Ok "Claude Code installed"
  } elseif (Test-Path (Join-Path $env:USERPROFILE ".claude\bin\claude.exe")) {
    Ok "Claude Code installed at ~\.claude\bin\claude.exe"
    Info "Open a new terminal after this script finishes to use 'claude' on PATH"
  } else {
    Warn "Claude Code binary not found on PATH. Open a fresh terminal."
  }
}

# ---------- Phase 7: Write configs + skills ----------
function Invoke-PhaseWriteConfigs {
  Step "Phase 7/8 - Write configs and skills"
  if (-not $BundlePath) { Fatal "Bundle not downloaded - aborting" }

  $configDir = $ActualClaudeConfigDir
  Invoke-Step { New-Item -ItemType Directory -Force -Path $configDir, (Join-Path $ClaudeCodeDir "skills") | Out-Null } "Ensure config dirs"

  # Stop Claude Desktop so it re-reads the config on next launch
  $claudeProc = Get-Process -Name "Claude" -ErrorAction SilentlyContinue
  if ($claudeProc) {
    Invoke-Step { Stop-Process -Name "Claude" -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 1 } "Stop Claude Desktop"
  }

  # claude_desktop_config.json with placeholder substitution
  $src = Join-Path $BundlePath "claude_desktop_config.json"
  $dst = Join-Path $configDir "claude_desktop_config.json"
  if (-not $DryRun) {
    $content = Get-Content $src -Raw
    # Literal .Replace() (not regex -replace), and double the backslashes so the
    # Windows path embeds as a valid JSON string.
    $content = $content.Replace('{{HOME}}', $env:USERPROFILE.Replace('\', '\\'))
    # .NET UTF8Encoding($false) writes without a BOM. PowerShell 5's
    # Set-Content -Encoding utf8 adds one, which Claude Desktop's JSON
    # parser rejects.
    [System.IO.File]::WriteAllText($dst, $content, (New-Object System.Text.UTF8Encoding($false)))
  }
  Ok "Wrote $dst"

  # developer_settings.json
  $devSrc = Join-Path $BundlePath "developer_settings.json"
  if (Test-Path $devSrc) {
    Invoke-Step { Copy-Item $devSrc (Join-Path $configDir "developer_settings.json") -Force } "Write developer_settings.json"
    Ok "Wrote developer_settings.json"
  }

  # Skills
  $skillsSrc = Join-Path $BundlePath "skills"
  if (Test-Path $skillsSrc) {
    Get-ChildItem -Directory $skillsSrc | ForEach-Object {
      $dstDir = Join-Path $ClaudeCodeDir "skills\$($_.Name)"
      Invoke-Step {
        if (Test-Path $dstDir) { Remove-Item -Recurse -Force $dstDir }
        Copy-Item -Recurse $_.FullName $dstDir
      } "Install skill $($_.Name)"
    }
    Ok "Installed skills to $ClaudeCodeDir\skills"
  }

  # Claude Code settings
  foreach ($file in @("settings.json", "permissions.json")) {
    $s = Join-Path $BundlePath "claude-code\$file"
    if (Test-Path $s) {
      Invoke-Step { Copy-Item $s (Join-Path $ClaudeCodeDir $file) -Force } "Write Claude Code $file"
      Ok "Wrote ~\.claude\$file"
    }
  }
}

# ---------- Phase 8: Finish ----------
function Invoke-PhaseFinish {
  Step "Phase 8/8 - Launch and next steps"

  $claudeExe = Join-Path $env:LOCALAPPDATA "AnthropicClaude\Claude.exe"
  if (-not (Test-Path $claudeExe)) {
    # Try MSIX launch
    $claudeExe = (Get-Command Claude -ErrorAction SilentlyContinue).Source
  }

  if (-not $DryRun -and $claudeExe -and (Test-Path $claudeExe)) {
    Start-Process $claudeExe
    Ok "Launched Claude Desktop"
  }

  Write-Host ""
  Write-Host "Install complete." -ForegroundColor Yellow
  Write-Host ""
  Write-Host "Next steps:"
  Write-Host "  1. Sign in to Claude Desktop with your Anthropic account"
  Write-Host "  2. Click the Cowork tab (top of the sidebar) to activate the agent"
  Write-Host "  3. Open a new PowerShell window and run 'claude' to try Claude Code"
  Write-Host ""
  Write-Host "Bundle manifest:  $BundlePath\manifest.json" -ForegroundColor DarkGray
  Write-Host "Install log:      $LogFile" -ForegroundColor DarkGray
  Write-Host "Restore earlier config: $BackupRoot\$Ts\restore.ps1" -ForegroundColor DarkGray
  Write-Host ""
}

# ---------- Main ----------
try {
  Invoke-PhasePreflight
  Invoke-PhaseBackup
  Invoke-PhaseDownload
  Invoke-PhaseInstallNode
  Invoke-PhaseInstallClaudeDesktop
  Invoke-PhaseInstallClaudeCode
  Invoke-PhaseWriteConfigs
  Invoke-PhaseFinish
} catch {
  ErrLog "Fatal: $_"
  Write-Host ""
  Write-Host "Install failed. Log: $LogFile" -ForegroundColor Red
  exit 1
}
