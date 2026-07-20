# Todo — Claude Installer

**Last updated:** 2026-07-20

---

## NEXT: commit, release, field test

Everything below is built and verified locally but UNCOMMITTED in both repos.

- [x] Commit claude-installer (36af436 assess.sh + harness, acb29f7 installer fixes + .bat, 0fd6820 memory files)
- [x] Push claude-installer (7510d65 on origin/main, one-liners live)
- [x] claude-templates committed, pushed, v0.2.0 tagged. Release workflow green: all 10 bundles + checksums attached.
- [ ] Field testing: 3 sessions (~60 min total) per the HTML guide artifact "Claude Installer Field Test Guide" (claude.ai/code/artifact/4fa157aa-9078-4355-8569-92f9476bac35): fresh Win11, macOS (first bash 3.2 run of assess.sh), Tom's QCC box (assess only)
- [ ] Optional: GitHub Actions CI matrix (windows-latest + macos-latest run assess + harness on every push) — offered, not yet wired

## assess.ps1 (health check) — V1 built

Merged to `main`. Read-only machine assessment: 7 check categories, maturity + readiness rollups, console + JSON output. 42 Pester tests passing. See `docs/prerequisites.md` and the design doc.

- [x] V1 built and verified on Ben's laptop (10s scan, Level 1, all categories, JSON written, no config writes)
- [x] Merge `assess-v1` to `main` (pushed as of e451663)
- [ ] Fresh Windows 11 VM test — must hit Level 0 with zero uncaught exceptions on a truly clean install
- [ ] Old/messy real-machine test (Tom's QCC box) — surface edge cases on an established, cluttered machine

## assess.sh (macOS health check) — built 2026-07-20, needs real-Mac run

Full port of assess.ps1: same finding IDs, maturity levels, readiness gates, JSON schema. bash 3.2 compatible, no jq/python/timeout deps, probes isolated in `probe_*` functions for stubbing. Built + adversarially reviewed by 16-agent workflow (41 findings, 18 blocker/major fixed: BOM handling, fail-closed MDM, crash-safe check dispatch, dead-mount watchdogs, secret-safe temp files, case-insensitive MCP match).

- [x] `installer/assess.sh` written and hardened
- [x] `tests/test-assess-sh.sh` — pure-bash harness, 137 tests passing on Linux
- [ ] First run on real macOS /bin/bash 3.2 (field test session B)

---

## Blockers (all cleared)

- [x] ~~Verify silent-install flags for Claude Desktop on Windows (.exe) + macOS (.dmg)~~ — see `docs/decisions.md`. winget + brew cask primary, direct download fallback.
- [x] ~~Find where Claude Desktop stores its Developer Mode flag~~ — see `docs/decisions.md`. `developer_settings.json` controls DevTools; Developer tab auto-appears when `claude_desktop_config.json` exists. Gap: confirm the tab on clean VM.
- [x] ~~Create `engineai-nz/claude-templates` public repo~~ — live at https://github.com/engineai-nz/claude-templates
- [x] ~~Create `engineai-nz/claude-installer` public repo and push this project~~ — live at https://github.com/engineai-nz/claude-installer

## V1 build — installer

- [x] `installer/install.sh` — macOS entry point with 8-phase flow
- [x] install.sh parity fixes (2026-07-20): quit-and-poll before config write (the Electron config-wipe bug, macOS side), children run with stdin detached so `curl | bash` survives interactive installers, df guard, unguarded `open -a` no longer fails a good install
- [x] `installer/install.ps1` — Windows equivalent (MSIX-aware, handles winget)
- [x] `installer/install.bat` — double-click wrapper: self-elevates, ExecutionPolicy bypass scoped to child only, optional SHA256 pin, pauses on exit (2026-07-20, never field-tested)
- [x] Flag parsing: `--industry <name> --stack <google|microsoft>` — both installers now accept all five industries
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
- [x] `finance`, `investment`, `property-development`, `small-business` scaffolded (2026-07-20): manifest + mcp.json ({{PLACEHOLDER}} tokens only, verified-real MCP servers) + README + starter skill each. build-bundles.py now auto-discovers industries with a manifest.json; all 10 bundles build clean locally.
- [x] v0.2.0 tagged and released: 10 bundles + checksums.txt attached, workflow green (2026-07-20)

## V1 acceptance test

- [x] Windows 11 real-machine test (Ben's laptop, build 26200) — surfaced 5 bugs, all fixed, all 14 MCPs load, no banner
- [ ] Fresh Windows 11 VM — paste one-liner, works end-to-end in under 5 minutes on a truly clean install
- [ ] Fresh macOS VM (Intel + ARM if practical) — same
- [ ] Run on Tom's QCC machine as real-world smoke test

## Content buildout (parallel track, not V1 blocker)

- [ ] Research: what apps do property agents actually use day-to-day?
- [ ] Per-industry: fill in real skills + MCPs per `docs/plans/mcp-coverage-map.md`
- [ ] Publish script: `scripts/publish-to-public.sh <industry>` — copy from private factory to public templates repo

## Post-V1 / later

- [ ] Post-install auth wizard (walks user through top 5 OAuth/API-key setups)
- [ ] `install.engineai.co.nz` Vercel redirect for cleaner one-liner URL
  - New Vercel project with `vercel.json` redirects: `/` and `/win` → raw install.ps1, `/mac` → raw install.sh
  - Add custom domain in Vercel, CNAME `install` → Vercel target at registrar
  - Client-facing commands become: `irm install.engineai.co.nz | iex` (Win) / `curl -fsSL install.engineai.co.nz/mac | bash` (Mac)
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
- 2026-04-18 — Windows 11 real-machine test on Ben's laptop: surfaced and fixed 5 bugs (Debug collision, multi-hyphen fn names, em-dash console mangling, JSON backslash escaping, UTF-8 BOM). All 14 MCPs load in Claude Desktop, banner clear.
- 2026-04-18 — Hardened Phase 7 to poll until Claude Desktop fully exits (Electron helpers); added Find-ClaudeDesktopExe for versioned install-path discovery.
