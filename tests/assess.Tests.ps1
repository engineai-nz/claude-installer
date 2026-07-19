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
