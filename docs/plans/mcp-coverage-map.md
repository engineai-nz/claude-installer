# MCP Coverage Map — Content Roadmap
**Date:** 2026-04-17
**Status:** Research / content planning (not V1 installer scope)

Reference for per-industry content buildout. Not a blocker for V1 installer ship — installer ships with stub MCPs and this list guides what fills the slots over time.

---

## Tier 1 — Primitives (always installed, stack-agnostic)

Cowork's operating hands. Non-negotiable.

1. **Chrome MCP** (Claude in Chrome) — web automation. Form filling, research, SaaS tools without APIs, booking, purchasing.
2. **Desktop Commander** — file system ops, running scripts, process management, reading logs.
3. **Filesystem MCP** — tighter/safer read/write. Overlaps with Desktop Commander, worth having both.
4. **Playwright MCP** — heavier/programmatic browser automation beyond interactive Chrome use.
5. **Fetch** — HTTP.

**Minimum viable primitive stack:** Chrome + Desktop Commander + Drive/OneDrive (the bridge).

---

## Tier 2 — Stack-specific (Google vs Microsoft)

6 of the top-9 SMB tools split along these lines. Pick one per client based on what the business already uses.

| Need | Google stack | Microsoft stack |
|---|---|---|
| Files | Drive | OneDrive/SharePoint |
| Email | Gmail | Outlook |
| Calendar | Google Calendar | Outlook Calendar |
| Meetings | Meet (via transcription tools) | Teams |

Roughly 50/50 split across SMBs. Google Workspace vs M365.

---

## Tier 3 — Stack-neutral SMB tools

Declared per industry in the manifest's `add_ons` array.

### Comms
- **Slack** — tech-leaning SMBs
- **Microsoft Teams** — M365-aligned SMBs (note: already in Microsoft stack)

### CRM
- **HubSpot** — SMB skew, simpler API
- **Salesforce** — mid-market skew, more complex setup

### Accounting
- **Xero** — dominates ANZ/UK
- **QuickBooks** — dominates US

### Knowledge
- **Notion** — smaller/newer businesses
- **Confluence** — larger/structured businesses

### Project management
- **Asana**
- **Trello**
- **ClickUp**

### Meeting transcription
- **Fireflies**
- **Otter**
- **Grain**

### Technical / developer-adjacent
- **GitHub MCP**
- **Supabase / Postgres MCPs**

---

## Auth complexity ladder (for the post-install wizard, V2)

**Easy** — single API key paste, 5 minutes:
- Notion, HubSpot, Slack, Linear, Fireflies, Otter, Asana, Trello, ClickUp, GitHub

**Medium** — OAuth through the vendor's portal, 15 minutes:
- Xero, QuickBooks, Salesforce

**Hard** — OAuth app registration, admin consent, 30+ minutes:
- Google Workspace (Drive, Gmail, Calendar, Meet)
- Microsoft 365 (OneDrive, Outlook, Teams)

Hard-tier items should only happen with Ben on-site for V1. Self-serve later if patterns prove repeatable.

---

## Why the primitives list is different from the SMB tools list

The SMB tools list answers: **what apps does the business use that Claude should connect to?**

The primitives list answers: **what does Cowork need to actually act on the machine and the web?**

Primitives are Cowork's engine. SMB tools are the data it reaches for. Both tiers matter, different problems.

---

## Process for each new industry

1. **Business discovery** — what apps/services does this role use daily?
2. **MCP mapping** — for each app, check `modelcontextprotocol.io/servers` + community repos. Mark: exists / needs building / not possible.
3. **Core vs optional split** — 3-5 MCPs every client in this industry gets by default.
4. **Credential strategy** — which need OAuth, which API keys, which Ben handles on-site vs which clients can self-serve.
5. **Manifest write** — `industries/<name>/manifest.json` with add_ons + industry_mcps.

---

## Caveat

MCP ecosystem quality varies and moves weekly. Verify current state at deployment — something better than Desktop Commander (or any other entry here) may exist by then. Installer manifests are deliberately loose so MCPs can be swapped without code changes.
