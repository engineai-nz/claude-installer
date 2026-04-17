# Claude Installer — Design
**Date:** 2026-04-17
**Status:** Approved for V1 build
**Owners:** Ben du Chateau, Joe Ward

---

## 1. Purpose

A shell-based installer that takes a non-technical client machine from "clean" to "Claude Desktop + Claude Code CLI fully configured for Engine AI work" in a single command.

**Primary operator:** Ben on-site, pasting the one-liner at the client's keyboard.
**Secondary target:** self-serve clients, later. V1 design must not lock out the self-serve path.

---

## 2. Target users

- Non-power-users. Small-to-medium business owners and staff.
- Full admin on their own machine.
- **Out of scope:** corporate/IT-locked environments, WSL/dev-machine setups, remote/unattended installs.

---

## 3. What gets installed

| Layer | Windows | macOS |
|---|---|---|
| Claude Desktop (GUI) | silent `.exe` install | silent `.dmg` install |
| Claude Code CLI | native | native |
| `claude_desktop_config.json` | `%APPDATA%\Claude\` | `~/Library/Application Support/Claude/` |
| `~/.claude/` config (skills, settings, permissions) | same | same |
| Industry bundle | from public templates repo | same |

Windows Claude Code runs natively. **No WSL setup.** Clients aren't devs.

---

## 4. Repo architecture

Three repos, three roles:

| Repo | Visibility | Purpose |
|---|---|---|
| `engineai-nz/claude-installer` | public | Installer scripts (this project) |
| `engineai-nz/claude-templates` | **new, public** | Publish-ready industry bundles clients install |
| `engineai-nz/claude-business-templates` | private (existing) | Factory: template builder, tester, Ben/Joe dev workflow |

**Flow:** build/test templates in private factory → publish to public templates repo via script → clients install from public.

### Installer repo layout

```
claude-installer/
├── installer/
│   ├── install.sh                  # macOS entry point
│   ├── install.ps1                 # Windows entry point
│   └── lib/
│       ├── detect-os.{sh,ps1}
│       ├── install-desktop.{sh,ps1}
│       ├── install-code.{sh,ps1}
│       ├── write-config.{sh,ps1}
│       ├── bundle-skills.{sh,ps1}
│       └── backup.{sh,ps1}
├── docs/
│   └── plans/                      # This file lives here
├── .github/workflows/release.yml
├── CLAUDE.md
└── README.md
```

### Templates repo layout

```
claude-templates/
├── core/
│   └── primitives/                 # Tier 1 - always installed
│       ├── chrome-mcp/
│       ├── desktop-commander/
│       ├── filesystem/
│       ├── playwright/
│       └── fetch/
├── stacks/
│   ├── google/                     # Tier 2a - Drive, Gmail, Gcal, Meet
│   ├── microsoft/                  # Tier 2b - OneDrive, Outlook, Ocal, Teams
│   └── neutral/                    # Stack-agnostic add-ons (Slack, Notion, HubSpot, Xero, etc.)
├── industries/
│   ├── property/
│   │   ├── manifest.json
│   │   └── skills/
│   ├── finance/
│   ├── investment/
│   ├── property-development/
│   └── small-business/
├── claude-code-settings/
│   ├── settings.json               # Baseline ~/.claude/settings.json
│   └── permissions.json            # Pre-approved tool list to reduce prompts
└── README.md
```

---

## 5. MCP bundle architecture (three tiers)

**Tier 1 — Primitives** (always installed; no flag needed)

Cowork's hands. The MCPs that let it *do* things.

- Chrome MCP — web automation, form fill, research
- Desktop Commander — file ops, scripts, processes
- Filesystem MCP — tighter local read/write
- Playwright MCP — programmatic browser automation
- Fetch — HTTP

**Tier 2 — Stack** (`--stack google | microsoft | mixed`)

Picked once per client based on what their business actually uses.

| Need | Google | Microsoft |
|---|---|---|
| Files | Drive | OneDrive/SharePoint |
| Email | Gmail | Outlook |
| Calendar | Google Cal | Outlook Cal |
| Meetings | Meet | Teams |

**Tier 3 — Industry add-ons** (declared in industry manifest)

Stack-neutral business tools (Slack, HubSpot, Notion, Xero) + industry-specific MCPs (Trade Me for property, market data for finance, etc.).

### Manifest shape

```json
{
  "industry": "property",
  "version": "1.0.0",
  "add_ons": ["slack", "hubspot", "notion"],
  "industry_mcps": {
    "trade-me": { "command": "npx", "args": ["-y", "@engineai/mcp-trade-me"] }
  },
  "skills": ["property-skill-a", "property-skill-b"]
}
```

### MCP roadmap (from content track)

See `docs/plans/mcp-coverage-map.md` for the full list of 9 high-value SMB MCPs to build out per stack.

**Note on quality:** MCP ecosystem moves weekly. Manifests stay loose so MCPs can be swapped without installer code changes. Verify current state at deployment.

---

## 6. Install flow

One flow, two syntaxes (bash + PowerShell). Total runtime: under 5 minutes on decent connection.

### Phase 1 — Preflight (~5s)

1. Detect OS + architecture
2. Check existing installs (Claude Desktop present? Code CLI? Configs?)
3. Validate internet connectivity
4. Print plan: "Will install X, Y. Will back up Z."

### Phase 2 — Backup (~2s)

1. Copy existing configs to `~/.engineai-installer/backups/YYYY-MM-DD-HHMMSS/`
2. Write `restore.sh` / `restore.ps1` into that folder

### Phase 3 — System toggles (~10s, may trigger UAC/sudo)

1. Detect elevation
2. If not elevated, re-launch elevated (Windows: `Start-Process -Verb RunAs`; macOS: `sudo`)
3. **Windows:** enable OS Developer Mode via registry
4. Flip Claude Desktop Developer Mode flag in its config file
5. Drop privileges for the rest of the install

### Phase 4 — Download bundle (~10s)

1. Hit GitHub API for latest tag of `engineai-nz/claude-templates`
2. Download release zip → `~/.engineai-installer/bundle/<version>/`
3. Verify chosen industry manifest exists

### Phase 5 — Install Claude Desktop (~60–120s)

1. If not present, download `.dmg` / `.exe` from claude.ai
2. Silent install
3. Verify binary exists

### Phase 6 — Install Claude Code CLI (~30s)

1. If not present, run official install script (native, no WSL on Windows)
2. Verify `claude --version`

### Phase 7 — Write configs (~2s)

1. Merge primitives + chosen stack + industry add-ons → `claude_desktop_config.json`
2. Copy skills to `~/.claude/skills/`
3. Copy `settings.json` + `permissions.json` → `~/.claude/`

### Phase 8 — Finish (~5s)

1. Launch Claude Desktop
2. Print next steps: "Sign in → click Cowork tab → done"

---

## 7. Distribution

**V1 one-liners** (hosted on raw GitHub):

```bash
# macOS
curl -fsSL https://raw.githubusercontent.com/engineai-nz/claude-installer/main/installer/install.sh | bash -s -- --industry property --stack microsoft

# Windows (PowerShell, admin)
iwr https://raw.githubusercontent.com/engineai-nz/claude-installer/main/installer/install.ps1 | iex; Install-EngineAI -Industry property -Stack microsoft
```

**Defaults when no flags given:** installs primitives + stack-neutral minimum (Chrome, Desktop Commander, Drive *or* OneDrive based on auto-detection). Industry = none.

**Later (not V1):** point `install.engineai.co.nz` via Vercel redirect for a cleaner URL.

---

## 8. Safety

### Backups

Every overwrite creates a timestamped backup in `~/.engineai-installer/backups/`. Includes a self-contained restore script.

### Permissions

Ship `permissions.json` with pre-approved tools (Read, Write, Edit, Glob, Grep, safe Bash commands). Blocks `sudo`, `curl | bash`, dangerous wildcards. Reduces prompt spam for non-power-users on first use of Claude Code.

### Failure modes

| Failure | Behaviour |
|---|---|
| No internet | Bail early, clean |
| Desktop download fails | Bail, state untouched |
| Code CLI install fails | Continue, report partial success |
| Config write fails | Roll back from backup |
| Skill copy fails | Continue, log, summarise |
| Unknown industry | Refuse, list available |
| Elevation refused | Continue with warning, skip dev mode |

### Idempotency

Re-running = safe. Detects existing installs, skips downloads, re-syncs configs. "Repair" mode is default mode.

### Auth / credentials

MCPs needing OAuth or API keys get written with `{{PLACEHOLDER}}` tokens. Post-install auth wizard is **V2**. For V1: Ben handles top 3-5 credentials in-person during the on-site visit.

### Logging

All actions → `~/.engineai-installer/logs/YYYY-MM-DD-HHMMSS.log`. `engineai-installer --logs` tails latest.

---

## 9. Release & versioning

| Repo | Tag | Effect |
|---|---|---|
| `claude-installer` | `v1.x.x` | GitHub Actions builds release; one-liner `main` branch points at latest |
| `claude-templates` | `v1.x.x` | GitHub Actions builds release zip; installer fetches `latest` at install time |

Installer version ≠ templates version. Independent release cadences.

**Publish flow (private factory → public templates):**

1. Template passes QA in `claude-business-templates`
2. Run `scripts/publish-to-public.sh <industry>` → copies into `claude-templates`, strips drafts
3. Tag + push → GitHub Action builds release zip

---

## 10. V1 shipping criteria

- [ ] `engineai-nz/claude-installer` public repo live, `install.sh` + `install.ps1` working
- [ ] `engineai-nz/claude-templates` public repo live, `property/` folder with stub skills
- [ ] Installs Claude Desktop + Claude Code CLI silently on fresh Windows 11 VM
- [ ] Same on fresh macOS VM (Intel + ARM if practical)
- [ ] Writes `claude_desktop_config.json` with Tier 1 primitives + Microsoft stack
- [ ] Copies skills to `~/.claude/skills/`
- [ ] Flips Claude Desktop dev mode + Windows OS dev mode (admin path)
- [ ] Backs up existing configs
- [ ] Launches Claude Desktop on finish
- [ ] Prints clear next-steps message
- [ ] README with copy-paste one-liner + screenshot

**V1 acceptance test:** Tom's machine (QCC) or a fresh VM. Paste one-liner. 5 minutes later, Claude Desktop open, Ben signs Tom in, it works.

---

## 11. Explicitly out of V1

| Item | When |
|---|---|
| Real content for `property` (beyond stubs) | Content buildout track (parallel) |
| Other industries | Post-V1, one at a time |
| `.bat` wrapper for double-click install | When self-serve demand appears |
| `install.engineai.co.nz` custom domain | Before public rollout |
| Post-install auth wizard | V2 |
| Automated Cowork activation | Not possible (GUI-only), always manual |
| Skill upload to Claude Desktop Settings/Projects | When Anthropic ships a filesystem/API for it |
| Remote/unattended install | Future |
| Corporate IT environments | Different product |
| Version pinning per client | If support load demands |
| GUI installer (.exe/.msi) | If a specific client needs it |
| Multi-industry bundles per install | Future |

---

## 12. Estimated V1 build

2-3 focused sessions. Most complexity is platform quirks (silent install flags, path differences, admin elevation), not logic.

---

## 13. Dependencies to create before V1 build starts

1. Public repo: `engineai-nz/claude-templates` (empty scaffolding OK)
2. Public repo: `engineai-nz/claude-installer` (this project, push when ready)
3. Decision on silent install methods for Claude Desktop on both OSes (verify flags exist)
4. Verification of Claude Desktop Developer Mode storage location (for programmatic toggle)
