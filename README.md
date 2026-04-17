# Claude Installer

One-command installer that takes a clean Mac or Windows machine from zero to **Claude Desktop + Claude Code CLI + Engine AI skills and MCP servers**, pre-configured for a chosen industry.

Built by [Engine AI](https://engineai.co.nz) for non-technical clients. No dev tools required on the target machine.

---

## Usage

### macOS

```bash
curl -fsSL https://raw.githubusercontent.com/engineai-nz/claude-installer/main/installer/install.sh | bash -s -- --industry property --stack microsoft
```

### Windows (PowerShell)

```powershell
iwr https://raw.githubusercontent.com/engineai-nz/claude-installer/main/installer/install.ps1 -OutFile $env:TEMP\install.ps1
& $env:TEMP\install.ps1 -Industry property -Stack microsoft
```

Both accept `--industry` / `-Industry` and `--stack` / `-Stack`. V1 supports `property` and `microsoft | google`.

---

## What it does (8 phases, under 5 min)

1. **Preflight** — OS version, architecture, connectivity, existing installs
2. **Backup** — timestamped copy of any existing Claude config to `~/.engineai-installer/backups/`
3. **Download bundle** — pulls the `(industry, stack)` tarball from [claude-templates releases](https://github.com/engineai-nz/claude-templates/releases)
4. **Install Node.js** — required runtime for MCP servers (via Homebrew / winget)
5. **Install Claude Desktop** — silent install via Homebrew cask / winget
6. **Install Claude Code CLI** — official installer (`curl | bash` / `iwr | iex`)
7. **Write configs** — drops pre-merged `claude_desktop_config.json`, `developer_settings.json`, skills, and Claude Code settings into place
8. **Launch** — opens Claude Desktop and prints next steps

Every step is logged to `~/.engineai-installer/logs/`. Every config overwrite is backed up with a timestamped `restore.sh` / `restore.ps1`.

---

## Bundle architecture

The installer downloads pre-merged bundles from the [claude-templates](https://github.com/engineai-nz/claude-templates) repo. Each bundle is built from three tiers:

1. **Primitives** (always) — Desktop Commander, Filesystem, Fetch, Playwright, Chrome DevTools
2. **Stack** (Google or Microsoft) — Drive+Gmail+Gcal+Meet vs OneDrive+Outlook+Ocal+Teams
3. **Industry add-ons** — stack-neutral SMB tools (Slack, Notion, HubSpot, Xero) plus industry-specific MCPs

Source is tiered for maintainability; distribution is pre-merged for install simplicity.

---

## Target platforms

- macOS 12+ (Monterey or later)
- Windows 10 1903+ / Windows 11 (native, no WSL)
- 64-bit only (x86_64 / arm64 on Mac; AMD64 / ARM64 on Windows)

---

## Not in V1

- Post-install OAuth / API key wizard (V2)
- Automated Cowork tab activation (not scriptable — always manual)
- Skill upload to Claude Desktop Settings/Projects (API doesn't exist yet)
- Remote / unattended installs
- Corporate IT environments (different product)

---

## Related repos

| Repo | Visibility | Role |
|---|---|---|
| [engineai-nz/claude-installer](https://github.com/engineai-nz/claude-installer) | public | This repo — installer scripts |
| [engineai-nz/claude-templates](https://github.com/engineai-nz/claude-templates) | public | Publish-ready industry bundles |
| [engineai-nz/claude-business-templates](https://github.com/engineai-nz/claude-business-templates) | private | Factory where templates are built and tested |

---

## Licence

TBA.
