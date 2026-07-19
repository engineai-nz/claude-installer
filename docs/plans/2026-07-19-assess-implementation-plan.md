# assess.ps1 Health Check Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `installer/assess.ps1`, a read-only Windows diagnostic that maps a customer's Claude setup, machine health, data landscape, and business apps, printing a scored terminal summary and writing a JSON report.

**Architecture:** Single monolithic PowerShell 5.1 script (repo convention, matches install.ps1). Check-registry pattern: each category is a `Test-*` function returning standard finding objects from `New-Finding`; `Invoke-Assessment` runs all checks, computes two rollups (maturity level, readiness verdict), renders the console summary, and serialises the same objects to JSON. A library-mode env guard makes every function unit-testable under Pester without executing the scan.

**Tech Stack:** Windows PowerShell 5.1 (no external modules), Pester 3.4.0 (ships with Windows), CIM/registry/env probes only.

**Spec:** `docs/plans/2026-07-19-assess-health-check-design.md` — read it before starting any task.

## Global Constraints

- **Read-only contract:** no writes outside `~\.engineai-installer\assess\`; no process kills, launches, installs, or registry writes; registry reads only; never touch Claude while running; no file contents read beyond Claude's own config files.
- **Zero top-level parameters.** No `param()` block at script scope (breaks `irm | iex`). `param()` inside functions is fine.
- **PowerShell 5.1 compatible.** No PS7-only syntax (no ternary, no `??`, no `-AsHashtable`).
- **BOM-less UTF-8** for all file writes: `[System.IO.File]::WriteAllText($path, $content, (New-Object System.Text.UTF8Encoding($false)))`.
- **`.Replace()` not `-replace`** when embedding Windows paths into JSON strings.
- **No em dashes** anywhere in console output or docs (ASCII hyphens only).
- **Function names:** single-hyphen Verb-Noun only (`Test-MachineHealth`, never `Test-Machine-Health`).
- **Never crash on a bare machine.** Every check degrades to `missing`/`gap` findings; the runner wraps each check in try/catch.
- **Finding statuses:** exactly `ok | gap | missing | info`.
- **NZ English** in docs and output.

## Executor Environment Notes

- Use the **PowerShell tool** (Windows PowerShell 5.1) for running tests and the script. The repo lives on a UNC path (`\\wsl.localhost\...`), which PS 5.1 handles.
- If execution policy blocks running `.ps1` from the UNC path, copy the needed files to the session scratchpad directory and run there, or invoke via `powershell.exe -ExecutionPolicy Bypass -File <path>`.
- **Git must run inside WSL** (Windows git fails on UNC). Every commit step uses:
  `wsl.exe -d Ubuntu -- bash -c 'cd /home/duchats/projects/engineai/claude-installer && git add <files> && git commit -m "<msg>"'`
- Pester 3.4.0 syntax only: `$x | Should Be 'y'`, `Should Not Be`, `Should BeGreaterThan`. No `-Be` parameter syntax (that is Pester 5).
- Run tests with: `Invoke-Pester -Path <repo>\tests\assess.Tests.ps1` and check the `Passed`/`Failed` counts in output.
- Running `installer/assess.ps1` for smoke tests is safe by design (read-only) and expected on the dev laptop.

---

### Task 1: Scaffold, finding primitives, library-mode guard

**Files:**
- Create: `installer/assess.ps1`
- Create: `tests/assess.Tests.ps1`

**Interfaces:**
- Consumes: nothing (first task)
- Produces:
  - `New-Finding -Id <string> -Category <string> -Status <ok|gap|missing|info> [-Evidence <string>] [-Recommendation <string>] [-Data <hashtable>]` returns `[pscustomobject]` with lowercase properties `id, category, status, evidence, recommendation, data`
  - `Get-JsonSafe -Path <string>` returns `[pscustomobject]` with `exists [bool], valid [bool], hasBom [bool], data [object], error [string]`
  - `$script:AssessVersion` string constant
  - Library-mode guard: when `$env:ENGINEAI_ASSESS_LIBONLY -eq '1'`, the script defines functions and exits without scanning
  - Test harness pattern all later tasks reuse

- [ ] **Step 1: Write the failing test**

Create `tests/assess.Tests.ps1`:

```powershell
# Pester 3.4 tests for installer/assess.ps1.
# Loads the script in library mode so nothing executes.
$env:ENGINEAI_ASSESS_LIBONLY = '1'
$scriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'installer\assess.ps1'
. $scriptPath

Describe 'New-Finding' {
  It 'returns an object with the standard shape' {
    $f = New-Finding -Id 'x.y' -Category 'claude-desktop' -Status 'ok' -Evidence 'ev'
    $f.id | Should Be 'x.y'
    $f.category | Should Be 'claude-desktop'
    $f.status | Should Be 'ok'
    $f.evidence | Should Be 'ev'
    $f.recommendation | Should Be $null
  }
  It 'rejects an invalid status' {
    { New-Finding -Id 'a' -Category 'c' -Status 'broken' } | Should Throw
  }
  It 'carries optional data' {
    $f = New-Finding -Id 'a' -Category 'c' -Status 'info' -Data @{ count = 3 }
    $f.data.count | Should Be 3
  }
}

Describe 'Get-JsonSafe' {
  $tmp = Join-Path $env:TEMP "assess-test-$(Get-Random)"
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null

  It 'reports a missing file' {
    $r = Get-JsonSafe -Path (Join-Path $tmp 'nope.json')
    $r.exists | Should Be $false
    $r.valid | Should Be $false
  }
  It 'parses valid BOM-less JSON' {
    $p = Join-Path $tmp 'good.json'
    [System.IO.File]::WriteAllText($p, '{"a":1}', (New-Object System.Text.UTF8Encoding($false)))
    $r = Get-JsonSafe -Path $p
    $r.exists | Should Be $true
    $r.valid | Should Be $true
    $r.hasBom | Should Be $false
    $r.data.a | Should Be 1
  }
  It 'detects a UTF-8 BOM' {
    $p = Join-Path $tmp 'bom.json'
    [System.IO.File]::WriteAllText($p, '{"a":1}', (New-Object System.Text.UTF8Encoding($true)))
    $r = Get-JsonSafe -Path $p
    $r.hasBom | Should Be $true
    $r.valid | Should Be $true
  }
  It 'reports invalid JSON without throwing' {
    $p = Join-Path $tmp 'bad.json'
    [System.IO.File]::WriteAllText($p, '{not json', (New-Object System.Text.UTF8Encoding($false)))
    $r = Get-JsonSafe -Path $p
    $r.valid | Should Be $false
    $r.error | Should Not Be $null
  }

  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
```

- [ ] **Step 2: Run test to verify it fails**

Run (PowerShell tool): `Invoke-Pester -Path .\tests\assess.Tests.ps1`
Expected: FAIL (script file does not exist, dot-source error).

- [ ] **Step 3: Write the scaffold**

Create `installer/assess.ps1`:

```powershell
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
    [string] $Recommendation = $null,
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

# Check registry: populated by later tasks. Order = console display order.
$script:Checks = @()

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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester -Path .\tests\assess.Tests.ps1`
Expected: PASS, 7 passed, 0 failed.

- [ ] **Step 5: Commit**

```bash
wsl.exe -d Ubuntu -- bash -c 'cd /home/duchats/projects/engineai/claude-installer && git add installer/assess.ps1 tests/assess.Tests.ps1 && git commit -m "feat: assess.ps1 scaffold with finding primitives and library mode"'
```

---

### Task 2: machine-health checks

**Files:**
- Modify: `installer/assess.ps1` (add function before `$script:Checks`, register in `$script:Checks`)
- Modify: `tests/assess.Tests.ps1` (append Describe block)

**Interfaces:**
- Consumes: `New-Finding`
- Produces: `Test-MachineHealth` returning findings with these ids (all category `machine-health`):
  `machine.osSupport, machine.patchState, machine.ram, machine.disk, machine.cpu, machine.arch, machine.admin, machine.domainJoin, machine.mdm, machine.winget, machine.psVersion, machine.executionPolicy, machine.antivirus, machine.pendingReboot`
  Rollup task 8 depends on these exact ids.

- [ ] **Step 1: Write the failing test**

Append to `tests/assess.Tests.ps1`:

```powershell
Describe 'Test-MachineHealth' {
  $findings = Test-MachineHealth
  It 'returns findings' {
    @($findings).Count | Should BeGreaterThan 10
  }
  It 'uses only valid statuses' {
    ($findings | Where-Object { $_.status -notin @('ok','gap','missing','info') }) | Should Be $null
  }
  It 'includes the readiness-critical ids' {
    foreach ($id in @('machine.osSupport','machine.admin','machine.mdm','machine.arch',
                      'machine.patchState','machine.disk','machine.ram','machine.winget')) {
      ($findings | Where-Object { $_.id -eq $id }) | Should Not Be $null
    }
  }
  It 'has unique ids' {
    $ids = $findings | ForEach-Object { $_.id }
    ($ids | Group-Object | Where-Object Count -gt 1) | Should Be $null
  }
  It 'reports RAM as a number in data' {
    ($findings | Where-Object { $_.id -eq 'machine.ram' }).data.gb | Should BeGreaterThan 0
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Invoke-Pester -Path .\tests\assess.Tests.ps1`
Expected: FAIL, `Test-MachineHealth` not recognised.

- [ ] **Step 3: Implement**

Add to `installer/assess.ps1` (before the `$script:Checks` line):

```powershell
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
```

Register it by changing the `$script:Checks` line:

```powershell
$script:Checks = @('Test-MachineHealth')
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester -Path .\tests\assess.Tests.ps1`
Expected: PASS, 12 passed, 0 failed.

- [ ] **Step 5: Commit**

```bash
wsl.exe -d Ubuntu -- bash -c 'cd /home/duchats/projects/engineai/claude-installer && git add installer/assess.ps1 tests/assess.Tests.ps1 && git commit -m "feat: machine-health checks (OS support, hardware, admin, MDM, friction)"'
```

---

### Task 3: claude-desktop checks

**Files:**
- Modify: `installer/assess.ps1`
- Modify: `tests/assess.Tests.ps1`

**Interfaces:**
- Consumes: `New-Finding`, `Get-JsonSafe`
- Produces:
  - `Get-ClaudeDesktopContext` returning `[pscustomobject]` with `installType ('standard'|'msix'|'none'), version [string], configDir [string], configPath [string]`. Tasks 5 and 9 consume this.
  - `Test-ClaudeDesktop` returning findings with ids (category `claude-desktop`):
    `desktop.installed, desktop.config, desktop.mcpServers, desktop.devSettings, desktop.running`
    `desktop.mcpServers` carries `-Data @{ count = <int>; names = <string[]> }`; rollup task 8 reads `data.count`.

- [ ] **Step 1: Write the failing test**

Append to `tests/assess.Tests.ps1`:

```powershell
Describe 'Get-ClaudeDesktopContext' {
  It 'returns a context object with a valid installType' {
    $ctx = Get-ClaudeDesktopContext
    $ctx.installType | Should Match '^(standard|msix|none)$'
  }
  It 'resolves a config path when installed' {
    $ctx = Get-ClaudeDesktopContext
    if ($ctx.installType -ne 'none') {
      $ctx.configPath | Should Match 'claude_desktop_config\.json$'
    } else {
      $ctx.configPath | Should Be $null
    }
  }
}

Describe 'Test-ClaudeDesktop' {
  $findings = Test-ClaudeDesktop
  It 'always reports installed state' {
    ($findings | Where-Object { $_.id -eq 'desktop.installed' }) | Should Not Be $null
  }
  It 'reports mcpServers with a count in data when config is valid' {
    $mcp = $findings | Where-Object { $_.id -eq 'desktop.mcpServers' }
    if ($mcp -and $mcp.status -ne 'missing') {
      $mcp.data.count -ge 0 | Should Be $true
    }
  }
  It 'uses only valid statuses' {
    ($findings | Where-Object { $_.status -notin @('ok','gap','missing','info') }) | Should Be $null
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Invoke-Pester -Path .\tests\assess.Tests.ps1`
Expected: FAIL, `Get-ClaudeDesktopContext` not recognised.

- [ ] **Step 3: Implement**

Add to `installer/assess.ps1`:

```powershell
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
```

Register: `$script:Checks = @('Test-MachineHealth', 'Test-ClaudeDesktop')`

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester -Path .\tests\assess.Tests.ps1`
Expected: PASS, 17 passed, 0 failed.

- [ ] **Step 5: Commit**

```bash
wsl.exe -d Ubuntu -- bash -c 'cd /home/duchats/projects/engineai/claude-installer && git add installer/assess.ps1 tests/assess.Tests.ps1 && git commit -m "feat: claude-desktop checks with shared install-context helper"'
```

---

### Task 4: claude-code checks

**Files:**
- Modify: `installer/assess.ps1`
- Modify: `tests/assess.Tests.ps1`

**Interfaces:**
- Consumes: `New-Finding`, `Get-JsonSafe`
- Produces: `Test-ClaudeCode` returning findings with ids (category `claude-code`):
  `code.installed, code.settings, code.skills, code.claudeMd, code.mcpServers`
  `code.installed` status `ok` and `code.skills` status `ok` are consumed by the maturity rollup (task 8). `code.mcpServers` carries `-Data @{ count; names }` like the desktop equivalent.

- [ ] **Step 1: Write the failing test**

Append to `tests/assess.Tests.ps1`:

```powershell
Describe 'Test-ClaudeCode' {
  $findings = Test-ClaudeCode
  It 'always reports installed state' {
    ($findings | Where-Object { $_.id -eq 'code.installed' }) | Should Not Be $null
  }
  It 'uses only valid statuses' {
    ($findings | Where-Object { $_.status -notin @('ok','gap','missing','info') }) | Should Be $null
  }
  It 'has unique ids' {
    $ids = $findings | ForEach-Object { $_.id }
    ($ids | Group-Object | Where-Object Count -gt 1) | Should Be $null
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Invoke-Pester -Path .\tests\assess.Tests.ps1`
Expected: FAIL, `Test-ClaudeCode` not recognised.

- [ ] **Step 3: Implement**

```powershell
function Test-ClaudeCode {
  $c = 'claude-code'
  $findings = @()
  $claudeDir = Join-Path $env:USERPROFILE '.claude'

  $cmd = Get-Command claude -ErrorAction SilentlyContinue
  $binPath = Join-Path $claudeDir 'bin\claude.exe'
  $installed = $false
  if ($cmd) {
    $installed = $true
    $ver = $null
    try { $ver = (& claude --version 2>$null | Select-Object -First 1) } catch { }
    $findings += New-Finding -Id 'code.installed' -Category $c -Status 'ok' `
      -Evidence $(if ($ver) { "On PATH, $ver" } else { 'On PATH' })
  } elseif (Test-Path $binPath) {
    $installed = $true
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
```

Register: `$script:Checks = @('Test-MachineHealth', 'Test-ClaudeDesktop', 'Test-ClaudeCode')`

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester -Path .\tests\assess.Tests.ps1`
Expected: PASS, 20 passed, 0 failed.

- [ ] **Step 5: Commit**

```bash
wsl.exe -d Ubuntu -- bash -c 'cd /home/duchats/projects/engineai/claude-installer && git add installer/assess.ps1 tests/assess.Tests.ps1 && git commit -m "feat: claude-code checks (CLI, settings, skills, MCPs)"'
```

---

### Task 5: mcp-runtime checks

**Files:**
- Modify: `installer/assess.ps1`
- Modify: `tests/assess.Tests.ps1`

**Interfaces:**
- Consumes: `New-Finding`, `Get-JsonSafe`, `Get-ClaudeDesktopContext`
- Produces:
  - `Test-McpServerEntry -Name <string> -Server <object> -NpxAvailable <bool>` (pure helper, unit-tested) returning ONE finding with id `mcp.server.<Name>`, category `mcp-runtime`. Status `ok` when the command resolves and no `{{PLACEHOLDER}}` tokens remain; `gap` otherwise.
  - `Test-McpRuntime` returning `mcp.node`, `mcp.filesystem`, plus one `mcp.server.*` finding per configured Desktop server. `mcp.node` status and `mcp.filesystem` status feed the maturity rollup (task 8). `mcp.filesystem` is `ok` when a filesystem MCP server exists in the Desktop config AND its entry is `ok`.

- [ ] **Step 1: Write the failing test**

Append to `tests/assess.Tests.ps1`:

```powershell
Describe 'Test-McpServerEntry' {
  It 'flags unfilled placeholders as gap' {
    $server = ('{"command":"npx","args":["-y","some-mcp"],"env":{"KEY":"{{API_KEY}}"}}' | ConvertFrom-Json)
    $f = Test-McpServerEntry -Name 'hubspot' -Server $server -NpxAvailable $true
    $f.id | Should Be 'mcp.server.hubspot'
    $f.status | Should Be 'gap'
    $f.evidence | Should Match 'placeholder'
  }
  It 'passes a clean npx server when npx is available' {
    $server = ('{"command":"npx","args":["-y","@modelcontextprotocol/server-filesystem","C:\\Users"]}' | ConvertFrom-Json)
    $f = Test-McpServerEntry -Name 'filesystem' -Server $server -NpxAvailable $true
    $f.status | Should Be 'ok'
  }
  It 'flags npx servers when npx is missing' {
    $server = ('{"command":"npx","args":["-y","x"]}' | ConvertFrom-Json)
    $f = Test-McpServerEntry -Name 'x' -Server $server -NpxAvailable $false
    $f.status | Should Be 'gap'
  }
  It 'flags a non-existent absolute command path' {
    $server = ('{"command":"C:\\nope\\missing.exe","args":[]}' | ConvertFrom-Json)
    $f = Test-McpServerEntry -Name 'y' -Server $server -NpxAvailable $true
    $f.status | Should Be 'gap'
  }
}

Describe 'Test-McpRuntime' {
  $findings = Test-McpRuntime
  It 'always reports node state' {
    ($findings | Where-Object { $_.id -eq 'mcp.node' }) | Should Not Be $null
  }
  It 'always reports filesystem MCP state' {
    ($findings | Where-Object { $_.id -eq 'mcp.filesystem' }) | Should Not Be $null
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Invoke-Pester -Path .\tests\assess.Tests.ps1`
Expected: FAIL, `Test-McpServerEntry` not recognised.

- [ ] **Step 3: Implement**

```powershell
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
  if ($raw -match '\{\{[A-Za-z0-9_]+\}\}') {
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
```

Register: `$script:Checks = @('Test-MachineHealth', 'Test-ClaudeDesktop', 'Test-ClaudeCode', 'Test-McpRuntime')`

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester -Path .\tests\assess.Tests.ps1`
Expected: PASS, 26 passed, 0 failed.

- [ ] **Step 5: Commit**

```bash
wsl.exe -d Ubuntu -- bash -c 'cd /home/duchats/projects/engineai/claude-installer && git add installer/assess.ps1 tests/assess.Tests.ps1 && git commit -m "feat: mcp-runtime checks with per-server resolvability and placeholder scan"'
```

---

### Task 6: data-landscape checks

**Files:**
- Modify: `installer/assess.ps1`
- Modify: `tests/assess.Tests.ps1`

**Interfaces:**
- Consumes: `New-Finding`
- Produces: `Test-DataLandscape` returning findings (category `data-landscape`) with ids:
  `data.oneDrive, data.kfm, data.googleDrive, data.dropbox, data.mappedDrives`
  All are `info`/`ok` style evidence findings; `data.oneDrive` and `data.googleDrive` carry `-Data @{ paths = <string[]> }` used later by install-time drive mapping (not consumed inside assess).

- [ ] **Step 1: Write the failing test**

Append to `tests/assess.Tests.ps1`:

```powershell
Describe 'Test-DataLandscape' {
  $findings = Test-DataLandscape
  It 'reports all five landscape ids' {
    foreach ($id in @('data.oneDrive','data.kfm','data.googleDrive','data.dropbox','data.mappedDrives')) {
      ($findings | Where-Object { $_.id -eq $id }) | Should Not Be $null
    }
  }
  It 'uses only valid statuses' {
    ($findings | Where-Object { $_.status -notin @('ok','gap','missing','info') }) | Should Be $null
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Invoke-Pester -Path .\tests\assess.Tests.ps1`
Expected: FAIL, `Test-DataLandscape` not recognised.

- [ ] **Step 3: Implement**

```powershell
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
    $vols = Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue |
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

  # Mapped network drives.
  $mapped = @(Get-CimInstance Win32_MappedLogicalDisk -ErrorAction SilentlyContinue)
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
```

Register: append `'Test-DataLandscape'` to `$script:Checks`.

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester -Path .\tests\assess.Tests.ps1`
Expected: PASS, 28 passed, 0 failed.

- [ ] **Step 5: Commit**

```bash
wsl.exe -d Ubuntu -- bash -c 'cd /home/duchats/projects/engineai/claude-installer && git add installer/assess.ps1 tests/assess.Tests.ps1 && git commit -m "feat: data-landscape checks (OneDrive, KFM, Google Drive, mapped drives)"'
```

---

### Task 7: work-stack and opportunity-scan checks

**Files:**
- Modify: `installer/assess.ps1`
- Modify: `tests/assess.Tests.ps1`

**Interfaces:**
- Consumes: `New-Finding`
- Produces:
  - `Get-InstalledPrograms` returning `[object[]]` of registry uninstall entries with a `DisplayName` (HKLM 64-bit, HKLM WOW6432Node, HKCU). Cached in `$script:InstalledPrograms` so it runs once.
  - `Test-WorkStack` returning findings (category `work-stack`): `stack.microsoft, stack.google, stack.verdict`. `stack.verdict` carries `-Data @{ stack = 'microsoft'|'google'|'mixed'|'unknown' }` (the future `-Stack` flag value).
  - `Test-OpportunityScan` returning (category `opportunity-scan`) one `info` finding per detected known app with id `apps.<key>` and `-Data @{ mcpAvailable = <bool> }`, plus a summary finding `apps.summary` with `-Data @{ detected = <string[]>; mcpReady = <string[]> }`.

- [ ] **Step 1: Write the failing test**

Append to `tests/assess.Tests.ps1`:

```powershell
Describe 'Get-InstalledPrograms' {
  It 'returns entries with display names' {
    $progs = Get-InstalledPrograms
    @($progs).Count | Should BeGreaterThan 5
    ($progs | Select-Object -First 1).DisplayName | Should Not Be $null
  }
}

Describe 'Test-WorkStack' {
  $findings = Test-WorkStack
  It 'produces a verdict with a valid stack value' {
    $v = $findings | Where-Object { $_.id -eq 'stack.verdict' }
    $v | Should Not Be $null
    $v.data.stack | Should Match '^(microsoft|google|mixed|unknown)$'
  }
}

Describe 'Test-OpportunityScan' {
  $findings = Test-OpportunityScan
  It 'always produces a summary' {
    $s = $findings | Where-Object { $_.id -eq 'apps.summary' }
    $s | Should Not Be $null
    $s.data.detected -is [array] | Should Be $true
  }
  It 'marks every detected app with an mcpAvailable flag' {
    $apps = $findings | Where-Object { $_.id -like 'apps.*' -and $_.id -ne 'apps.summary' }
    foreach ($a in $apps) { $a.data.ContainsKey('mcpAvailable') | Should Be $true }
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Invoke-Pester -Path .\tests\assess.Tests.ps1`
Expected: FAIL, `Get-InstalledPrograms` not recognised.

- [ ] **Step 3: Implement**

```powershell
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
```

Register: append `'Test-WorkStack', 'Test-OpportunityScan'` to `$script:Checks`.

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester -Path .\tests\assess.Tests.ps1`
Expected: PASS, 32 passed, 0 failed.

- [ ] **Step 5: Commit**

```bash
wsl.exe -d Ubuntu -- bash -c 'cd /home/duchats/projects/engineai/claude-installer && git add installer/assess.ps1 tests/assess.Tests.ps1 && git commit -m "feat: work-stack verdict and opportunity-scan with known-apps table"'
```

---

### Task 8: rollups (maturity level + readiness verdict)

**Files:**
- Modify: `installer/assess.ps1`
- Modify: `tests/assess.Tests.ps1`

**Interfaces:**
- Consumes: finding ids from tasks 2-5: `desktop.installed, desktop.mcpServers (data.count), code.installed, code.skills, mcp.node, mcp.filesystem, machine.osSupport, machine.admin, machine.mdm, machine.arch, machine.patchState, machine.disk, machine.ram, machine.winget, machine.antivirus, machine.pendingReboot, machine.executionPolicy`
- Produces:
  - `Get-MaturityLevel -Findings <object[]>` returning `[int]` 0-4
  - `Get-ReadinessVerdict -Findings <object[]>` returning `[pscustomobject]` with `verdict ('ready'|'ready-with-friction'|'not-ready')`, `blockers [object[]]` each `@{ id; evidence; estimateMinutes }`
  Task 9 consumes both.

- [ ] **Step 1: Write the failing test**

These are pure functions, so fabricate findings. Append:

```powershell
function New-TestFinding {
  param($Id, $Status, $Data = $null)
  New-Finding -Id $Id -Category 'test' -Status $Status -Evidence 'test' -Data $Data
}

Describe 'Get-MaturityLevel' {
  It 'is 0 when nothing is installed' {
    $f = @( (New-TestFinding 'desktop.installed' 'missing'), (New-TestFinding 'code.installed' 'missing') )
    Get-MaturityLevel -Findings $f | Should Be 0
  }
  It 'is 1 with Desktop but zero MCPs' {
    $f = @(
      (New-TestFinding 'desktop.installed' 'ok'),
      (New-TestFinding 'desktop.mcpServers' 'gap' @{ count = 0; names = @() }),
      (New-TestFinding 'code.installed' 'missing')
    )
    Get-MaturityLevel -Findings $f | Should Be 1
  }
  It 'is 2 with MCPs configured but runtime broken' {
    $f = @(
      (New-TestFinding 'desktop.installed' 'ok'),
      (New-TestFinding 'desktop.mcpServers' 'ok' @{ count = 5; names = @('a') }),
      (New-TestFinding 'mcp.node' 'missing'),
      (New-TestFinding 'mcp.filesystem' 'gap'),
      (New-TestFinding 'code.installed' 'missing')
    )
    Get-MaturityLevel -Findings $f | Should Be 2
  }
  It 'is 3 with working MCPs and filesystem access but no Code/skills' {
    $f = @(
      (New-TestFinding 'desktop.installed' 'ok'),
      (New-TestFinding 'desktop.mcpServers' 'ok' @{ count = 5; names = @('a') }),
      (New-TestFinding 'mcp.node' 'ok'),
      (New-TestFinding 'mcp.filesystem' 'ok'),
      (New-TestFinding 'code.installed' 'missing')
    )
    Get-MaturityLevel -Findings $f | Should Be 3
  }
  It 'is 4 when Code and skills are also in place' {
    $f = @(
      (New-TestFinding 'desktop.installed' 'ok'),
      (New-TestFinding 'desktop.mcpServers' 'ok' @{ count = 5; names = @('a') }),
      (New-TestFinding 'mcp.node' 'ok'),
      (New-TestFinding 'mcp.filesystem' 'ok'),
      (New-TestFinding 'code.installed' 'ok'),
      (New-TestFinding 'code.skills' 'ok')
    )
    Get-MaturityLevel -Findings $f | Should Be 4
  }
}

Describe 'Get-ReadinessVerdict' {
  It 'is not-ready on any hard stop' {
    $f = @( (New-TestFinding 'machine.osSupport' 'missing'), (New-TestFinding 'machine.admin' 'ok'),
            (New-TestFinding 'machine.mdm' 'ok'), (New-TestFinding 'machine.arch' 'ok') )
    (Get-ReadinessVerdict -Findings $f).verdict | Should Be 'not-ready'
  }
  It 'is ready-with-friction on friction findings only' {
    $f = @( (New-TestFinding 'machine.osSupport' 'ok'), (New-TestFinding 'machine.admin' 'ok'),
            (New-TestFinding 'machine.mdm' 'ok'), (New-TestFinding 'machine.arch' 'ok'),
            (New-TestFinding 'machine.patchState' 'gap'), (New-TestFinding 'machine.winget' 'gap') )
    $v = Get-ReadinessVerdict -Findings $f
    $v.verdict | Should Be 'ready-with-friction'
    @($v.blockers).Count | Should Be 2
    ($v.blockers | ForEach-Object { $_.estimateMinutes } | Measure-Object -Sum).Sum | Should BeGreaterThan 0
  }
  It 'is ready when everything is clean' {
    $f = @( (New-TestFinding 'machine.osSupport' 'ok'), (New-TestFinding 'machine.admin' 'ok'),
            (New-TestFinding 'machine.mdm' 'ok'), (New-TestFinding 'machine.arch' 'ok') )
    (Get-ReadinessVerdict -Findings $f).verdict | Should Be 'ready'
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Invoke-Pester -Path .\tests\assess.Tests.ps1`
Expected: FAIL, `Get-MaturityLevel` not recognised.

- [ ] **Step 3: Implement**

```powershell
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
  $frictionEstimates = @{
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
    if ($byId[$id] -and $byId[$id].status -ne 'ok') {
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester -Path .\tests\assess.Tests.ps1`
Expected: PASS, 40 passed, 0 failed.

- [ ] **Step 5: Commit**

```bash
wsl.exe -d Ubuntu -- bash -c 'cd /home/duchats/projects/engineai/claude-installer && git add installer/assess.ps1 tests/assess.Tests.ps1 && git commit -m "feat: maturity level and readiness verdict rollups"'
```

---

### Task 9: console renderer, JSON export, full runner wiring

**Files:**
- Modify: `installer/assess.ps1` (replace the stub `Invoke-Assessment`)
- Modify: `tests/assess.Tests.ps1`

**Interfaces:**
- Consumes: everything above
- Produces:
  - `Export-AssessJson -Findings <object[]> -Maturity <int> -Readiness <object>` returning the written file path. JSON shape per spec section 6.2: `schemaVersion (1), assessVersion, timestamp (ISO 8601 with offset), machine { hostname, user, os, arch }, maturityLevel, readiness { verdict, blockers }, findings [...], summary { ok, gap, missing }`. BOM-less UTF-8.
  - `Write-AssessConsole -Findings <object[]> -Maturity <int> -Readiness <object>` (display only)
  - Final `Invoke-Assessment` that runs checks, computes rollups, renders, exports, prints the JSON path last

- [ ] **Step 1: Write the failing test**

Append to `tests/assess.Tests.ps1`:

```powershell
Describe 'Export-AssessJson' {
  $f = @(
    (New-TestFinding 'desktop.installed' 'ok'),
    (New-TestFinding 'machine.ram' 'gap' @{ gb = 4 }),
    (New-TestFinding 'apps.summary' 'info' @{ detected = @('Slack') })
  )
  $r = [pscustomobject]@{ verdict = 'ready'; blockers = @() }
  $path = Export-AssessJson -Findings $f -Maturity 1 -Readiness $r

  It 'writes a file' {
    Test-Path $path | Should Be $true
  }
  It 'writes BOM-less parseable JSON with the spec shape' {
    $bytes = [System.IO.File]::ReadAllBytes($path)
    ($bytes[0] -eq 0xEF) | Should Be $false
    $doc = [System.Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
    $doc.schemaVersion | Should Be 1
    $doc.maturityLevel | Should Be 1
    $doc.readiness.verdict | Should Be 'ready'
    @($doc.findings).Count | Should Be 3
    $doc.summary.ok | Should Be 1
    $doc.summary.gap | Should Be 1
    $doc.machine.hostname | Should Not Be $null
  }

  Remove-Item $path -ErrorAction SilentlyContinue
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `Invoke-Pester -Path .\tests\assess.Tests.ps1`
Expected: FAIL, `Export-AssessJson` not recognised.

- [ ] **Step 3: Implement**

Add the two functions, then REPLACE the stub `Invoke-Assessment` entirely:

```powershell
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `Invoke-Pester -Path .\tests\assess.Tests.ps1`
Expected: PASS, 42 passed, 0 failed.

- [ ] **Step 5: End-to-end smoke run on the dev laptop**

Run (PowerShell tool, execution-policy bypass if UNC blocks it):
`powershell.exe -ExecutionPolicy Bypass -File .\installer\assess.ps1`

Expected:
- All seven categories render with findings, no red error text from PowerShell itself
- Maturity level plausible for the dev laptop (3 or 4)
- Readiness verdict renders with any friction items listed
- `Report: C:\Users\...\.engineai-installer\assess\<ts>.json` printed
- Scan time under 30 seconds
- Open the JSON and confirm it parses: `(Get-Content <path> -Raw | ConvertFrom-Json).schemaVersion` returns 1

- [ ] **Step 6: Commit**

```bash
wsl.exe -d Ubuntu -- bash -c 'cd /home/duchats/projects/engineai/claude-installer && git add installer/assess.ps1 tests/assess.Tests.ps1 && git commit -m "feat: console renderer, JSON export, full assessment runner"'
```

---

### Task 10: prerequisites sheet and README

**Files:**
- Create: `docs/prerequisites.md`
- Modify: `README.md` (add assess one-liner above the install one-liners)

**Interfaces:**
- Consumes: readiness criteria from task 8 (the sheet mirrors `Get-ReadinessVerdict` hard stops and friction items)
- Produces: customer-facing prereq sheet; README documents assess as the engagement entry point

- [ ] **Step 1: Write docs/prerequisites.md**

```markdown
# Before we set up Claude for you

A quick checklist so your setup session takes 30 minutes instead of half a day.
If anything here is a problem, tell us before the session and we will plan around it.

## Your computer

- **Windows 11** (or an Apple Mac on macOS 13 Ventura or newer)
- **8 GB of memory** or more (16 GB is ideal). Not sure? We can check on the call.
- **10 GB of free disk space**
- **Up to date**: run Windows Update (or macOS Software Update) in the days before the session
- **You can install software on it**: you know the computer's admin password
- **It is your machine**: if a company IT department manages the computer, we need
  their sign-off first - ask us and we will send them a one-pager

## Your accounts

Have these passwords ready on the day:

- Your **Claude (Anthropic) account** login
- Your **Microsoft or Google account** login (whichever your business runs on)

## Internet

A stable connection. Nothing special, but installs download a few hundred MB.

## That is it

On the day, we run a 30-second read-only health check first. It reads settings,
not your files, and tells us exactly what your machine needs. If anything is not
ready, we will tell you on the spot and rebook rather than waste your time.
```

- [ ] **Step 2: Update README.md**

Read the current README first. Add an "Assess" section ABOVE the install one-liners:

```markdown
## Step 1: Assess (read-only health check)

Run this first on any machine. It changes nothing and takes about 30 seconds:

```powershell
irm https://raw.githubusercontent.com/engineai-nz/claude-installer/main/installer/assess.ps1 | iex
```

It prints a scored summary (Claude maturity level plus install readiness) and
writes a JSON report to `~\.engineai-installer\assess\`.

Customer prerequisites: see [docs/prerequisites.md](docs/prerequisites.md).
```

Keep the existing install instructions as "Step 2: Install" (adjust the heading only if the README structure allows it cleanly; do not rewrite unrelated content).

- [ ] **Step 3: Verify docs render**

Run: `Get-Content .\docs\prerequisites.md -TotalCount 5`
Expected: the heading renders, no encoding artifacts (no mangled characters).

- [ ] **Step 4: Commit**

```bash
wsl.exe -d Ubuntu -- bash -c 'cd /home/duchats/projects/engineai/claude-installer && git add docs/prerequisites.md README.md && git commit -m "docs: customer prerequisites sheet and assess one-liner in README"'
```

---

### Task 11: full-suite verification and memory files

**Files:**
- Modify: `tasks/todo.md`, `tasks/lessons.md` (if any new gotchas surfaced)

- [ ] **Step 1: Run the full test suite**

Run: `Invoke-Pester -Path .\tests\assess.Tests.ps1`
Expected: 42 passed, 0 failed.

- [ ] **Step 2: Re-run end-to-end**

Run: `powershell.exe -ExecutionPolicy Bypass -File .\installer\assess.ps1`
Expected: clean run, all categories, JSON written. Confirm no writes occurred outside `~\.engineai-installer\assess\` (spot-check: `claude_desktop_config.json` modification time unchanged).

- [ ] **Step 3: Update memory files**

In `tasks/todo.md`: add an "assess.ps1" section marking V1 built, with remaining items: fresh Windows 11 VM test (must hit Level 0 with zero uncaught exceptions), old/messy real machine test, macOS assess.sh (post-V1). Log any new platform gotchas discovered during implementation to `tasks/lessons.md`.

- [ ] **Step 4: Commit**

```bash
wsl.exe -d Ubuntu -- bash -c 'cd /home/duchats/projects/engineai/claude-installer && git add tasks/todo.md tasks/lessons.md && git commit -m "chore: update todo and lessons after assess.ps1 build"'
```
