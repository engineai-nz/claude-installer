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

---

## 2026-04-17 — Claude Code CLI install path

Native installer on both platforms. No Node, no npm.

- **macOS:** `curl -fsSL https://claude.ai/install.sh | bash` → installs to `~/.claude/` with launcher at `~/.local/bin/claude`. No admin needed.
- **Windows:** `irm https://claude.ai/install.ps1 | iex` → installs to `%USERPROFILE%\.claude\`. No admin needed. Works in plain PowerShell 5.1+.
- **Auth:** deferred to first run (`claude` triggers browser OAuth). Installer does NOT call `claude login`.
- **PATH:** installer modifies user env; requires a fresh shell after install.

**Rejected alternatives:**
- npm path (`npm install -g @anthropic-ai/claude-code`) — requires Node, bad fit for non-dev clients.
- winget — no published package as of 2026-04-17.
- brew cask `claude-code` — works but adds Homebrew dependency; native installer is faster.

---

## 2026-04-17 — Bundle architecture: pre-merged, not runtime-merged

The design doc called for runtime merging of primitives + stack + industry on the client. We changed to **factory-side pre-merge** for V1.

### Why the change

Client-side merging needs a JSON tool. Python 3 on a clean macOS is a stub that triggers Xcode CLT install on first use (1GB GUI download). PowerShell handles JSON natively, but bash without jq is painful. Awk-based merging is fragile.

Pre-merged bundles move the complexity to the factory, which already has Python/Node/everything. Clients get zero-dep installs.

### Architecture

- **Source layout in `claude-templates` stays three-tier:** `core/primitives/`, `stacks/<name>/`, `industries/<name>/`. Maintainable.
- **`scripts/build-bundles.py`** generates `dist/bundles/<industry>-<stack>.tar.gz` per `(industry, stack)` pair.
- **`.github/workflows/release.yml`** runs the build on tag push and attaches tarballs to the GitHub release.
- **Installer** downloads `https://github.com/engineai-nz/claude-templates/releases/latest/download/<industry>-<stack>.tar.gz`, unpacks, drops files in place, substitutes `{{HOME}}`.

### Trade-offs accepted

- N × M tarballs per release (N industries × M stacks). For V1: 1 × 2 = 2 tarballs. For full coverage: 5 × 2 = 10. Trivial.
- Must tag + wait for release before installer can fetch. OK — not a hot path.
- Placeholder substitution (`{{HOME}}`) is the only client-side templating. Everything else (`{{GOOGLE_CLIENT_ID}}`, etc.) stays in the config for the post-install auth step.

### Runtime Node requirement

MCP servers run via `npx`, which requires Node.js on the client. This is a non-negotiable runtime dependency imposed by the MCP ecosystem, not by our installer. Phase 4 installs Node via Homebrew (macOS) / winget (Windows). Design doc's "no Node prerequisites" referred to installer prereqs, not runtime.

---

## 2026-04-17 — Homebrew required on macOS for V1

`install.sh` uses Homebrew as the primary path for Claude Desktop and Node.js installs. Direct-download fallbacks are best-effort only for V1.

**Why:** brew install is the simplest, most reliable silent install on macOS. Direct-zip install of Claude Desktop requires fetching `RELEASES.json`, parsing the latest version, constructing a hashed URL, `ditto -xk`ing, and `xattr -dr com.apple.quarantine`. Brittle on version bumps. Node.js direct pkg requires `sudo installer` which we'd rather avoid.

**Acceptance-test implication:** V1 acceptance on a fresh macOS VM assumes Homebrew is pre-installed, or Ben installs it on-site before running the installer. Post-V1, bundle Homebrew install as a preflight step if self-serve demand appears.
