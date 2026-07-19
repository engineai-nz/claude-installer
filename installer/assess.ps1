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
