# CLAUDE.md — Claude Installer

**Project:** Claude Installer
**Owner:** Engine AI (Ben du Chateau + Joe Ward)
**Last updated:** 2026-04-17

---

## 1. Purpose

A shell-based installer that takes a non-technical client machine from "clean" to **Claude Desktop + Claude Code CLI + Engine AI skills and MCP servers** in a single command. Runs on Mac and Windows (native, no WSL).

Primary operator for V1: Ben on-site. Self-serve clients is a later goal — V1 design must not close that door.

Full design: `docs/plans/2026-04-17-claude-installer-design.md`.

---

## 2. Stakeholders

| Role | Person |
|---|---|
| Engineering / owner | Ben du Chateau |
| Co-founder / content | Joe Ward |
| End users | Engine AI clients (SMB, non-power-users, full admin on own machine) |

---

## 3. Stack

- **Bash** (`install.sh`) for macOS
- **PowerShell** (`install.ps1`) for Windows
- **No Node, no Python** — keep the client machine prerequisites at zero
- Delivery: `curl | bash` and `iwr | iex` one-liners hosted on raw GitHub

---

## 4. Related repos

| Repo | Visibility | Role |
|---|---|---|
| `engineai-nz/claude-installer` (this) | public | Installer code |
| `engineai-nz/claude-templates` | **new, public** — to create | Publish-ready industry bundles |
| `engineai-nz/claude-business-templates` | private (existing) | Dev factory for templates |

Installer reads from `claude-templates`. Factory → publish script → public templates.

---

## 5. Bundle architecture (three tiers)

1. **Primitives** (always) — Chrome MCP, Desktop Commander, Filesystem, Playwright, Fetch
2. **Stack** (`--stack google | microsoft`) — Drive+Gmail+Gcal+Meet vs OneDrive+Outlook+Ocal+Teams
3. **Industry add-ons** (from manifest) — stack-neutral SMB tools (Slack, HubSpot, Notion, Xero) + industry-specific MCPs

Target industries: `property`, `finance`, `investment`, `property-development`, `small-business`.

---

## 6. V1 scope

- Silent install Claude Desktop + Claude Code CLI on Mac + Windows
- Write `claude_desktop_config.json` with primitives + chosen stack
- Copy skills to `~/.claude/skills/` (Claude Code only — Desktop Skills bridge is post-V1)
- Flip Claude Desktop Developer Mode + Windows OS Developer Mode (admin path)
- Backup existing configs before overwrite
- Launch Claude Desktop on finish, print next steps (sign in, click Cowork)
- One industry: `property` with stub skills to prove the pipeline

**Explicitly out of V1:** real content, post-install auth wizard, custom domain, `.bat` wrapper, remote install, corporate IT environments, automated Cowork activation (GUI-only).

---

## 7. Primary constraints

- **No secrets in the repo.** MCP configs ship with `{{PLACEHOLDER}}` tokens. Credentials happen post-install.
- **Target users are non-devs.** No CLI prerequisites on the client machine. Sensible defaults. Zero questions where possible.
- **Never overwrite existing Claude Desktop / Claude Code config without a timestamped backup.**
- **Don't assume corporate IT access.** Assume personal/SMB machines with full admin. If that's not the case, bail gracefully.
- **Manifests stay loose.** MCP ecosystem moves weekly — swap MCPs without touching installer code.

---

## 8. Conventions

- NZ English (organisation, colour, optimise)
- Python for utility scripts, not bash. Don't assume `jq`, `fzf`, etc.
- No em dashes in user-facing output (AI tell)
- Lowercase filenames, no spaces

---

## 9. Memory files

| File | Purpose |
|---|---|
| `tasks/todo.md` | Active work + next actions |
| `tasks/lessons.md` | Gotchas, client-machine weirdness, platform quirks |
| `docs/decisions.md` | Architecture + strategic decisions with rationale |
| `docs/plans/` | Design docs and roadmaps |

**Start of session:** read todo + lessons, summarise state in 3 sentences.
**End of session:** update todo, log lessons + decisions.

---

## 10. Links

- GitHub org: https://github.com/engineai-nz
- Private templates factory: https://github.com/engineai-nz/claude-business-templates
- Parent config: `~/.claude/CLAUDE.md` (global operator config)
