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
