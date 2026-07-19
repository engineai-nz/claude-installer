# Design: assess.ps1 - Engine AI Claude Health Check

**Date:** 2026-07-19
**Status:** Approved by Ben, pre-implementation
**Owner:** Ben du Chateau

---

## 1. Problem

Most prospective customers already use Claude, badly. They are web-only or bare-Desktop users: no MCP servers, no drive access, no Cowork, no skills. Engine AI engagements start by finding out where a customer is at, on their machine, without breaking anything.

A second, growing problem is the machines themselves. Customer laptops are frequently old, low on memory, unpatched, missing admin access, or company-managed. An install that should take 30 minutes can eat half a day. Engine AI needs to know what it is dealing with before committing billable time.

## 2. What we are building

A single read-only PowerShell script (`installer/assess.ps1`) that Ben pastes into a customer machine during a remote session. In under 30 seconds it:

1. Maps the customer's Claude setup (Desktop, Code, MCPs, skills)
2. Maps their data landscape (OneDrive, Google Drive, mapped drives)
3. Detects their work stack (Microsoft vs Google) and installed business apps
4. Assesses the machine itself (OS support status, hardware, admin, patching, MDM)
5. Prints a scored terminal summary Ben talks through live
6. Writes a JSON report Ben takes back to Engine AI

Plus one companion deliverable: `docs/prerequisites.md`, a customer-facing one-pager sent before any engagement is booked.

**Engagement flow:** prereq sheet sent -> remote session -> paste one-liner -> talk through terminal summary live -> grab JSON -> proposal generated at Engine AI -> return visit runs install.ps1.

## 3. Decisions

| Decision | Choice | Why |
|---|---|---|
| Delivery | Ben drives via remote session; no phone-home | Matches real engagements; no consent/endpoint infra needed; nothing leaves the machine |
| Scan scope | Full opportunity scan (Claude + environment + business apps + machine health) | The findings are the sales artifact; all read-only |
| Output | Terminal summary + JSON file | Presentation layer stays at Engine AI (proposals pipeline); scan stays minimal on the customer machine |
| Repo shape | Same repo, new tool alongside install.ps1 | Assess is stage 1, install is stage 2 of the same engagement; lessons (BOM, MSIX paths, config dirs) carry over |
| Architecture | Check registry: each check is a small function returning a standard finding object; a runner renders console + JSON from the same objects | Check list grows monthly; adding a check = adding one function; JSON schema falls out for free |
| Platform | Windows only for V1 | Windows is the declared tier-1 platform; assess.sh follows after real-customer shakedown |

## 4. Check catalogue (V1)

Seven categories. Each check is a function named `Test-*` returning one or more finding objects.

### 4.1 claude-desktop
- Installed: standard (`%LOCALAPPDATA%\AnthropicClaude`), MSIX (`Get-AppxPackage *Claude*`), or none
- Version parsed from the `app-<version>` folder name
- Config dir resolved (standard vs MSIX LocalCache path)
- `claude_desktop_config.json`: exists, parses as JSON, BOM check
- `mcpServers`: count and server names
- `developer_settings.json` present
- Claude Desktop currently running (process check only, never touched)
- Sign-in state: NOT checked (not reliably detectable; out of scope)

### 4.2 claude-code
- `claude` on PATH or at `~\.claude\bin\claude.exe`
- Version (`claude --version`)
- `~\.claude\settings.json` present
- Skills installed under `~\.claude\skills\` (names only)
- `CLAUDE.md` present in `~\.claude\`
- MCPs configured on the Code side (`~\.claude.json` mcpServers, if present)

### 4.3 mcp-runtime
- Node present + version; npx present
- For each configured MCP server (Desktop and Code):
  - Command resolvable (on PATH or absolute path exists)
  - Config contains unfilled `{{PLACEHOLDER}}` tokens (configured-but-dead server: the most common "not using it properly" state)

### 4.4 data-landscape
- OneDrive personal and business (`$env:OneDrive`, `$env:OneDriveCommercial`)
- Known Folder Move: are Desktop/Documents actually redirected into OneDrive
- Google Drive for desktop (mount letter or DriveFS path)
- Dropbox folder
- Mapped network drives (letter, UNC target)
- Output: where this business's files actually live; feeds drive-mapping at install time

### 4.5 work-stack
- Microsoft signals: Office apps installed, Outlook, Teams
- Google signals: Google Drive client, Chrome default browser
- Verdict: `microsoft` | `google` | `mixed` | `unknown`; determines the `-Stack` flag for the later install

### 4.6 opportunity-scan
- Installed business apps matched against a known-apps table baked into the script
- Detection sources: registry uninstall keys (HKLM + HKCU, both bitnesses), Start menu shortcuts, running processes
- App table entries carry `mcpAvailable: true/false` so recommendations write themselves
- Initial table: Slack, Teams, Zoom, Notion, Xero, MYOB, QuickBooks, Dropbox, plus AI-tool signals (ChatGPT desktop, Copilot, Cursor)
- Known limitation (documented in output): web-only apps (HubSpot, most Xero usage) are invisible to V1

### 4.7 machine-health
- OS: edition, build, and support status. Windows 10 reached end of support October 2025; unsupported OS is a hard finding
- Patch state: date of last installed update (Win32_QuickFixEngineering / Windows Update history); flagged as `gap` when no update has installed in 90 days
- Hardware: total RAM, free disk on system drive, CPU model + core count, AMD64 vs ARM64
- Admin reality: current user in Administrators group; can elevate via UAC; machine domain-joined; Intune/MDM-enrolled (corporate-managed detection = documented bail condition, surfaced upfront)
- Install friction: winget present, PowerShell version, execution policy, third-party antivirus product name (Security Center query), pending reboot flag

## 5. Rollups

Two independent rollups. Maturity says where they are; readiness says whether we can take them up and how long it will take.

### 5.1 Claude maturity level (the sales headline)
- **Level 0 - Web only:** no Claude Desktop, no Claude Code
- **Level 1 - Desktop installed:** app present, zero MCPs
- **Level 2 - Partially connected:** some MCPs but broken/placeholder configs or no file access
- **Level 3 - Connected:** working MCPs including filesystem access to where their files actually live
- **Level 4 - Orchestrated:** Level 3 plus Claude Code, skills, and stack integration

### 5.2 Install readiness verdict (the time-protection mechanism)
- **READY:** clean machine, standard install, ~30 min
- **READY WITH FRICTION:** blockers listed with realistic per-blocker time estimates (pending updates, low disk, no winget, aggressive AV)
- **NOT READY:** hard stops with exactly what must change (unsupported OS, no admin, MDM-managed, unsupported architecture). Session ends with "fix these, we rebook" instead of a half-day slog

Readiness criteria mirror `docs/prerequisites.md` so the sheet (the promise) and the scan (the enforcement) cannot drift in spirit.

## 6. Output

### 6.1 Terminal
- Per-category status lines: `[OK]` / `[GAP]` / `[--]` (missing)
- Maturity level + readiness verdict as the closing block
- Generated "What we'd do" list: top 5 recommendations pulled from gap findings
- JSON path printed last

### 6.2 JSON
Written to `~\.engineai-installer\assess\<timestamp>.json`. BOM-less UTF-8.

```json
{
  "schemaVersion": 1,
  "assessVersion": "0.1.0",
  "timestamp": "2026-07-19T14:30:00+13:00",
  "machine": { "hostname": "...", "user": "...", "os": "...", "arch": "..." },
  "maturityLevel": 1,
  "readiness": {
    "verdict": "ready-with-friction",
    "blockers": [ { "id": "machine.patchState", "estimateMinutes": 45 } ]
  },
  "findings": [
    {
      "id": "desktop.mcpServers",
      "category": "claude-desktop",
      "status": "gap",
      "evidence": "config exists, 0 servers",
      "recommendation": "Install MCP bundle"
    }
  ],
  "summary": { "ok": 9, "gap": 6, "missing": 3 }
}
```

Statuses: `ok` | `gap` (present but wrong/incomplete) | `missing` | `info` (neutral evidence, e.g. detected apps). The same finding objects render the terminal and serialise to JSON; no dual bookkeeping.

## 7. Read-only contract

Stated in the script header, enforced by construction:

- No writes outside `~\.engineai-installer\assess\`
- No process kills, no app launches, no installs, no registry writes (registry reads only)
- Never touches Claude while it is running
- One optional network call (connectivity probe for the future install); everything else local
- No file contents read beyond Claude's own config files. Filenames, registry entries, and environment variables only. Nothing from the customer's documents

Trust line for the call: "this reads settings, not your files."

## 8. Delivery mechanics

- One-liner: `irm https://raw.githubusercontent.com/engineai-nz/claude-installer/main/installer/assess.ps1 | iex`
- **Zero parameters.** A `param()` block breaks `iex` piping; anything tunable becomes an env var later if ever needed
- PowerShell 5.1 compatible; TLS 1.2 forced at the top
- All install.ps1 lessons honoured: BOM-less UTF-8 via .NET writer, `.Replace()` not `-replace` for paths, no em dashes in console output, single-hyphen function names
- Must not fatally error on a machine with nothing installed: every check degrades to a `missing` finding, never a crash
- README gets the assess one-liner above the install one-liner (assess is now the engagement entry point)

## 9. docs/prerequisites.md (companion deliverable)

Customer-facing, one page, plain language, no jargon. Sent before booking. Contents:

- Windows 11, or macOS 13 Ventura or newer
- 8 GB RAM minimum (16 GB recommended); 10 GB free disk
- Admin access to the machine (know the admin password)
- Machine not managed by a company IT department, or bring IT sign-off
- Stable internet
- Have passwords ready: Anthropic account, Microsoft or Google account

## 10. Out of scope for V1

- macOS `assess.sh` (follows after Windows survives real customers)
- Web-app usage detection
- Phone-home endpoint / consented telemetry
- HTML report (presentation happens at Engine AI from the JSON)
- Any remediation (that is install.ps1's job)
- Cowork state detection (blocked on the clean-VM investigation of where Cowork state lives)
- Claude Desktop sign-in state detection

## 11. Testing

1. Ben's own laptop: rich setup, should score Level 4 / READY, no errors
2. Fresh Windows 11 VM: should score Level 0 cleanly with zero uncaught exceptions (nothing-installed path is the most fragile)
3. Old/messy real machine (Tom's QCC box): realistic shakedown of machine-health checks and readiness verdict before any customer sees it
4. Verify runtime stays under ~30 seconds on a slow machine (registry uninstall enumeration is the likely offender; cap or optimise if it drags)
