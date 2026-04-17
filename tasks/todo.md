# Todo — Claude Installer

**Last updated:** 2026-04-17

---

## Blockers (do first)

- [ ] Verify silent-install flags for Claude Desktop on Windows (.exe) + macOS (.dmg)
- [ ] Find where Claude Desktop stores its Developer Mode flag (both OSes) — so installer can flip it programmatically
- [ ] Create `engineai-nz/claude-templates` public repo (empty scaffold OK for now)
- [ ] Create `engineai-nz/claude-installer` public repo and push this project

## V1 build — installer

- [ ] `installer/install.sh` — macOS entry point with phased flow (preflight → backup → sys toggles → download → install Desktop → install Code → write configs → launch)
- [ ] `installer/install.ps1` — Windows equivalent, including UAC re-launch for dev mode registry write
- [ ] `installer/lib/` — shared helpers: detect-os, backup, write-config, bundle-skills
- [ ] Flag parsing: `--industry <name> --stack <google|microsoft|mixed>`
- [ ] Manifest resolver: merge primitives + stack + industry add-ons into final `claude_desktop_config.json`
- [ ] Backup system: timestamped copy + `restore.{sh,ps1}` in backup folder
- [ ] Logging to `~/.engineai-installer/logs/`
- [ ] Idempotent re-run behaviour (detect existing installs, skip, re-sync)
- [ ] README with copy-paste one-liners + screenshots

## V1 build — templates repo

- [ ] `core/primitives/` — stub MCP configs for Chrome MCP, Desktop Commander, Filesystem, Playwright, Fetch
- [ ] `stacks/google/`, `stacks/microsoft/` — stub MCP configs for the split Tier 2 tools
- [ ] `industries/property/manifest.json` — minimal manifest for V1 acceptance test
- [ ] `industries/property/skills/` — 2-3 stub skills
- [ ] Placeholder folders for `finance`, `investment`, `property-development`, `small-business`
- [ ] `claude-code-settings/` — baseline `settings.json` + `permissions.json` (pre-approved safe tools)
- [ ] GitHub Actions release workflow → zip + tag

## V1 acceptance test

- [ ] Fresh Windows 11 VM — paste one-liner, works end-to-end in under 5 minutes
- [ ] Fresh macOS VM (Intel + ARM if practical) — same
- [ ] Run on Tom's QCC machine as real-world smoke test

## Content buildout (parallel track, not V1 blocker)

- [ ] Research: what apps do property agents actually use day-to-day?
- [ ] Per-industry: fill in real skills + MCPs per `docs/plans/mcp-coverage-map.md`
- [ ] Publish script: `scripts/publish-to-public.sh <industry>` — copy from private factory to public templates repo

## Post-V1 / later

- [ ] Post-install auth wizard (walks user through top 5 OAuth/API-key setups)
- [ ] `install.engineai.co.nz` Vercel redirect for cleaner one-liner URL
- [ ] `.bat` wrapper for double-click install on Windows (self-serve path)
- [ ] Skill upload to Claude Desktop Settings / Projects when Anthropic ships an API
- [ ] Remote/unattended install mode
- [ ] Version pinning per client

## Done

-
