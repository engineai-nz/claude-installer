#!/usr/bin/env bash
#
# Engine AI Claude Installer - macOS
#
# Installs Claude Desktop + Claude Code CLI, configures MCP servers and
# skills for a chosen industry and productivity stack, and launches Claude
# Desktop. Designed for non-technical clients on personal/SMB Macs.
#
# Usage (one-liner):
#   curl -fsSL https://raw.githubusercontent.com/engineai-nz/claude-installer/main/installer/install.sh | bash -s -- --industry property --stack microsoft
#
# Usage (local):
#   ./installer/install.sh --industry property --stack microsoft

# -E so the ERR trap is inherited by shell functions. Without it every phase
# function would abort silently, because all of the work happens in functions.
set -Eeuo pipefail

# ---------- Constants ----------
INSTALLER_VERSION="0.1.0"
TEMPLATES_REPO="engineai-nz/claude-templates"
WORK_DIR="${HOME}/.engineai-installer"
LOG_DIR="${WORK_DIR}/logs"
BACKUP_ROOT="${WORK_DIR}/backups"
BUNDLE_DIR="${WORK_DIR}/bundle"
CLAUDE_CONFIG_DIR="${HOME}/Library/Application Support/Claude"
CLAUDE_CODE_DIR="${HOME}/.claude"

# ---------- Colour output ----------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_GOLD=$'\033[38;5;179m'
  C_GREEN=$'\033[32m'
  C_RED=$'\033[31m'
  C_YELLOW=$'\033[33m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_GOLD=""; C_GREEN=""; C_RED=""; C_YELLOW=""
fi

# `|| true` because pipefail would otherwise turn an unwritable log file into a
# non-zero return from ok()/warn(), and those are often the last statement in a
# phase function - which under errexit would kill the whole install.
log()  { printf "%s\n" "$*" | tee -a "${LOG_FILE:-/dev/null}" >&2 || true; }
info() { log "${C_DIM}  ${1}${C_RESET}"; }
step() { log ""; log "${C_GOLD}${C_BOLD}==>${C_RESET} ${C_BOLD}$1${C_RESET}"; }
ok()   { log "${C_GREEN}  ✓${C_RESET} $1"; }
warn() { log "${C_YELLOW}  !${C_RESET} $1"; }
err()  { log "${C_RED}  ✗${C_RESET} $1"; }
# Clear the ERR trap first so a deliberate fatal does not also print the
# generic "failed near line N" message.
fatal() { trap - ERR; err "$1"; exit "${2:-1}"; }

# ---------- Defaults ----------
INDUSTRY="property"
STACK="microsoft"
DRY_RUN=0
DEBUG=0
BUNDLE_VERSION="latest"

# ---------- Flag parsing ----------
show_help() {
  cat <<EOF
Engine AI Claude Installer (macOS) v${INSTALLER_VERSION}

Usage: install.sh [options]

Options:
  --industry <name>      Industry bundle: property (default) | finance |
                         investment | property-development | small-business
  --stack <name>         Productivity stack: microsoft (default) | google
  --bundle-version <tag> Templates release tag to install (default: latest)
  --dry-run              Print what would happen, do nothing
  --debug                Extra logging
  --help, -h             Show this help

Typical run:
  ./install.sh --industry property --stack microsoft
EOF
}

# $1 = flag name, $2 = number of args still on the command line.
# Without this a bare `--industry` hits "$2" under set -u and dies with
# "unbound variable" instead of telling the user what is wrong.
need_value() {
  if [[ "$2" -lt 2 ]]; then
    echo "Flag $1 needs a value."
    show_help
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --industry) need_value "$1" $#; INDUSTRY="$2"; shift 2 ;;
    --stack) need_value "$1" $#; STACK="$2"; shift 2 ;;
    --bundle-version) need_value "$1" $#; BUNDLE_VERSION="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --debug) DEBUG=1; shift ;;
    --help|-h) show_help; exit 0 ;;
    *) echo "Unknown flag: $1"; show_help; exit 2 ;;
  esac
done

# Keep this list in step with the [ValidateSet] on install.ps1 as bundles land.
case "$INDUSTRY" in
  property|finance|investment|property-development|small-business) ;;
  *) echo "Invalid --industry '$INDUSTRY'. Choose: property | finance | investment | property-development | small-business"; exit 2 ;;
esac

case "$STACK" in
  google|microsoft) ;;
  *) echo "Invalid --stack '$STACK'. Choose: google | microsoft"; exit 2 ;;
esac

# ---------- Setup log directory before first log() call ----------
mkdir -p "$LOG_DIR" "$BACKUP_ROOT" "$BUNDLE_DIR"
TS=$(date +%Y-%m-%d-%H%M%S)
LOG_FILE="${LOG_DIR}/${TS}.log"
: > "$LOG_FILE"

# ---------- Error trap ----------
# errexit on its own returns the user to a bare prompt part-way through the
# output with no indication anything failed. Mirror the try/catch in install.ps1.
on_error() {
  local exit_code=$?
  local line="${BASH_LINENO[0]:-?}"
  trap - ERR
  err "Install failed (exit ${exit_code}) near line ${line}."
  err "Log: ${LOG_FILE}"
  err "Restore your previous config: ${BACKUP_ROOT}/${TS}/restore.sh"
  exit "$exit_code"
}
trap on_error ERR

if [[ $DEBUG -eq 1 ]]; then
  set -x
fi

# ---------- Banner ----------
banner() {
  log ""
  log "${C_GOLD}${C_BOLD}Engine AI Claude Installer${C_RESET} ${C_DIM}v${INSTALLER_VERSION}${C_RESET}"
  log "${C_DIM}Industry: ${INDUSTRY}   Stack: ${STACK}   Bundle: ${BUNDLE_VERSION}${C_RESET}"
  log "${C_DIM}Log: ${LOG_FILE}${C_RESET}"
  log ""
}

# Every child runs with stdin closed off. When this script itself came from
# `curl | bash`, fd 0 holds the rest of our own source, and any child that reads
# a line from it (brew prompts, sudo, installer) eats the remainder of this
# installer and we resume parsing mid-token.
run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    log "${C_DIM}[dry-run] $*${C_RESET}"
  else
    "$@" </dev/null
  fi
}

# ---------- Helper: locate Claude Desktop ----------
# /Applications is the normal home, but a non-admin drag-install from the DMG
# lands in ~/Applications. Spotlight is the last resort for anything unusual.
CLAUDE_APP=""
find_claude_app() {
  local p
  for p in "/Applications/Claude.app" "${HOME}/Applications/Claude.app"; do
    if [[ -d "$p" ]]; then printf '%s' "$p"; return 0; fi
  done
  p=$(mdfind "kMDItemCFBundleIdentifier == 'com.anthropic.claudefordesktop'" 2>/dev/null | head -n 1 || true)
  if [[ -n "$p" && -d "$p" ]]; then printf '%s' "$p"; return 0; fi
  return 1
}
resolve_claude_app() { CLAUDE_APP=$(find_claude_app || true); }

# ---------- Helper: fully stop Claude Desktop ----------
# Claude Desktop is Electron. The main process and its helpers (Renderer, GPU,
# Utility) all flush claude_desktop_config.json on shutdown. If any of them is
# alive when we write, our mcpServers block is replaced by a defaults-only file
# and Claude shows "Could not load app settings". Same failure mode as the
# Windows fix in tasks/lessons.md (2026-04-18), so quit politely, then poll
# until every process is gone before writing anything.
claude_desktop_running() {
  pgrep -f "Claude.app/Contents/MacOS/Claude" >/dev/null 2>&1
}

wait_for_claude_exit() {
  local timeout="$1" deadline
  deadline=$(( $(date +%s) + timeout ))
  while claude_desktop_running && [[ $(date +%s) -lt $deadline ]]; do
    sleep 0.3
  done
}

stop_claude_desktop() {
  claude_desktop_running || return 0

  info "Claude Desktop is running - asking it to quit"
  osascript -e 'quit app "Claude"' </dev/null >/dev/null 2>&1 || true
  wait_for_claude_exit 10

  if claude_desktop_running; then
    warn "Claude Desktop did not quit cleanly - terminating"
    pkill -f "Claude.app/Contents/MacOS/Claude" >/dev/null 2>&1 || true
    wait_for_claude_exit 5
  fi

  if claude_desktop_running; then
    pkill -9 -f "Claude.app/Contents/MacOS/Claude" >/dev/null 2>&1 || true
    wait_for_claude_exit 3
  fi

  if claude_desktop_running; then
    warn "Some Claude processes did not exit - config may be overwritten"
    return 1
  fi
  ok "Claude Desktop stopped"
}

# ---------- Phase 1: Preflight ----------
phase_preflight() {
  step "Phase 1/8 - Preflight checks"

  # macOS version
  local os_version
  os_version=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
  info "macOS ${os_version}"
  local major="${os_version%%.*}"
  if [[ "$major" != "unknown" ]] && (( major < 12 )); then
    fatal "macOS ${os_version} is older than 12 (Monterey). Claude Desktop requires 12 or later."
  fi

  # Architecture
  local arch
  arch=$(uname -m)
  info "Architecture: ${arch}"

  # Connectivity
  if ! curl -fsSL --max-time 5 -o /dev/null https://raw.githubusercontent.com 2>/dev/null; then
    fatal "No connectivity to raw.githubusercontent.com - aborting."
  fi
  ok "Connectivity OK"

  # Existing installs
  resolve_claude_app
  if [[ -n "$CLAUDE_APP" ]]; then
    info "Claude Desktop is already installed at ${CLAUDE_APP} - will reconfigure"
  fi
  if command -v claude >/dev/null 2>&1; then
    info "Claude Code CLI is already installed - will reconfigure"
  fi

  # Disk space - need at least 1GB free in home.
  # -P forces POSIX single-line-per-filesystem output. Without it df wraps long
  # device names onto a second line and NR==2 reads the wrong row, which yields
  # an empty value and a false "less than 1GB free" abort.
  local free_mb
  # `|| true` inside the substitution: pipefail would otherwise promote a df
  # failure (stale network share, unmounted volume) to a fatal errexit abort
  # and the warn-and-continue branch below would never run.
  free_mb=$(df -Pm "$HOME" 2>/dev/null | awk 'NR==2 {print $4}' || true)
  if [[ -z "$free_mb" || ! "$free_mb" =~ ^[0-9]+$ ]]; then
    warn "Could not determine free disk space - continuing"
  elif (( free_mb < 1024 )); then
    fatal "Less than 1GB free in ${HOME}. Free up space before continuing."
  fi
  ok "Preflight clean"
}

# ---------- Phase 2: Backup ----------
phase_backup() {
  step "Phase 2/8 - Backup existing configuration"
  local backup_dir="${BACKUP_ROOT}/${TS}"
  run mkdir -p "$backup_dir"

  local backed_up=0
  if [[ -f "${CLAUDE_CONFIG_DIR}/claude_desktop_config.json" ]]; then
    run cp "${CLAUDE_CONFIG_DIR}/claude_desktop_config.json" "${backup_dir}/claude_desktop_config.json"
    backed_up=1
  fi
  if [[ -f "${CLAUDE_CONFIG_DIR}/developer_settings.json" ]]; then
    run cp "${CLAUDE_CONFIG_DIR}/developer_settings.json" "${backup_dir}/developer_settings.json"
    backed_up=1
  fi
  # permissions.json is overwritten in phase 7, so it has to be backed up here.
  local cc_file
  for cc_file in settings.json permissions.json; do
    if [[ -f "${CLAUDE_CODE_DIR}/${cc_file}" ]]; then
      run cp "${CLAUDE_CODE_DIR}/${cc_file}" "${backup_dir}/claude_code_${cc_file}"
      backed_up=1
    fi
  done
  if [[ -d "${CLAUDE_CODE_DIR}/skills" ]]; then
    run cp -R "${CLAUDE_CODE_DIR}/skills" "${backup_dir}/claude_code_skills"
    backed_up=1
  fi

  # Write a restore script
  if [[ $DRY_RUN -eq 0 ]]; then
    cat > "${backup_dir}/restore.sh" <<EOF
#!/usr/bin/env bash
# Restore script generated by Engine AI Claude Installer on ${TS}
set -euo pipefail
BACKUP_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
[[ -f "\$BACKUP_DIR/claude_desktop_config.json" ]] && cp "\$BACKUP_DIR/claude_desktop_config.json" "${CLAUDE_CONFIG_DIR}/claude_desktop_config.json"
[[ -f "\$BACKUP_DIR/developer_settings.json" ]] && cp "\$BACKUP_DIR/developer_settings.json" "${CLAUDE_CONFIG_DIR}/developer_settings.json"
[[ -f "\$BACKUP_DIR/claude_code_settings.json" ]] && cp "\$BACKUP_DIR/claude_code_settings.json" "${CLAUDE_CODE_DIR}/settings.json"
[[ -f "\$BACKUP_DIR/claude_code_permissions.json" ]] && cp "\$BACKUP_DIR/claude_code_permissions.json" "${CLAUDE_CODE_DIR}/permissions.json"
# Copy first, swap second. Deleting the live skills dir before the copy means a
# failed copy leaves you with nothing at all.
if [[ -d "\$BACKUP_DIR/claude_code_skills" ]]; then
  rm -rf "${CLAUDE_CODE_DIR}/skills.restore-tmp"
  cp -R "\$BACKUP_DIR/claude_code_skills" "${CLAUDE_CODE_DIR}/skills.restore-tmp"
  rm -rf "${CLAUDE_CODE_DIR}/skills"
  mv "${CLAUDE_CODE_DIR}/skills.restore-tmp" "${CLAUDE_CODE_DIR}/skills"
fi
echo "Restored from \$BACKUP_DIR"
EOF
    chmod +x "${backup_dir}/restore.sh"
  fi

  if (( backed_up )); then
    ok "Backed up to ${backup_dir}"
  else
    info "Nothing to back up (fresh install)"
  fi
}

# ---------- Phase 3: Download bundle ----------
phase_download_bundle() {
  step "Phase 3/8 - Download templates bundle"
  local tarball="${INDUSTRY}-${STACK}.tar.gz"
  local download_url

  if [[ "$BUNDLE_VERSION" == "latest" ]]; then
    download_url="https://github.com/${TEMPLATES_REPO}/releases/latest/download/${tarball}"
  else
    download_url="https://github.com/${TEMPLATES_REPO}/releases/download/${BUNDLE_VERSION}/${tarball}"
  fi

  local bundle_work="${BUNDLE_DIR}/${TS}"
  run mkdir -p "$bundle_work"

  info "Fetching ${tarball}"
  if [[ $DRY_RUN -eq 0 ]]; then
    if ! curl -fsSL --max-time 60 -o "${bundle_work}/${tarball}" "$download_url"; then
      fatal "Failed to download ${download_url}. Is there a release tagged for ${INDUSTRY}-${STACK}?"
    fi
    if ! tar -xzf "${bundle_work}/${tarball}" -C "$bundle_work"; then
      fatal "Downloaded ${tarball} but could not extract it (corrupt archive?)"
    fi
    [[ -f "${bundle_work}/claude_desktop_config.json" ]] \
      || fatal "Bundle ${tarball} is missing claude_desktop_config.json - wrong or truncated release artefact"
  fi

  BUNDLE_PATH="$bundle_work"
  ok "Unpacked to ${BUNDLE_PATH}"
}

# ---------- Phase 4: Install Node.js (runtime for npx MCPs) ----------
phase_install_node() {
  step "Phase 4/8 - Install Node.js runtime"
  if command -v node >/dev/null 2>&1; then
    info "Node.js already present: $(node --version </dev/null)"
    ok "Node ready"
    return 0
  fi

  info "Node.js not found - installing via Homebrew or the official pkg"
  if command -v brew >/dev/null 2>&1; then
    # A brew failure must not kill the whole install. install.ps1 degrades the
    # same way when winget fails.
    run brew install node || warn "Homebrew could not install Node. Install Node LTS manually from https://nodejs.org"
  else
    # sudo cannot prompt for a password when there is no terminal attached,
    # which is exactly the case under the documented `curl | bash` one-liner.
    if ! sudo -n true 2>/dev/null && [[ ! -t 0 ]]; then
      warn "Installing Node needs sudo but no terminal is attached (curl | bash). Install Node LTS manually from https://nodejs.org"
      return 0
    fi

    local node_pkg="${BUNDLE_DIR}/${TS}/node.pkg"

    # There is no node-latest-lts-*.pkg artefact on nodejs.org, so the real
    # version has to come from the release index. Records are newest-first and
    # LTS releases carry a codename string in "lts"; non-LTS carry false.
    info "Resolving current Node.js LTS"
    local node_ver
    node_ver=$(curl -fsSL --max-time 30 "https://nodejs.org/dist/index.json" 2>/dev/null \
      | tr '{' '\n' \
      | grep -m1 '"lts":"' \
      | sed -n 's/.*"version":"v\([0-9][0-9.]*\)".*/\1/p' || true)
    if [[ -z "$node_ver" ]]; then
      warn "Could not resolve a Node.js download. Install Node LTS manually from https://nodejs.org"
      return 0
    fi

    # nodejs.org ships one universal macOS pkg per release (x64 + arm64 in the
    # same file). There is no per-architecture .pkg, so do not build one.
    info "Downloading Node.js v${node_ver}"
    if ! run curl -fsSL --max-time 300 -o "$node_pkg" \
        "https://nodejs.org/dist/v${node_ver}/node-v${node_ver}.pkg"; then
      warn "Node.js download failed. MCP servers will not start until Node is installed from https://nodejs.org"
      return 0
    fi
    run sudo installer -pkg "$node_pkg" -target / \
      || warn "Node.js pkg install failed. Install Node LTS manually from https://nodejs.org"
  fi

  if command -v node >/dev/null 2>&1; then
    ok "Node.js installed: $(node --version </dev/null)"
  else
    warn "Node.js not on PATH after install. MCP servers may fail to start."
  fi
}

# ---------- Phase 5: Install Claude Desktop ----------
phase_install_claude_desktop() {
  step "Phase 5/8 - Install Claude Desktop"
  resolve_claude_app
  if [[ -n "$CLAUDE_APP" ]]; then
    ok "Claude Desktop already installed: ${CLAUDE_APP}"
    return 0
  fi

  # Prefer brew cask if available
  if command -v brew >/dev/null 2>&1; then
    info "Installing via Homebrew cask"
    run brew install --cask claude || warn "Homebrew could not install Claude Desktop. Install manually from https://claude.ai/download"
  else
    # The unattended download flow needs a confirmed macOS artefact URL and
    # admin rights on /Applications. Neither is safe to guess, so hand off
    # rather than leave a half-installed app behind.
    warn "Homebrew not found. Install Claude Desktop manually from https://claude.ai/download"
    info "Download the .dmg, drag Claude to your Applications folder, then re-run this installer to finish configuration."
    return 0
  fi

  resolve_claude_app
  if [[ -n "$CLAUDE_APP" ]]; then
    run xattr -dr com.apple.quarantine "$CLAUDE_APP" >/dev/null 2>&1 || true
    ok "Claude Desktop installed: ${CLAUDE_APP}"
  else
    warn "Claude Desktop not found in /Applications or ~/Applications after install"
  fi
}

# ---------- Phase 6: Install Claude Code CLI ----------
phase_install_claude_code() {
  step "Phase 6/8 - Install Claude Code CLI"
  if command -v claude >/dev/null 2>&1; then
    ok "Claude Code already installed: $(claude --version </dev/null 2>/dev/null || echo 'unknown')"
    return 0
  fi

  info "Running official installer"
  if [[ $DRY_RUN -eq 0 ]]; then
    local cc_installer="${BUNDLE_DIR}/${TS}/claude-code-install.sh"
    if ! curl -fsSL --max-time 120 -o "$cc_installer" "https://claude.ai/install.sh"; then
      warn "Could not download the Claude Code installer. Run manually: curl -fsSL https://claude.ai/install.sh | bash"
      return 0
    fi
    # Run it detached from our stdin. When this script itself came from
    # `curl | bash`, stdin holds the rest of our own source, and a child that
    # reads a line from it eats the remainder of this installer.
    if ! bash "$cc_installer" </dev/null; then
      warn "Claude Code install failed. Run manually: curl -fsSL https://claude.ai/install.sh | bash"
      return 0
    fi
  fi

  # PATH may not be live in this shell; check common install locations
  if command -v claude >/dev/null 2>&1; then
    ok "Claude Code installed"
  elif [[ -x "${HOME}/.local/bin/claude" ]]; then
    ok "Claude Code installed at ~/.local/bin/claude"
    info "Open a new terminal after this script finishes to use 'claude' on PATH"
  else
    warn "Claude Code binary not found on PATH. You may need a fresh shell."
  fi
}

# ---------- Phase 7: Write configs + skills ----------
phase_write_configs() {
  step "Phase 7/8 - Write configs and skills"
  [[ -z "${BUNDLE_PATH:-}" ]] && fatal "Bundle not downloaded - aborting"

  # Must happen before the first write, never after. A Claude process that is
  # still alive will flush a defaults-only config over the top of ours.
  if [[ $DRY_RUN -eq 0 ]]; then
    stop_claude_desktop || true
  fi

  run mkdir -p "$CLAUDE_CONFIG_DIR" "${CLAUDE_CODE_DIR}/skills"

  # Substitute placeholders in claude_desktop_config.json
  local src="${BUNDLE_PATH}/claude_desktop_config.json"
  local dst="${CLAUDE_CONFIG_DIR}/claude_desktop_config.json"
  if [[ $DRY_RUN -eq 0 ]]; then
    # Nothing was actually extracted under --dry-run, so only insist on the
    # source file when we are about to read it for real.
    [[ -f "$src" ]] || fatal "Bundle is missing claude_desktop_config.json (${src})"

    # Two escaping passes. First for JSON, so a backslash or quote in $HOME
    # cannot break the string. Then for sed's replacement metacharacters, where
    # & means "the whole match", \ escapes, and | is our delimiter.
    local home_json home_sed
    home_json=$(printf '%s' "$HOME" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
    home_sed=$(printf '%s' "$home_json" | sed -e 's/[\\&|]/\\&/g')
    # Render to a temp file and move it into place, so a failed substitution
    # never leaves a truncated config behind.
    if ! sed "s|{{HOME}}|${home_sed}|g" "$src" > "${dst}.tmp"; then
      rm -f "${dst}.tmp"
      fatal "Failed to render ${dst}"
    fi
    mv -f "${dst}.tmp" "$dst"
  fi
  ok "Wrote ${dst}"

  # developer_settings.json
  if [[ -f "${BUNDLE_PATH}/developer_settings.json" ]]; then
    run cp "${BUNDLE_PATH}/developer_settings.json" "${CLAUDE_CONFIG_DIR}/developer_settings.json"
    ok "Wrote developer_settings.json"
  fi

  # Skills
  if [[ -d "${BUNDLE_PATH}/skills" ]]; then
    # Copy each skill dir, replacing existing ones of the same name
    for skill_dir in "${BUNDLE_PATH}/skills"/*/; do
      [[ -d "$skill_dir" ]] || continue
      local name
      name=$(basename "$skill_dir")
      run rm -rf "${CLAUDE_CODE_DIR}/skills/${name}"
      # Strip the trailing slash the */ glob leaves on. BSD cp copies the
      # contents rather than the directory when the source ends in one.
      run cp -R "${skill_dir%/}" "${CLAUDE_CODE_DIR}/skills/${name}"
    done
    ok "Installed skills to ~/.claude/skills/"
  fi

  # Claude Code settings
  if [[ -f "${BUNDLE_PATH}/claude-code/settings.json" ]]; then
    run cp "${BUNDLE_PATH}/claude-code/settings.json" "${CLAUDE_CODE_DIR}/settings.json"
    ok "Wrote ~/.claude/settings.json"
  fi
  if [[ -f "${BUNDLE_PATH}/claude-code/permissions.json" ]]; then
    run cp "${BUNDLE_PATH}/claude-code/permissions.json" "${CLAUDE_CODE_DIR}/permissions.json"
    ok "Wrote ~/.claude/permissions.json"
  fi
}

# ---------- Phase 8: Finish ----------
phase_finish() {
  step "Phase 8/8 - Launch and next steps"

  resolve_claude_app

  if [[ $DRY_RUN -eq 0 ]]; then
    # Claude was fully stopped in phase 7, so this is a cold start that reads the
    # config we just wrote. Do not kill anything here - a kill at this point is
    # what triggers the shutdown flush that clobbers the config.
    if claude_desktop_running; then
      warn "Claude Desktop is running again already - quit and reopen it to pick up the new config"
    elif [[ -n "$CLAUDE_APP" ]]; then
      # Launching is cosmetic. Every config is already written, so a failed
      # launch must not abort the install and send the client to restore.sh.
      if open -a "$CLAUDE_APP"; then
        ok "Launched Claude Desktop"
      else
        warn "Could not launch Claude Desktop - open it from your Applications folder"
      fi
    else
      warn "Claude Desktop not found - launch it from your Applications folder"
    fi
  fi

  log ""
  log "${C_GOLD}${C_BOLD}Install complete.${C_RESET}"
  log ""
  log "${C_BOLD}Next steps:${C_RESET}"
  log "  1. Sign in to Claude Desktop with your Anthropic account"
  log "  2. Click the Cowork tab (top of the sidebar) to activate the agent"
  log "  3. In a new terminal, run ${C_BOLD}claude${C_RESET} to try Claude Code"
  log ""
  log "${C_DIM}Bundle manifest:  ${BUNDLE_PATH}/manifest.json${C_RESET}"
  log "${C_DIM}Install log:      ${LOG_FILE}${C_RESET}"
  log "${C_DIM}Restore earlier config: ${BACKUP_ROOT}/${TS}/restore.sh${C_RESET}"
  log ""
}

# ---------- Main ----------
main() {
  banner
  phase_preflight
  phase_backup
  phase_download_bundle
  phase_install_node
  phase_install_claude_desktop
  phase_install_claude_code
  phase_write_configs
  phase_finish
}

main "$@"
