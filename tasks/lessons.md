# Lessons — Claude Installer

**Last updated:** 2026-04-17

Corrections, gotchas, and things learned the hard way. Append-only.

---

## 2026-04-17 — Git on WSL projects from Claude Code on Windows

**Gotcha:** Running `git` against WSL project paths via Windows Git Bash (UNC path `//wsl.localhost/Ubuntu/...`) fails. `git init` creates `.git/` but every subsequent command returns `fatal: not in a git directory`.

**Fix:** Always run git via `wsl.exe -d Ubuntu -- bash -c '...'` so it executes natively inside WSL against Linux paths. File writes work fine via the UNC path (Edit / Write tools), but git ops must go through WSL.

**Pattern:**
```
wsl.exe -d Ubuntu -- bash -c 'cd /home/duchats/projects/... && git <cmd>'
```

For multi-line scripts, use a heredoc (`bash << 'OUTER' ... OUTER`) — inline `&&` chains get mangled by quoting.

---

## 2026-04-17 — Claude Desktop Developer tab enablement is undocumented

**Gotcha:** The Settings → Developer tab (which exposes MCP / Edit Config) has no publicly documented JSON flag. `developer_settings.json` + `allowDevTools` controls Chrome DevTools only.

**Working theory:** the tab appears automatically when `claude_desktop_config.json` exists with valid `mcpServers`. Unconfirmed on a clean VM.

**Action before first client ship:** test on a fresh Windows 11 VM and fresh macOS VM. If the tab does not appear, inspect `Local Storage/leveldb/` under the config dir for an Electron-stored flag.

---

## 2026-04-17 — PowerShell can't read UNC paths from Windows bash shim

**Gotcha:** Running `powershell.exe -Command "..."` from Git Bash with a UNC path (`\\wsl.localhost\...`) fails. PowerShell strips one leading backslash somewhere in the shell-to-shell handoff and reports "Cannot find path".

**Fix:** Don't syntax-check `.ps1` files via this path. Options:
- Run `pwsh` from inside WSL if installed
- Copy the file to a Windows-native path first and parse there
- Skip parse checks and rely on VM-based acceptance testing

For V1 I skipped the static parse check and marked Windows as "test on VM". If we hit frequent PS1 bugs, install pwsh in WSL or set up a Windows CI runner.

---

## 2026-04-17 — Build artifacts don't belong in source repos

**Gotcha:** First `python3 scripts/build-bundles.py` run generated `dist/bundles/` with 4 unpacked dirs + 2 tarballs. Without a `.gitignore` entry, these would have been committed as source.

**Fix:** Added `dist/` to `.gitignore` before first commit to claude-templates. Build output belongs in GitHub releases, not in the repo tree.

---

## 2026-04-18 — Windows install.ps1 bugs found on first real-machine test

Four separate failures on Ben's Windows 11 laptop (build 26200). All fixed.

**1. `-Debug` param collision with CmdletBinding.**
`[CmdletBinding()]` already adds `-Debug` as a common parameter. Declaring `[switch] $Debug` in the param block throws `A parameter with the name 'Debug' was defined multiple times`. Renamed to `$DebugMode`.

**2. Multi-hyphen function names not resolved by PowerShell 5.**
Functions named `Invoke-Phase-Backup` etc. (Verb-Noun-Noun) failed with `not recognized as the name of a cmdlet`. PowerShell convention is single-hyphen Verb-Noun. Renamed all phase functions to `Invoke-PhaseBackup`, etc.

**3. Em dash in `Step` headers mangled by CP1252 console.**
Windows consoles rendered `Phase 1/8 — Preflight` as `Phase 1/8 A-cents-symbols`. Replaced em dashes with ASCII hyphens.

**4. Windows paths embedded as invalid JSON in claude_desktop_config.json.**
Two compounding bugs:
- `$env:USERPROFILE -replace '\\', '\\'` doesn't double backslashes. PowerShell's `-replace` treats both operands as regex, so `\\` on the replacement side collapses to `\`. Fix: use `.Replace()` (literal) and double the backslashes that way.
- `Set-Content -Encoding utf8` on PowerShell 5 adds a UTF-8 BOM. Claude Desktop's JSON parser (Node `JSON.parse`) rejects BOM. Fix: `[IO.File]::WriteAllText($p, $c, (New-Object Text.UTF8Encoding $false))`.

**How to apply:** Every PowerShell script that writes JSON consumed by an Electron/Node app must use BOM-less UTF-8 via .NET. Every PowerShell path-munging into JSON strings must use `.Replace()` not `-replace`.

---

## 2026-04-18 — Claude Desktop overwrites user-managed config on shutdown

**Gotcha:** If Claude Desktop is running when the installer writes `claude_desktop_config.json`, killing the main process with `Stop-Process -Name "Claude" -Force; Start-Sleep 1` is not enough. Electron helper processes (renderer, GPU, utility — all named `claude.exe`) take longer than 1s to exit, and on their way out they write a defaults-only config (`{"preferences": {"coworkWebSearchEnabled": true}}`), wiping our `mcpServers` block. Result: "Could not load app settings" banner even though the file we wrote was valid.

Also: `Start-Process claude.exe` on an already-running Claude Desktop just focuses the existing window — it does NOT restart the app reading the fresh config. So relaunching at the end of the installer does nothing if Claude wasn't fully killed first.

**Fix:** In Phase 7 of install.ps1, poll until every `*laude*` process is gone (10s timeout) before writing the config. Phase 8 only launches if no Claude process is running.

**Client-side recovery if it ever happens again:** kill every `*laude*` process, re-write the config from the bundle manually, relaunch Claude from the Start menu (not the tray).

---

## 2026-04-18 — winget Anthropic.Claude lands in a versioned subdir

**Gotcha:** Post-install detection at `Test-Path $env:LOCALAPPDATA\AnthropicClaude` is too shallow. The installer drops the exe at `AnthropicClaude\app-<version>\claude.exe` (e.g. `app-1.3109.0`), so launching via `Join-Path $env:LOCALAPPDATA "AnthropicClaude\Claude.exe"` misses. The parent folder check happens to work today because `AnthropicClaude\` exists, but the launch path doesn't.

**Fix:** `Find-ClaudeDesktopExe` helper recursively globs `claude.exe` under `AnthropicClaude\` and picks the most recent by LastWriteTime. Phase 5 verification and Phase 8 launch both use it.

---

## 2026-04-18 — Official Claude Code installer script can block on stdin

**Gotcha:** `Invoke-RestMethod https://claude.ai/install.ps1 | Invoke-Expression` inside Phase 6 hung for >10 minutes on one VM. User pressed Enter and it completed with "Claude Code successfully installed". Looks like the script emits an interactive prompt that isn't visible when piped through `Invoke-Expression`.

**Action (deferred):** not fixing in V1 — the on-site operator can nudge it with Enter. If self-serve path lands later, need to either download and inspect the install script or invoke with explicit non-interactive flags.
