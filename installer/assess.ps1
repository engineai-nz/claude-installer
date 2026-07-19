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
  $cs2 = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
  $ramGb = if ($cs2 -and $cs2.TotalPhysicalMemory) { [math]::Round($cs2.TotalPhysicalMemory / 1GB, 1) } else { 0 }
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
  $denyOnlyAdmin = $false
  if (-not $elevated -and -not $inAdmins) {
    try {
      $denyOnlyAdmin = [bool]((& whoami /groups) -match 'S-1-5-32-544')
    } catch { }
  }
  if ($elevated) {
    $findings += New-Finding -Id 'machine.admin' -Category $c -Status 'ok' -Evidence 'Running elevated'
  } elseif ($inAdmins) {
    $findings += New-Finding -Id 'machine.admin' -Category $c -Status 'ok' `
      -Evidence 'User is an administrator (not currently elevated)'
  } elseif ($denyOnlyAdmin) {
    $findings += New-Finding -Id 'machine.admin' -Category $c -Status 'ok' `
      -Evidence 'User is an administrator (UAC filtered token, can elevate)'
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
  $builtInProviders = @('Deploy Authority', 'Cloud Authority', 'Local Authority')
  $mdmProvider = $null
  try {
    $enrollments = Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction Stop
    foreach ($e in $enrollments) {
      $p = Get-ItemProperty $e.PSPath -ErrorAction SilentlyContinue
      if ($p.ProviderID -and ($p.ProviderID -notin $builtInProviders)) {
        $mdmProvider = $p.ProviderID
        if ($p.UPN) { $mdmProvider = "$($p.ProviderID) ($($p.UPN))" }
        break
      }
    }
  } catch { }
  if ($mdmProvider) {
    $findings += New-Finding -Id 'machine.mdm' -Category $c -Status 'missing' `
      -Evidence "MDM enrollment detected: $mdmProvider" `
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

function Test-ClaudeCode {
  $c = 'claude-code'
  $findings = @()
  $claudeDir = Join-Path $env:USERPROFILE '.claude'

  $cmd = Get-Command claude -ErrorAction SilentlyContinue
  $binPath = Join-Path $claudeDir 'bin\claude.exe'
  if ($cmd) {
    $ver = $null
    try { $ver = (& claude --version 2>$null | Select-Object -First 1) } catch { }
    $findings += New-Finding -Id 'code.installed' -Category $c -Status 'ok' `
      -Evidence $(if ($ver) { "On PATH, $ver" } else { 'On PATH' })
  } elseif (Test-Path $binPath) {
    $findings += New-Finding -Id 'code.installed' -Category $c -Status 'ok' `
      -Evidence 'Installed at ~\.claude\bin (not on PATH in this shell)'
  } else {
    $findings += New-Finding -Id 'code.installed' -Category $c -Status 'missing' `
      -Evidence 'Claude Code CLI not installed' `
      -Recommendation 'Install Claude Code (skills and agent workflows run here)'
    return $findings
  }

  if (Test-Path (Join-Path $claudeDir 'settings.json')) {
    $findings += New-Finding -Id 'code.settings' -Category $c -Status 'ok' -Evidence 'settings.json present'
  } else {
    $findings += New-Finding -Id 'code.settings' -Category $c -Status 'gap' `
      -Evidence 'No settings.json' -Recommendation 'Apply Engine AI baseline settings'
  }

  $skillsDir = Join-Path $claudeDir 'skills'
  $skills = @()
  if (Test-Path $skillsDir) {
    $skills = @(Get-ChildItem $skillsDir -Directory -ErrorAction SilentlyContinue | ForEach-Object Name)
  }
  if ($skills.Count -gt 0) {
    $findings += New-Finding -Id 'code.skills' -Category $c -Status 'ok' `
      -Evidence "$($skills.Count) skills: $($skills -join ', ')" -Data @{ names = $skills }
  } else {
    $findings += New-Finding -Id 'code.skills' -Category $c -Status 'gap' `
      -Evidence 'No skills installed' -Recommendation 'Install the Engine AI skill bundle'
  }

  if (Test-Path (Join-Path $claudeDir 'CLAUDE.md')) {
    $findings += New-Finding -Id 'code.claudeMd' -Category $c -Status 'ok' -Evidence 'Global CLAUDE.md present'
  } else {
    $findings += New-Finding -Id 'code.claudeMd' -Category $c -Status 'info' -Evidence 'No global CLAUDE.md'
  }

  # Claude Code MCP servers live in ~\.claude.json (top-level mcpServers).
  $codeCfg = Get-JsonSafe -Path (Join-Path $env:USERPROFILE '.claude.json')
  $names = @()
  if ($codeCfg.valid -and $codeCfg.data.mcpServers) {
    $names = @($codeCfg.data.mcpServers.PSObject.Properties.Name)
  }
  $findings += New-Finding -Id 'code.mcpServers' -Category $c `
    -Status $(if ($names.Count -gt 0) { 'ok' } else { 'info' }) `
    -Evidence $(if ($names.Count -gt 0) { "$($names.Count) MCP servers: $($names -join ', ')" } else { 'No Code-side MCP servers' }) `
    -Data @{ count = $names.Count; names = $names }

  $findings
}

function Test-McpServerEntry {
  # Pure check of one MCP server config entry. No machine state beyond
  # command resolution.
  param(
    [Parameter(Mandatory)] [string] $Name,
    [Parameter(Mandatory)] [object] $Server,
    [Parameter(Mandatory)] [bool] $NpxAvailable
  )
  $problems = @()

  $raw = $Server | ConvertTo-Json -Depth 5 -Compress
  if ($raw -match '\{\{[A-Za-z0-9_-]+\}\}') {
    $problems += 'unfilled placeholder tokens'
  }

  $cmd = $Server.command
  if (-not $cmd) {
    $problems += 'no command'
  } elseif ($cmd -match '^[A-Za-z]:\\') {
    if (-not (Test-Path $cmd)) { $problems += "command not found: $cmd" }
  } elseif ($cmd -in @('npx', 'npx.cmd')) {
    if (-not $NpxAvailable) { $problems += 'npx not available (Node missing)' }
  } else {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { $problems += "command not on PATH: $cmd" }
  }

  if ($problems.Count -eq 0) {
    New-Finding -Id "mcp.server.$Name" -Category 'mcp-runtime' -Status 'ok' -Evidence 'Resolvable, no placeholders'
  } else {
    New-Finding -Id "mcp.server.$Name" -Category 'mcp-runtime' -Status 'gap' `
      -Evidence ($problems -join '; ') `
      -Recommendation "Server '$Name' is configured but cannot work as-is"
  }
}

function Test-McpRuntime {
  $c = 'mcp-runtime'
  $findings = @()

  $node = Get-Command node -ErrorAction SilentlyContinue
  $npx = Get-Command npx -ErrorAction SilentlyContinue
  $npxAvailable = [bool]$npx
  if ($node) {
    $ver = try { (& node --version) } catch { 'version unknown' }
    $findings += New-Finding -Id 'mcp.node' -Category $c -Status 'ok' -Evidence "Node $ver"
  } else {
    $findings += New-Finding -Id 'mcp.node' -Category $c -Status 'missing' `
      -Evidence 'Node.js not installed' `
      -Recommendation 'MCP servers cannot run without Node.js'
  }

  $ctx = Get-ClaudeDesktopContext
  $cfg = if ($ctx.configPath) { Get-JsonSafe -Path $ctx.configPath } else { $null }
  $fsOk = $false
  if ($cfg -and $cfg.valid -and $cfg.data.mcpServers) {
    foreach ($prop in $cfg.data.mcpServers.PSObject.Properties) {
      $f = Test-McpServerEntry -Name $prop.Name -Server $prop.Value -NpxAvailable $npxAvailable
      $findings += $f
      if ($prop.Name -match 'filesystem' -and $f.status -eq 'ok') { $fsOk = $true }
    }
  }

  if ($fsOk) {
    $findings += New-Finding -Id 'mcp.filesystem' -Category $c -Status 'ok' `
      -Evidence 'Working filesystem MCP configured'
  } else {
    $findings += New-Finding -Id 'mcp.filesystem' -Category $c -Status 'gap' `
      -Evidence 'No working filesystem MCP' `
      -Recommendation 'Claude cannot reach local files; connect the filesystem MCP to where the files live'
  }

  $findings
}

function Test-DataLandscape {
  $c = 'data-landscape'
  $findings = @()

  # OneDrive: personal and business env vars.
  $odPaths = @()
  foreach ($v in @($env:OneDrive, $env:OneDriveCommercial, $env:OneDriveConsumer)) {
    if ($v -and (Test-Path $v) -and ($odPaths -notcontains $v)) { $odPaths += $v }
  }
  if ($odPaths.Count -gt 0) {
    $findings += New-Finding -Id 'data.oneDrive' -Category $c -Status 'ok' `
      -Evidence "OneDrive: $($odPaths -join '; ')" -Data @{ paths = $odPaths }
  } else {
    $findings += New-Finding -Id 'data.oneDrive' -Category $c -Status 'info' `
      -Evidence 'No OneDrive detected' -Data @{ paths = @() }
  }

  # Known Folder Move: are Desktop/Documents redirected into OneDrive?
  $docs = [Environment]::GetFolderPath('MyDocuments')
  $desktop = [Environment]::GetFolderPath('Desktop')
  $kfm = $false
  foreach ($od in $odPaths) {
    if ($docs -like "$od*" -or $desktop -like "$od*") { $kfm = $true }
  }
  $findings += New-Finding -Id 'data.kfm' -Category $c -Status 'info' `
    -Evidence $(if ($kfm) { "Desktop/Documents redirected into OneDrive (Documents: $docs)" } else { "Desktop/Documents local (Documents: $docs)" }) `
    -Data @{ redirected = $kfm; documents = $docs; desktop = $desktop }

  # Google Drive for desktop: DriveFS data dir + mounted volume.
  $gdPaths = @()
  if (Test-Path (Join-Path $env:LOCALAPPDATA 'Google\DriveFS')) {
    $vols = Get-CimInstance Win32_LogicalDisk -OperationTimeoutSec 5 -ErrorAction SilentlyContinue |
      Where-Object { $_.VolumeName -eq 'Google Drive' }
    foreach ($v in $vols) { $gdPaths += $v.DeviceID }
    if ($gdPaths.Count -eq 0) { $gdPaths += 'installed (mount not found)' }
    $findings += New-Finding -Id 'data.googleDrive' -Category $c -Status 'ok' `
      -Evidence "Google Drive for desktop: $($gdPaths -join '; ')" -Data @{ paths = $gdPaths }
  } else {
    $findings += New-Finding -Id 'data.googleDrive' -Category $c -Status 'info' `
      -Evidence 'No Google Drive for desktop' -Data @{ paths = @() }
  }

  # Dropbox.
  $dropbox = Join-Path $env:USERPROFILE 'Dropbox'
  $findings += New-Finding -Id 'data.dropbox' -Category $c -Status 'info' `
    -Evidence $(if (Test-Path $dropbox) { "Dropbox at $dropbox" } else { 'No Dropbox' })

  # Mapped network drives: read persistent mappings from the registry
  # (HKCU:\Network) instead of Win32_MappedLogicalDisk, which blocks on
  # SMB provider resolution per drive and can add 30s+ with dead mappings.
  $mapped = @()
  try {
    $mapped = @(Get-ChildItem 'HKCU:\Network' -ErrorAction Stop | ForEach-Object {
      $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
      [pscustomobject]@{ DeviceID = "$($_.PSChildName):"; ProviderName = $p.RemotePath }
    })
  } catch { }
  if ($mapped.Count -gt 0) {
    $desc = ($mapped | ForEach-Object { "$($_.DeviceID) -> $($_.ProviderName)" }) -join '; '
    $findings += New-Finding -Id 'data.mappedDrives' -Category $c -Status 'ok' `
      -Evidence "Mapped drives: $desc" `
      -Data @{ drives = @($mapped | ForEach-Object { @{ letter = $_.DeviceID; unc = $_.ProviderName } }) }
  } else {
    $findings += New-Finding -Id 'data.mappedDrives' -Category $c -Status 'info' -Evidence 'No mapped network drives'
  }

  $findings
}

function Get-InstalledPrograms {
  if ($script:InstalledPrograms) { return $script:InstalledPrograms }
  $paths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
  )
  $script:InstalledPrograms = @(
    Get-ItemProperty $paths -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName }
  )
  return $script:InstalledPrograms
}

function Test-WorkStack {
  $c = 'work-stack'
  $findings = @()
  $progs = Get-InstalledPrograms

  $msSignals = @()
  if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun') { $msSignals += 'Microsoft 365 (Click-to-Run)' }
  if ($progs | Where-Object { $_.DisplayName -match 'Microsoft 365|Microsoft Office' }) { $msSignals += 'Office listed in programs' }
  if ((Get-AppxPackage -Name 'MSTeams' -ErrorAction SilentlyContinue) -or
      ($progs | Where-Object { $_.DisplayName -match 'Microsoft Teams' })) { $msSignals += 'Teams' }
  $msSignals = @($msSignals | Select-Object -Unique)

  $gSignals = @()
  if (Test-Path (Join-Path $env:LOCALAPPDATA 'Google\DriveFS')) { $gSignals += 'Google Drive for desktop' }
  try {
    $prog = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice' -ErrorAction Stop).ProgId
    if ($prog -like 'Chrome*') { $gSignals += 'Chrome default browser' }
  } catch { }

  $findings += New-Finding -Id 'stack.microsoft' -Category $c -Status 'info' `
    -Evidence $(if ($msSignals) { $msSignals -join ', ' } else { 'No Microsoft stack signals' })
  $findings += New-Finding -Id 'stack.google' -Category $c -Status 'info' `
    -Evidence $(if ($gSignals) { $gSignals -join ', ' } else { 'No Google stack signals' })

  $stack = if ($msSignals.Count -gt 0 -and $gSignals.Count -gt 0) { 'mixed' }
           elseif ($msSignals.Count -gt 0) { 'microsoft' }
           elseif ($gSignals.Count -gt 0) { 'google' }
           else { 'unknown' }
  $findings += New-Finding -Id 'stack.verdict' -Category $c -Status 'info' `
    -Evidence "Work stack: $stack" -Data @{ stack = $stack }

  $findings
}

function Test-OpportunityScan {
  $c = 'opportunity-scan'
  $findings = @()
  $progs = Get-InstalledPrograms
  $processes = @(Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $_.ProcessName })

  # Known-apps table. Extend freely: one row per app.
  # match = regex against DisplayName; proc = regex against process names.
  $knownApps = @(
    @{ key = 'slack';      name = 'Slack';            match = '^Slack';                 proc = '^slack$';     mcp = $true }
    @{ key = 'teams';      name = 'Microsoft Teams';  match = 'Microsoft Teams';        proc = '^ms-teams$';  mcp = $true }
    @{ key = 'zoom';       name = 'Zoom';             match = '^Zoom';                  proc = '^Zoom$';      mcp = $false }
    @{ key = 'notion';     name = 'Notion';           match = '^Notion';                proc = '^Notion$';    mcp = $true }
    @{ key = 'xero';       name = 'Xero';             match = 'Xero';                   proc = 'Xero';        mcp = $true }
    @{ key = 'myob';       name = 'MYOB';             match = 'MYOB';                   proc = 'MYOB';        mcp = $false }
    @{ key = 'quickbooks'; name = 'QuickBooks';       match = 'QuickBooks';             proc = 'qb';          mcp = $false }
    @{ key = 'dropbox';    name = 'Dropbox';          match = '^Dropbox';               proc = '^Dropbox$';   mcp = $true }
    @{ key = 'chatgpt';    name = 'ChatGPT Desktop';  match = '^ChatGPT';               proc = '^ChatGPT$';   mcp = $false }
    @{ key = 'copilot';    name = 'GitHub Copilot';   match = 'GitHub Copilot';         proc = $null;         mcp = $false }
    @{ key = 'cursor';     name = 'Cursor';           match = '^Cursor';                proc = '^Cursor$';    mcp = $false }
  )

  $detected = @()
  $mcpReady = @()
  foreach ($app in $knownApps) {
    $hit = $false
    if ($progs | Where-Object { $_.DisplayName -match $app.match }) { $hit = $true }
    if (-not $hit -and $app.proc -and ($processes | Where-Object { $_ -match $app.proc })) { $hit = $true }
    if ($hit) {
      $detected += $app.name
      if ($app.mcp) { $mcpReady += $app.name }
      $mcpNote = if ($app.mcp) { 'MCP connector available' } else { 'no MCP connector yet' }
      $findings += New-Finding -Id "apps.$($app.key)" -Category $c -Status 'info' `
        -Evidence "$($app.name) detected ($mcpNote)" -Data @{ mcpAvailable = $app.mcp }
    }
  }

  $findings += New-Finding -Id 'apps.summary' -Category $c -Status 'info' `
    -Evidence "$($detected.Count) known business apps detected, $($mcpReady.Count) connectable to Claude" `
    -Recommendation $(if ($mcpReady.Count -gt 0) { "Connect Claude to: $($mcpReady -join ', ')" } else { $null }) `
    -Data @{ detected = @($detected); mcpReady = @($mcpReady) }

  $findings
}

function Get-MaturityLevel {
  param([Parameter(Mandatory)] [object[]] $Findings)
  $byId = @{}
  foreach ($f in $Findings) { $byId[$f.id] = $f }

  $desktopOk = $byId['desktop.installed'] -and $byId['desktop.installed'].status -eq 'ok'
  $codeOk = $byId['code.installed'] -and $byId['code.installed'].status -eq 'ok'
  if (-not $desktopOk -and -not $codeOk) { return 0 }

  $mcpCount = 0
  if ($byId['desktop.mcpServers'] -and $byId['desktop.mcpServers'].data) {
    $mcpCount = [int]$byId['desktop.mcpServers'].data.count
  }
  if ($mcpCount -eq 0) { return 1 }

  $nodeOk = $byId['mcp.node'] -and $byId['mcp.node'].status -eq 'ok'
  $fsOk = $byId['mcp.filesystem'] -and $byId['mcp.filesystem'].status -eq 'ok'
  if (-not ($nodeOk -and $fsOk)) { return 2 }

  $skillsOk = $byId['code.skills'] -and $byId['code.skills'].status -eq 'ok'
  if ($codeOk -and $skillsOk) { return 4 }
  return 3
}

function Get-ReadinessVerdict {
  param([Parameter(Mandatory)] [object[]] $Findings)
  $byId = @{}
  foreach ($f in $Findings) { $byId[$f.id] = $f }

  # Hard stops: any of these not 'ok' means NOT READY.
  $hardStopIds = @('machine.osSupport', 'machine.admin', 'machine.mdm', 'machine.arch')
  # Friction: 'gap' here means READY WITH FRICTION, with a time cost.
  $frictionEstimates = [ordered]@{
    'machine.patchState'      = 45
    'machine.disk'            = 20
    'machine.ram'             = 0
    'machine.winget'          = 20
    'machine.antivirus'       = 15
    'machine.pendingReboot'   = 10
    'machine.executionPolicy' = 10
  }

  $blockers = @()
  $hard = $false
  foreach ($id in $hardStopIds) {
    if (-not $byId.ContainsKey($id)) {
      $hard = $true
      $blockers += [pscustomobject]@{ id = $id; evidence = "Health check incomplete: $id missing"; estimateMinutes = $null }
    } elseif ($byId[$id].status -ne 'ok') {
      $hard = $true
      $blockers += [pscustomobject]@{ id = $id; evidence = $byId[$id].evidence; estimateMinutes = $null }
    }
  }
  foreach ($id in $frictionEstimates.Keys) {
    if ($byId[$id] -and $byId[$id].status -eq 'gap') {
      $blockers += [pscustomobject]@{ id = $id; evidence = $byId[$id].evidence; estimateMinutes = $frictionEstimates[$id] }
    }
  }

  $verdict = if ($hard) { 'not-ready' }
             elseif (@($blockers).Count -gt 0) { 'ready-with-friction' }
             else { 'ready' }
  [pscustomobject]@{ verdict = $verdict; blockers = @($blockers) }
}

# Check registry: populated by later tasks. Order = console display order.
$script:Checks = @('Test-MachineHealth', 'Test-ClaudeDesktop', 'Test-ClaudeCode', 'Test-McpRuntime', 'Test-DataLandscape', 'Test-WorkStack', 'Test-OpportunityScan')

function Export-AssessJson {
  param(
    [Parameter(Mandatory)] [object[]] $Findings,
    [Parameter(Mandatory)] [int] $Maturity,
    [Parameter(Mandatory)] [object] $Readiness
  )
  New-Item -ItemType Directory -Force -Path $script:OutDir | Out-Null

  $summary = @{ ok = 0; gap = 0; missing = 0 }
  foreach ($f in $Findings) {
    if ($summary.ContainsKey($f.status)) { $summary[$f.status]++ }
  }

  $doc = [ordered]@{
    schemaVersion = 1
    assessVersion = $script:AssessVersion
    timestamp     = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    machine       = [ordered]@{
      hostname = $env:COMPUTERNAME
      user     = $env:USERNAME
      os       = "$((Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption) build $([System.Environment]::OSVersion.Version.Build)"
      arch     = $env:PROCESSOR_ARCHITECTURE
    }
    maturityLevel = $Maturity
    readiness     = $Readiness
    findings      = $Findings
    summary       = $summary
  }

  $path = Join-Path $script:OutDir "$(Get-Date -Format 'yyyy-MM-dd-HHmmss').json"
  $json = $doc | ConvertTo-Json -Depth 8
  [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
  return $path
}

function Write-AssessConsole {
  param(
    [Parameter(Mandatory)] [object[]] $Findings,
    [Parameter(Mandatory)] [int] $Maturity,
    [Parameter(Mandatory)] [object] $Readiness
  )
  $categoryOrder = @('machine-health', 'claude-desktop', 'claude-code', 'mcp-runtime',
                     'data-landscape', 'work-stack', 'opportunity-scan', 'internal')
  foreach ($cat in $categoryOrder) {
    $inCat = @($Findings | Where-Object { $_.category -eq $cat })
    if ($inCat.Count -eq 0) { continue }
    Write-Host ''
    Write-Host "== $cat ==" -ForegroundColor Yellow
    foreach ($f in $inCat) {
      switch ($f.status) {
        'ok'      { Write-Host "  [OK]  $($f.evidence)" -ForegroundColor Green }
        'gap'     { Write-Host "  [GAP] $($f.evidence)" -ForegroundColor DarkYellow }
        'missing' { Write-Host "  [--]  $($f.evidence)" -ForegroundColor Red }
        'info'    { Write-Host "  [i]   $($f.evidence)" -ForegroundColor Gray }
      }
    }
  }

  $maturityLabels = @{
    0 = 'Level 0 - Web only'; 1 = 'Level 1 - Desktop installed'
    2 = 'Level 2 - Partially connected'; 3 = 'Level 3 - Connected'
    4 = 'Level 4 - Orchestrated'
  }
  Write-Host ''
  Write-Host 'Claude maturity: ' -NoNewline
  Write-Host $maturityLabels[$Maturity] -ForegroundColor Cyan

  Write-Host 'Install readiness: ' -NoNewline
  switch ($Readiness.verdict) {
    'ready'               { Write-Host 'READY (about 30 min standard install)' -ForegroundColor Green }
    'ready-with-friction' {
      $mins = ($Readiness.blockers | Where-Object { $_.estimateMinutes } |
        ForEach-Object { $_.estimateMinutes } | Measure-Object -Sum).Sum
      if (-not $mins) { $mins = 0 }
      Write-Host "READY WITH FRICTION (add roughly $mins min)" -ForegroundColor DarkYellow
      foreach ($b in $Readiness.blockers) { Write-Host "    - $($b.evidence)" -ForegroundColor DarkYellow }
    }
    'not-ready'           {
      Write-Host 'NOT READY' -ForegroundColor Red
      foreach ($b in $Readiness.blockers) { Write-Host "    - $($b.evidence)" -ForegroundColor Red }
    }
  }

  $recs = @($Findings | Where-Object { $_.recommendation -and $_.status -in @('gap', 'missing') } |
    Select-Object -First 5)
  if ($recs.Count -gt 0) {
    Write-Host ''
    Write-Host 'What we would do:' -ForegroundColor Yellow
    $i = 1
    foreach ($r in $recs) { Write-Host "  $i. $($r.recommendation)"; $i++ }
  }
}

function Invoke-Assessment {
  Write-Host ''
  Write-Host 'Engine AI Claude Health Check' -ForegroundColor Yellow -NoNewline
  Write-Host " v$script:AssessVersion (read-only)" -ForegroundColor DarkGray
  Write-Host ''

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $findings = @()
  foreach ($check in $script:Checks) {
    Write-Host "  scanning: $check" -ForegroundColor DarkGray
    try {
      $findings += & $check
    } catch {
      $findings += New-Finding -Id "$check.error" -Category 'internal' -Status 'gap' `
        -Evidence "Check $check failed: $($_.Exception.Message)"
    }
  }

  $maturity = Get-MaturityLevel -Findings $findings
  $readiness = Get-ReadinessVerdict -Findings $findings
  Write-AssessConsole -Findings $findings -Maturity $maturity -Readiness $readiness

  $jsonPath = Export-AssessJson -Findings $findings -Maturity $maturity -Readiness $readiness
  $sw.Stop()
  Write-Host ''
  Write-Host "Scan took $([math]::Round($sw.Elapsed.TotalSeconds, 1))s" -ForegroundColor DarkGray
  Write-Host "Report: $jsonPath" -ForegroundColor Cyan
  Write-Host ''
}

if ($env:ENGINEAI_ASSESS_LIBONLY -ne '1') { Invoke-Assessment }
