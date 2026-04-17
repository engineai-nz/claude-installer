# Claude Installer

One-command installer that takes a clean Mac or Windows machine from zero to **Claude Desktop + Claude Code CLI + Engine AI skills and MCP servers**, pre-configured for a chosen industry.

Built by [Engine AI](https://engineai.co.nz) for non-technical clients. No dev tools required on the target machine.

---

## Status

**V1 in development.** Design locked, implementation in progress.

See [docs/plans/2026-04-17-claude-installer-design.md](docs/plans/2026-04-17-claude-installer-design.md) for the full design.

---

## How it will work (V1)

**macOS:**
```bash
curl -fsSL https://raw.githubusercontent.com/engineai-nz/claude-installer/main/install.sh | bash -s -- --industry property --stack google
```

**Windows (PowerShell):**
```powershell
iwr https://raw.githubusercontent.com/engineai-nz/claude-installer/main/install.ps1 | iex
```

The installer will:
1. Preflight checks (OS version, admin rights, existing installs)
2. Backup any existing Claude config with a timestamp
3. Silent-install Claude Desktop + Claude Code CLI
4. Write `claude_desktop_config.json` with the primitive + stack + industry MCP bundle
5. Copy Engine AI skills to `~/.claude/skills/`
6. Enable Developer Mode (Claude Desktop + Windows OS level)
7. Launch Claude Desktop and print next steps

---

## Bundle architecture

Three tiers, composable:

1. **Primitives** (always installed) — Chrome MCP, Desktop Commander, Filesystem, Playwright, Fetch
2. **Stack** (pick one: `--stack google | microsoft | mixed`) — Drive+Gmail+Gcal+Meet vs OneDrive+Outlook+Ocal+Teams
3. **Industry add-ons** (`--industry property | finance | ...`) — stack-neutral SMB tools plus industry-specific MCPs

Content lives in [engineai-nz/claude-templates](https://github.com/engineai-nz/claude-templates).

---

## Target platforms

- macOS 12+ (Monterey or later)
- Windows 10 1903+ / Windows 11
- Native only. No WSL on Windows — target users aren't developers.

---

## Licence

TBA.
