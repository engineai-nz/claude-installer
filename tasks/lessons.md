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
