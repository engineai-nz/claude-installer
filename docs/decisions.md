# Decisions — Claude Installer

**Last updated:** 2026-04-17

Architecture and strategic decisions with rationale. One entry per decision.

---

## 2026-04-17 — Full V1 design locked in

See `docs/plans/2026-04-17-claude-installer-design.md` for the full spec. Key decisions captured here for traceability.

### Product
- Target = **Claude Desktop + Claude Code CLI** (not just one). Claude Code is where skills live and run; Desktop + MCPs is where non-power-users spend their time. Client gets both.
- **Cowork activation stays manual.** GUI-only, can't be scripted. Installer pre-loads MCPs so Cowork works the moment user clicks the tab.

### Target users
- Non-power-users on personal/SMB machines with full admin.
- **Corporate IT / locked-down machines = out of scope.** Different product entirely.

### Platforms
- Mac + Windows native. **No WSL setup on Windows** — clients aren't devs, WSL is a rabbit hole.

### Distribution
- Pure shell: `install.sh` for macOS (bash), `install.ps1` for Windows (PowerShell).
- No Node, no Python prerequisites on client machine.
- Hosted on `raw.githubusercontent.com`. Custom domain is a later nice-to-have.

### Repo architecture
- **Three repos.** `claude-installer` (public, installer code), `claude-templates` (new public, client bundles), `claude-business-templates` (existing private, dev factory).
- Why: secret sauce (template builder, tester, Ben/Joe workflow) stays private. Public templates repo is clean/auditable — what clients actually install.
- Future optionality: if content needs to go private, flip `claude-templates` visibility without touching installer.

### Bundle architecture (three tiers)
1. **Primitives** (always) — Chrome MCP, Desktop Commander, Filesystem, Playwright, Fetch. Cowork's hands.
2. **Stack** (`--stack google|microsoft|mixed`) — splits the ~50/50 SMB reality of Google Workspace vs M365.
3. **Industry add-ons** — declared per-industry in `manifest.json`.

Why three tiers: a property agent on Microsoft 365 ≠ a property agent on Workspace. Stack cuts across every industry, should be a first-class dimension not hidden inside each manifest.

### V1 skill install
- **Claude Code only.** Skills go to `~/.claude/skills/`. Fully scriptable, works immediately.
- **Claude Desktop skills deferred.** Current paths (upload to Claude Project via GUI, or .skill bundle via Settings) are not headlessly automatable. Revisit when Anthropic ships a filesystem/API for it.

### Safety
- **Backup + overwrite** (not merge) for existing configs. Merging is the #1 source of subtle installer bugs. Timestamped backup + restore script is the escape hatch.
- **Idempotent re-run.** Default behaviour is "repair" — detects existing installs, skips, re-syncs.
- **Credentials never auto-flow.** MCPs ship with `{{PLACEHOLDER}}` tokens. Ben handles top creds on-site for V1; post-install auth wizard is V2.

### Admin elevation
- **Installer assumes full admin on a personal/SMB machine.** Self-elevates via UAC on Windows / sudo on Mac for dev mode toggles, drops privileges for the rest.
- Non-admin refusal is non-fatal — continue with warning, skip dev mode.

### Versioning
- **Latest tagged release.** `main` branch of `claude-installer` points at latest. `claude-templates` fetched by tag at install time.
- Installer version ≠ templates version. Independent cadences.
- Per-client version pinning is post-V1 if support load demands it.

---

## 2026-04-17 — Silent install paths locked

### Windows
- **Primary path: `winget install Anthropic.Claude --silent --accept-package-agreements --accept-source-agreements --scope user`**
- Package is maintained in winget-pkgs. Squirrel.Windows per-user installer, no UAC, installs to `%LocalAppData%\AnthropicClaude\`.
- **Fallback (no winget, e.g. stripped Win10 LTSC):** download the signed `.exe` from `https://downloads.claude.ai/releases/win32/x64/{VERSION}/Claude-{HASH}.exe` and run with `--silent` (Squirrel flag). Version feed: `https://downloads.claude.ai/releases/win32/x64/RELEASES.json`.
- MSIX variant exists but adds no value for SMB install — skip.

### macOS
- **Primary path: `brew install --cask claude`** (cask is `claude`, not `claude-desktop`).
- **Fallback (no brew):** download `.zip` (not .dmg — Claude Desktop ships as a zipped .app now) from `https://downloads.claude.ai/releases/darwin/universal/{VERSION}/Claude-{HASH}.zip`, unzip with `ditto -xk`, move to `/Applications`, strip quarantine with `xattr -dr com.apple.quarantine`. Required or Gatekeeper prompts on first launch.
- Direct-zip is probably the better default — no brew dependency on a fresh SMB Mac.

### Sources
- winget manifest: https://raw.githubusercontent.com/microsoft/winget-pkgs/master/manifests/a/Anthropic/Claude/1.3109.0/Anthropic.Claude.installer.yaml
- homebrew-cask: https://raw.githubusercontent.com/Homebrew/homebrew-cask/main/Casks/c/claude.rb

---

## 2026-04-17 — Developer Mode flag paths

"Developer Mode" means two different things in this stack. V1 needs to handle both.

### Thing 1 — Chrome DevTools (Ctrl+Alt+I)
- Controlled by `developer_settings.json` → `{"allowDevTools": true}` in the Claude config dir.
- Documented by Anthropic in the MCP debugging docs.

### Thing 2 — Settings → Developer tab + "Edit Config" (MCP UI)
- **No publicly documented JSON flag.** Empirically, the Developer tab appears automatically once `claude_desktop_config.json` exists with valid `mcpServers`. Dropping a well-formed config is the practical enable.
- **Risk flagged:** verify on a clean VM before first client ship. If gated by Electron localStorage, check `Local Storage/leveldb/` under the config dir.

### Config dir paths

| Platform | Path |
|---|---|
| Windows (standard .exe) | `%APPDATA%\Claude\` (= `C:\Users\<user>\AppData\Roaming\Claude\`) |
| Windows (MSIX) | `%LOCALAPPDATA%\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude\` |
| macOS | `~/Library/Application Support/Claude/` |

Detect MSIX on Windows with `Get-AppxPackage -Name *Claude*`. No registry keys for Claude Desktop. No NSUserDefaults plist on macOS — Electron + JSON only.

### Claude Desktop must be fully quit before writing
- Closing the window does not reload config. Confirmed in MCP docs.
- Windows: `taskkill /IM Claude.exe /F`
- macOS: `pkill -x Claude`

### Windows OS-level Developer Mode (separate concern)
- Registry: `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock\AllowDevelopmentWithoutDevLicense = 1` (DWORD)
- Requires elevated PowerShell and a reboot. Enables sideloading + symlinks without admin.
- Non-fatal if skipped — V1 runs with a warning if user declines UAC.

### Installer pattern
1. Detect install type (MSIX vs standard on Windows).
2. Kill Claude Desktop process.
3. Timestamped backup of existing `claude_desktop_config.json` + `developer_settings.json`.
4. Write new configs.
5. On Windows, optionally flip `AllowDevelopmentWithoutDevLicense` (admin + reboot prompt).
6. Relaunch Claude Desktop.

### Sources
- MCP debugging docs: https://modelcontextprotocol.io/docs/tools/debugging
- MCP local servers setup: https://modelcontextprotocol.io/docs/develop/connect-local-servers
- anthropics/claude-code#26073 (MSIX vs standard path split)
