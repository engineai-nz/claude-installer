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
