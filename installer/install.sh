#!/usr/bin/env bash
#
# Engine AI Claude Installer — macOS
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

set -euo pipefail

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

log()  { printf "%s\n" "$*" | tee -a "${LOG_FILE:-/dev/null}" >&2; }
info() { log "${C_DIM}  ${1}${C_RESET}"; }
step() { log ""; log "${C_GOLD}${C_BOLD}==>${C_RESET} ${C_BOLD}$1${C_RESET}"; }
ok()   { log "${C_GREEN}  ✓${C_RESET} $1"; }
warn() { log "${C_YELLOW}  !${C_RESET} $1"; }
err()  { log "${C_RED}  ✗${C_RESET} $1"; }
fatal() { err "$1"; exit "${2:-1}"; }

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
  --industry <name>      Industry bundle: property (default)
  --stack <name>         Productivity stack: microsoft (default) | google
  --bundle-version <tag> Templates release tag to install (default: latest)
  --dry-run              Print what would happen, do nothing
  --debug                Extra logging
  --help, -h             Show this help

Typical run:
  ./install.sh --industry property --stack microsoft
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --industry) INDUSTRY="$2"; shift 2 ;;
    --stack) STACK="$2"; shift 2 ;;
    --bundle-version) BUNDLE_VERSION="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --debug) DEBUG=1; shift ;;
    --help|-h) show_help; exit 0 ;;
    *) echo "Unknown flag: $1"; show_help; exit 2 ;;
  esac
done

case "$STACK" in
  google|microsoft) ;;
  *) echo "Invalid --stack '$STACK'. Choose: google | microsoft"; exit 2 ;;
esac

# ---------- Setup log directory before first log() call ----------
mkdir -p "$LOG_DIR" "$BACKUP_ROOT" "$BUNDLE_DIR"
TS=$(date +%Y-%m-%d-%H%M%S)
LOG_FILE="${LOG_DIR}/${TS}.log"
: > "$LOG_FILE"

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

run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    log "${C_DIM}[dry-run] $*${C_RESET}"
  else
    "$@"
  fi
}

# ---------- Phase 1: Preflight ----------
phase_preflight() {
  step "Phase 1/8 — Preflight checks"

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
    fatal "No connectivity to raw.githubusercontent.com — aborting."
  fi
  ok "Connectivity OK"

  # Existing installs
  if [[ -d "/Applications/Claude.app" ]]; then
    info "Claude Desktop is already installed — will reconfigure"
  fi
  if command -v claude >/dev/null 2>&1; then
    info "Claude Code CLI is already installed — will reconfigure"
  fi

  # Disk space — need at least 1GB free in home
  local free_mb
  free_mb=$(df -m "$HOME" | awk 'NR==2 {print $4}')
  if (( free_mb < 1024 )); then
    fatal "Less than 1GB free in ${HOME}. Free up space before continuing."
  fi
  ok "Preflight clean"
}

# ---------- Phase 2: Backup ----------
phase_backup() {
  step "Phase 2/8 — Backup existing configuration"
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
  if [[ -f "${CLAUDE_CODE_DIR}/settings.json" ]]; then
    run cp "${CLAUDE_CODE_DIR}/settings.json" "${backup_dir}/claude_code_settings.json"
    backed_up=1
  fi
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
[[ -d "\$BACKUP_DIR/claude_code_skills" ]] && rm -rf "${CLAUDE_CODE_DIR}/skills" && cp -R "\$BACKUP_DIR/claude_code_skills" "${CLAUDE_CODE_DIR}/skills"
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
  step "Phase 3/8 — Download templates bundle"
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
    tar -xzf "${bundle_work}/${tarball}" -C "$bundle_work"
  fi

  BUNDLE_PATH="$bundle_work"
  ok "Unpacked to ${BUNDLE_PATH}"
}

# ---------- Phase 4: Install Node.js (runtime for npx MCPs) ----------
phase_install_node() {
  step "Phase 4/8 — Install Node.js runtime"
  if command -v node >/dev/null 2>&1; then
    info "Node.js already present: $(node --version)"
    ok "Node ready"
    return 0
  fi

  info "Node.js not found — installing via Homebrew or the official pkg"
  if command -v brew >/dev/null 2>&1; then
    run brew install node
  else
    local arch
    arch=$(uname -m)
    local pkg_arch="x64"
    [[ "$arch" == "arm64" ]] && pkg_arch="arm64"
    local node_pkg="${BUNDLE_DIR}/${TS}/node.pkg"
    info "Downloading Node.js LTS pkg"
    run curl -fsSL --max-time 120 -o "$node_pkg" "https://nodejs.org/dist/latest-lts/node-latest-lts-darwin-${pkg_arch}.pkg" || {
      warn "Node.js install skipped — download failed. MCP servers may not start until Node is installed manually."
      return 0
    }
    run sudo installer -pkg "$node_pkg" -target /
  fi

  if command -v node >/dev/null 2>&1; then
    ok "Node.js installed: $(node --version)"
  else
    warn "Node.js not on PATH after install. MCP servers may fail to start."
  fi
}

# ---------- Phase 5: Install Claude Desktop ----------
phase_install_claude_desktop() {
  step "Phase 5/8 — Install Claude Desktop"
  if [[ -d "/Applications/Claude.app" ]]; then
    ok "Claude Desktop already installed"
    return 0
  fi

  # Prefer brew cask if available
  if command -v brew >/dev/null 2>&1; then
    info "Installing via Homebrew cask"
    run brew install --cask claude
  else
    info "Installing via direct .zip download"
    local zip_url="https://storage.googleapis.com/osprey-downloads-c02f6a0d-347c-492b-a752-3e0651722e97/nest-win-x64/Claude-latest.zip"
    # Claude Desktop macOS download URL format:
    local dmg_or_zip="${BUNDLE_DIR}/${TS}/Claude.zip"
    run curl -fsSL --max-time 180 -o "$dmg_or_zip" "https://claude.ai/download/mac" || {
      warn "Direct download failed. Install Claude Desktop manually from https://claude.ai/download"
      return 0
    }
    run ditto -xk "$dmg_or_zip" "/Applications/"
    run xattr -dr com.apple.quarantine "/Applications/Claude.app" 2>/dev/null || true
  fi

  if [[ -d "/Applications/Claude.app" ]]; then
    ok "Claude Desktop installed"
  else
    warn "Claude Desktop not found at /Applications/Claude.app after install"
  fi
}

# ---------- Phase 6: Install Claude Code CLI ----------
phase_install_claude_code() {
  step "Phase 6/8 — Install Claude Code CLI"
  if command -v claude >/dev/null 2>&1; then
    ok "Claude Code already installed: $(claude --version 2>/dev/null || echo 'unknown')"
    return 0
  fi

  info "Running official installer"
  if [[ $DRY_RUN -eq 0 ]]; then
    curl -fsSL https://claude.ai/install.sh | bash || {
      warn "Claude Code install failed. Run manually: curl -fsSL https://claude.ai/install.sh | bash"
      return 0
    }
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
  step "Phase 7/8 — Write configs and skills"
  [[ -z "${BUNDLE_PATH:-}" ]] && fatal "Bundle not downloaded — aborting"

  run mkdir -p "$CLAUDE_CONFIG_DIR" "${CLAUDE_CODE_DIR}/skills"

  # Substitute placeholders in claude_desktop_config.json
  local src="${BUNDLE_PATH}/claude_desktop_config.json"
  local dst="${CLAUDE_CONFIG_DIR}/claude_desktop_config.json"
  if [[ $DRY_RUN -eq 0 ]]; then
    sed "s|{{HOME}}|${HOME}|g" "$src" > "$dst"
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
      run cp -R "$skill_dir" "${CLAUDE_CODE_DIR}/skills/${name}"
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
  step "Phase 8/8 — Launch and next steps"

  if [[ $DRY_RUN -eq 0 ]]; then
    # Kill any running Claude Desktop so the new config is read
    pkill -x Claude 2>/dev/null || true
    sleep 1
    if [[ -d "/Applications/Claude.app" ]]; then
      open -a Claude
      ok "Launched Claude Desktop"
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
