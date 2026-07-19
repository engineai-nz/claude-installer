<#
.SYNOPSIS
  Engine AI Claude Health Check - Windows (read-only)

.DESCRIPTION
  Assesses a machine's Claude setup, machine health, data landscape, and
  installed business apps. Prints a scored summary and writes a JSON report.

  READ-ONLY CONTRACT
  - Writes nothing outside ~\.engineai-installer\assess\
  - No process kills, no app launches, no installs, no registry writes
  - Registry reads, environment variables, and filenames only
  - The only file contents read are Claude's own config files

.EXAMPLE
  irm https://raw.githubusercontent.com/engineai-nz/claude-installer/main/installer/assess.ps1 | iex
#>

# No top-level param() - required for irm | iex delivery.
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = `
  [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$script:AssessVersion = '0.1.0'
$script:OutDir = Join-Path $env:USERPROFILE '.engineai-installer\assess'

function New-Finding {
  param(
    [Parameter(Mandatory)] [string] $Id,
    [Parameter(Mandatory)] [string] $Category,
    [Parameter(Mandatory)] [ValidateSet('ok', 'gap', 'missing', 'info')] [string] $Status,
    [string] $Evidence = '',
    $Recommendation = $null,
    [hashtable] $Data = $null
  )
  [pscustomobject]@{
    id             = $Id
    category       = $Category
    status         = $Status
    evidence       = $Evidence
    recommendation = $Recommendation
    data           = $Data
  }
}

function Get-JsonSafe {
  # Read + parse a JSON file without ever throwing. Detects UTF-8 BOM,
  # which Claude Desktop's Node JSON parser rejects.
  param([Parameter(Mandatory)] [string] $Path)
  $result = [pscustomobject]@{
    exists = $false; valid = $false; hasBom = $false; data = $null; error = $null
  }
  if (-not (Test-Path $Path)) { return $result }
  $result.exists = $true
  try {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
      $result.hasBom = $true
    }
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($result.hasBom) { $text = $text.TrimStart([char]0xFEFF) }
    $result.data = $text | ConvertFrom-Json
    $result.valid = $true
  } catch {
    $result.error = $_.Exception.Message
  }
  return $result
}

function Test-MachineHealth {
  $c = 'machine-health'
  $findings = @()

  # OS support. Build 22000+ = Windows 11. Windows 10 reached end of
  # support in October 2025.
  $build = [System.Environment]::OSVersion.Version.Build
  $osName = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
  if ($build -ge 22000) {
    $findings += New-Finding -Id 'machine.osSupport' -Category $c -Status 'ok' `
      -Evidence "$osName build $build"
  } else {
    $findings += New-Finding -Id 'machine.osSupport' -Category $c -Status 'missing' `
      -Evidence "$osName build $build - Windows 10 is out of support (Oct 2025)" `
      -Recommendation 'Upgrade to Windows 11 or replace the machine before any install'
  }

  # Patch state: newest hotfix install date, 90-day staleness threshold.
  $lastPatch = $null
  try {
    $lastPatch = Get-HotFix -ErrorAction Stop |
      Where-Object { $_.InstalledOn } |
      Sort-Object InstalledOn -Descending |
      Select-Object -First 1 -ExpandProperty InstalledOn
  } catch { }
  if ($lastPatch -and $lastPatch -gt (Get-Date).AddDays(-90)) {
    $findings += New-Finding -Id 'machine.patchState' -Category $c -Status 'ok' `
      -Evidence "Last update $($lastPatch.ToString('yyyy-MM-dd'))"
  } elseif ($lastPatch) {
    $findings += New-Finding -Id 'machine.patchState' -Category $c -Status 'gap' `
      -Evidence "No updates since $($lastPatch.ToString('yyyy-MM-dd'))" `
      -Recommendation 'Run Windows Update before install day (can take an hour on a stale machine)'
  } else {
    $findings += New-Finding -Id 'machine.patchState' -Category $c -Status 'info' `
      -Evidence 'Could not read update history'
  }

  # Hardware.
  $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
  $ramGb = if ($os) { [math]::Round($os.TotalVisibleMemorySize / 1MB, 1) } else { 0 }
  $ramStatus = if ($ramGb -ge 8) { 'ok' } else { 'gap' }
  $findings += New-Finding -Id 'machine.ram' -Category $c -Status $ramStatus `
    -Evidence "$ramGb GB RAM" -Data @{ gb = $ramGb } `
    -Recommendation $(if ($ramStatus -eq 'gap') { '8 GB minimum for Claude Desktop plus MCP servers; expect sluggish performance' } else { $null })

  $sysLetter = $env:SystemDrive.TrimEnd(':')
  $disk = Get-PSDrive -Name $sysLetter -ErrorAction SilentlyContinue
  $freeGb = if ($disk) { [math]::Round($disk.Free / 1GB, 1) } else { 0 }
  $diskStatus = if ($freeGb -ge 10) { 'ok' } else { 'gap' }
  $findings += New-Finding -Id 'machine.disk' -Category $c -Status $diskStatus `
    -Evidence "$freeGb GB free on $env:SystemDrive" -Data @{ freeGb = $freeGb } `
    -Recommendation $(if ($diskStatus -eq 'gap') { 'Free at least 10 GB before install' } else { $null })

  $cpu = Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1
  $findings += New-Finding -Id 'machine.cpu' -Category $c -Status 'info' `
    -Evidence "$($cpu.Name) ($($cpu.NumberOfCores) cores)"

  $arch = $env:PROCESSOR_ARCHITECTURE
  $archStatus = if ($arch -eq 'AMD64') { 'ok' } elseif ($arch -eq 'ARM64') { 'gap' } else { 'missing' }
  $findings += New-Finding -Id 'machine.arch' -Category $c -Status $archStatus `
    -Evidence $arch `
    -Recommendation $(if ($archStatus -ne 'ok') { 'Non-AMD64 architecture: verify Claude Desktop and MCP support before committing' } else { $null })

  # Admin reality.
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $inAdmins = [bool]($identity.Groups | Where-Object { $_.Value -eq 'S-1-5-32-544' })
  $elevated = ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if ($elevated) {
    $findings += New-Finding -Id 'machine.admin' -Category $c -Status 'ok' -Evidence 'Running elevated'
  } elseif ($inAdmins) {
    $findings += New-Finding -Id 'machine.admin' -Category $c -Status 'ok' `
      -Evidence 'User is an administrator (not currently elevated)'
  } else {
    $findings += New-Finding -Id 'machine.admin' -Category $c -Status 'missing' `
      -Evidence 'Current user is not an administrator' `
      -Recommendation 'Get the machine admin password or an admin account before install day'
  }

  $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
  if ($cs -and $cs.PartOfDomain) {
    $findings += New-Finding -Id 'machine.domainJoin' -Category $c -Status 'gap' `
      -Evidence "Domain-joined: $($cs.Domain)" `
      -Recommendation 'Company-managed machine: IT sign-off required before install'
  } else {
    $findings += New-Finding -Id 'machine.domainJoin' -Category $c -Status 'ok' -Evidence 'Not domain-joined'
  }

  # MDM/Intune enrollment: registry read only.
  $mdm = $false
  try {
    $enrollments = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction Stop
    foreach ($e in $enrollments) {
      $p = Get-ItemProperty $e.PSPath -ErrorAction SilentlyContinue
      if ($p.ProviderID) { $mdm = $true; break }
    }
  } catch { }
  if ($mdm) {
    $findings += New-Finding -Id 'machine.mdm' -Category $c -Status 'missing' `
      -Evidence 'MDM/Intune enrollment detected' `
      -Recommendation 'Corporate-managed machine: out of standard scope, needs IT involvement'
  } else {
    $findings += New-Finding -Id 'machine.mdm' -Category $c -Status 'ok' -Evidence 'No MDM enrollment'
  }

  # Install friction.
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    $findings += New-Finding -Id 'machine.winget' -Category $c -Status 'ok' -Evidence 'winget available'
  } else {
    $findings += New-Finding -Id 'machine.winget' -Category $c -Status 'gap' `
      -Evidence 'winget not available' `
      -Recommendation 'Install App Installer from the Microsoft Store, or budget time for manual installs'
  }

  $findings += New-Finding -Id 'machine.psVersion' -Category $c -Status 'info' `
    -Evidence "PowerShell $($PSVersionTable.PSVersion)"

  $policy = Get-ExecutionPolicy
  $polStatus = if ($policy -in @('Restricted', 'AllSigned')) { 'gap' } else { 'ok' }
  $findings += New-Finding -Id 'machine.executionPolicy' -Category $c -Status $polStatus `
    -Evidence "Execution policy: $policy" `
    -Recommendation $(if ($polStatus -eq 'gap') { 'Restrictive execution policy will block install scripts' } else { $null })

  # Third-party AV via Security Center (workstations only; guard).
  $avNames = @()
  try {
    $avNames = Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName 'AntiVirusProduct' -ErrorAction Stop |
      Select-Object -ExpandProperty displayName
  } catch { }
  $thirdParty = @($avNames | Where-Object { $_ -and $_ -notmatch 'Defender' })
  if ($thirdParty.Count -gt 0) {
    $findings += New-Finding -Id 'machine.antivirus' -Category $c -Status 'gap' `
      -Evidence "Third-party AV: $($thirdParty -join ', ')" `
      -Recommendation 'Third-party antivirus can block or slow installers; budget extra time'
  } else {
    $findings += New-Finding -Id 'machine.antivirus' -Category $c -Status 'ok' `
      -Evidence $(if ($avNames) { "Windows Defender only" } else { 'No AV product reported' })
  }

  $rebootPending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
                   (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
  if ($rebootPending) {
    $findings += New-Finding -Id 'machine.pendingReboot' -Category $c -Status 'gap' `
      -Evidence 'Reboot pending' -Recommendation 'Reboot before install day'
  } else {
    $findings += New-Finding -Id 'machine.pendingReboot' -Category $c -Status 'ok' -Evidence 'No pending reboot'
  }

  $findings
}

function Get-ClaudeDesktopContext {
  # Standard install: %LOCALAPPDATA%\AnthropicClaude\app-<version>\claude.exe
  # MSIX install: config under the package LocalCache path.
  $ctx = [pscustomobject]@{ installType = 'none'; version = $null; configDir = $null; configPath = $null }

  $root = Join-Path $env:LOCALAPPDATA 'AnthropicClaude'
  $msix = Get-AppxPackage -Name '*Claude*' -ErrorAction SilentlyContinue | Select-Object -First 1

  if (Test-Path $root) {
    $ctx.installType = 'standard'
    $appDir = Get-ChildItem $root -Directory -Filter 'app-*' -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($appDir) { $ctx.version = $appDir.Name.Replace('app-', '') }
    $ctx.configDir = Join-Path $env:APPDATA 'Claude'
  } elseif ($msix) {
    $ctx.installType = 'msix'
    $ctx.version = $msix.Version
    $ctx.configDir = Join-Path $env:LOCALAPPDATA "Packages\$($msix.PackageFamilyName)\LocalCache\Roaming\Claude"
  }

  if ($ctx.configDir) {
    $ctx.configPath = Join-Path $ctx.configDir 'claude_desktop_config.json'
  }
  return $ctx
}

function Test-ClaudeDesktop {
  $c = 'claude-desktop'
  $findings = @()
  $ctx = Get-ClaudeDesktopContext

  if ($ctx.installType -eq 'none') {
    $findings += New-Finding -Id 'desktop.installed' -Category $c -Status 'missing' `
      -Evidence 'Claude Desktop not installed' `
      -Recommendation 'Install Claude Desktop (winget Anthropic.Claude)'
    return $findings
  }

  $verText = if ($ctx.version) { "v$($ctx.version)" } else { 'version unknown' }
  $findings += New-Finding -Id 'desktop.installed' -Category $c -Status 'ok' `
    -Evidence "$($ctx.installType) install, $verText"

  $cfg = Get-JsonSafe -Path $ctx.configPath
  if (-not $cfg.exists) {
    $findings += New-Finding -Id 'desktop.config' -Category $c -Status 'missing' `
      -Evidence 'No claude_desktop_config.json' `
      -Recommendation 'No MCP configuration exists; full setup required'
    return $findings
  }
  if (-not $cfg.valid) {
    $findings += New-Finding -Id 'desktop.config' -Category $c -Status 'gap' `
      -Evidence "Config invalid JSON: $($cfg.error)" `
      -Recommendation 'Config is corrupt; Claude Desktop cannot load it'
    return $findings
  }
  $bomNote = if ($cfg.hasBom) { ' (has UTF-8 BOM - Claude rejects this)' } else { '' }
  $cfgStatus = if ($cfg.hasBom) { 'gap' } else { 'ok' }
  $findings += New-Finding -Id 'desktop.config' -Category $c -Status $cfgStatus `
    -Evidence "Config valid$bomNote" `
    -Recommendation $(if ($cfg.hasBom) { 'Rewrite config as BOM-less UTF-8' } else { $null })

  $serverNames = @()
  if ($cfg.data.mcpServers) {
    $serverNames = @($cfg.data.mcpServers.PSObject.Properties.Name)
  }
  if ($serverNames.Count -gt 0) {
    $findings += New-Finding -Id 'desktop.mcpServers' -Category $c -Status 'ok' `
      -Evidence "$($serverNames.Count) MCP servers: $($serverNames -join ', ')" `
      -Data @{ count = $serverNames.Count; names = $serverNames }
  } else {
    $findings += New-Finding -Id 'desktop.mcpServers' -Category $c -Status 'gap' `
      -Evidence 'Config exists but no MCP servers configured' `
      -Recommendation 'Install the Engine AI MCP bundle' `
      -Data @{ count = 0; names = @() }
  }

  $devPath = Join-Path $ctx.configDir 'developer_settings.json'
  if (Test-Path $devPath) {
    $findings += New-Finding -Id 'desktop.devSettings' -Category $c -Status 'ok' -Evidence 'developer_settings.json present'
  } else {
    $findings += New-Finding -Id 'desktop.devSettings' -Category $c -Status 'info' -Evidence 'No developer_settings.json'
  }

  $running = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like '*laude*' }
  $findings += New-Finding -Id 'desktop.running' -Category $c -Status 'info' `
    -Evidence $(if ($running) { 'Claude Desktop is currently running' } else { 'Claude Desktop not running' })

  $findings
}

# Check registry: populated by later tasks. Order = console display order.
$script:Checks = @('Test-MachineHealth', 'Test-ClaudeDesktop')

function Invoke-Assessment {
  Write-Host ''
  Write-Host 'Engine AI Claude Health Check' -ForegroundColor Yellow -NoNewline
  Write-Host " v$script:AssessVersion (read-only)" -ForegroundColor DarkGray
  Write-Host ''

  $findings = @()
  foreach ($check in $script:Checks) {
    try {
      $findings += & $check
    } catch {
      $findings += New-Finding -Id "$check.error" -Category 'internal' -Status 'gap' `
        -Evidence "Check $check failed: $($_.Exception.Message)"
    }
  }
  # Rendering and JSON export are wired in a later task.
  $findings
}

if ($env:ENGINEAI_ASSESS_LIBONLY -ne '1') { Invoke-Assessment }
