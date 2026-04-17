# Todo — Claude Installer

**Last updated:** 2026-04-17

---

## Blockers (all cleared)

- [x] ~~Verify silent-install flags for Claude Desktop on Windows (.exe) + macOS (.dmg)~~ — see `docs/decisions.md`. winget + brew cask primary, direct download fallback.
- [x] ~~Find where Claude Desktop stores its Developer Mode flag~~ — see `docs/decisions.md`. `developer_settings.json` controls DevTools; Developer tab auto-appears when `claude_desktop_config.json` exists. Gap: confirm the tab on clean VM.
- [x] ~~Create `engineai-nz/claude-templates` public repo~~ — live at https://github.com/engineai-nz/claude-templates
- [x] ~~Create `engineai-nz/claude-installer` public repo and push this project~~ — live at https://github.com/engineai-nz/claude-installer

## V1 build — installer

- [x] `installer/install.sh` — macOS entry point with 8-phase flow
- [x] `installer/install.ps1` — Windows equivalent (MSIX-aware, handles winget)
- [x] Flag parsing: `--industry <name> --stack <google|microsoft>`
- [x] Manifest resolver moved factory-side (pre-merged bundles — see `docs/decisions.md`)
- [x] Backup system: timestamped copy + `restore.{sh,ps1}` in backup folder
- [x] Logging to `~/.engineai-installer/logs/`
- [x] Idempotent re-run behaviour (detects existing Claude Desktop / Code installs, skips)
- [x] README with copy-paste one-liners
- [ ] Screenshots in README (post-V1 acceptance test)
- [ ] `installer/lib/` refactor — not needed with monolithic scripts; revisit if scripts grow past 700 lines

## V1 build — templates repo

- [x] `core/primitives/mcp.json` — 5 MCPs: desktop-commander, filesystem, fetch, playwright, chrome-devtools
- [x] `stacks/google/`, `stacks/microsoft/`, `stacks/neutral/` — Tier 2 stubs
- [x] `industries/property/manifest.json` + `mcp.json` + stub skill
- [x] `claude-code-settings/` — baseline settings + tight permissions
- [x] `scripts/build-bundles.py` — factory-side merge + tarball
- [x] `.github/workflows/release.yml` — tag push → build → attach to release
- [x] v0.1.0 tagged and released with property-google + property-microsoft tarballs
- [ ] Placeholder folders for `finance`, `investment`, `property-development`, `small-business` — scaffold later when content is ready

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

- 2026-04-17 — V1 design doc locked and committed
- 2026-04-17 — Silent-install research logged (winget + brew cask primary paths)
- 2026-04-17 — Dev-mode-flag research logged (known gap on Developer tab — VM verify needed)
- 2026-04-17 — `engineai-nz/claude-installer` public repo created and pushed
- 2026-04-17 — `engineai-nz/claude-templates` public repo created with directory scaffold
- 2026-04-17 — Claude Code CLI install path researched (native installer, no Node dep)
- 2026-04-17 — Bundle architecture changed: factory-side pre-merge (Option 2 in session notes) — see decisions.md
- 2026-04-17 — Templates content stubbed out: 5 primitives, 2 stacks + neutral, 1 industry, 1 stub skill, baseline settings
- 2026-04-17 — `scripts/build-bundles.py` + `.github/workflows/release.yml` live
- 2026-04-17 — `install.sh` (macOS) + `install.ps1` (Windows) written — 8 phases each
- 2026-04-17 — claude-templates v0.1.0 released with `property-google.tar.gz` and `property-microsoft.tar.gz` attached
- 2026-04-17 — Smoke tested end-to-end: download bundle → unpack → sed-substitute → 14 MCPs merged correctly
