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
