#!/usr/bin/env bash
#
# Engine AI Claude Health Check - macOS (read-only)
#
# Assesses a machine's Claude setup, machine health, data landscape, and
# installed business apps. Prints a scored summary and writes a JSON report.
# Port of installer/assess.ps1. Same finding ids, same categories, same
# statuses, same maturity cascade, same readiness verdict logic, same JSON
# schema, so a macOS report and a Windows report compare directly.
#
# READ-ONLY CONTRACT
# - Writes nothing outside ~/.engineai-installer/assess/
# - No process kills, no app launches, no installs, no defaults writes
# - Filenames, directory listings, environment, and system metadata only
# - The only file contents read are Claude's own config files
#
# PROBE CONTRACT (this is what makes the script testable)
# - Every interrogation of the machine lives in its own small function whose
#   name starts with probe_. Those functions are the ONLY place an external
#   command is run against machine state.
# - Every probe prints its answer on stdout and always returns 0. A missing
#   binary, a permission denial, or a timeout produces empty output, never a
#   failure that can abort the scan.
# - All scoring, rollup, JSON, and console code calls probe_ functions and
#   nothing else, so a test harness can redefine any probe_ function with a
#   stub and drive the whole script deterministically off a fake machine.
# - The scoring code does run awk and sed over strings a probe already
#   returned (json_escape, json_scan_block, and a handful of field pulls).
#   Those are pure text transforms with no machine state behind them, so a
#   stubbed probe drives them exactly the same way a real one does.
#
# Deliberately NOT using 'set -e'. A health check must degrade to a finding,
# never abort. 'set -u' and 'pipefail' stay on to catch real coding mistakes.
#
# Bash 3.2 compatible (the /bin/bash that ships on every Mac): no associative
# arrays, no mapfile, no ${var,,}, no namerefs.
#
# Usage (one-liner):
#   curl -fsSL https://raw.githubusercontent.com/engineai-nz/claude-installer/main/installer/assess.sh | bash
#
# Usage (local):
#   ./installer/assess.sh [--json-only] [--out <dir>] [--help]

set -u
set -o pipefail

# ---------- Constants ----------
ASSESS_VERSION="0.1.0"
SCHEMA_VERSION="1"
OUT_DIR="${HOME}/.engineai-installer/assess"
ASSESS_TMP_DIR=""
JSON_ONLY=0

# Check registry. Display names match assess.ps1 so the internal error finding
# ids ("Test-MachineHealth.error") are identical across platforms.
CHECKS="Test-MachineHealth:check_machine_health
Test-ClaudeDesktop:check_claude_desktop
Test-ClaudeCode:check_claude_code
Test-McpRuntime:check_mcp_runtime
Test-DataLandscape:check_data_landscape
Test-WorkStack:check_work_stack
Test-OpportunityScan:check_opportunity_scan"

CATEGORY_ORDER="machine-health claude-desktop claude-code mcp-runtime data-landscape work-stack opportunity-scan internal"

# ---------- Flag parsing ----------
# Parsed defensively: 'curl | bash' passes no arguments at all, so every flag
# is optional and the script must run clean with $# = 0.
show_help() {
  cat <<EOF
Engine AI Claude Health Check (macOS) v${ASSESS_VERSION}

Read-only. Looks at this Mac, scores how ready it is for Claude, and writes a
JSON report. Nothing is installed, changed, launched, or closed.

Usage: assess.sh [options]

Options:
  --json-only        Print the JSON report to stdout and nothing else
  --out <dir>        Write the report to <dir> (default: ~/.engineai-installer/assess)
  --help, -h         Show this help

Typical run:
  curl -fsSL https://raw.githubusercontent.com/engineai-nz/claude-installer/main/installer/assess.sh | bash
EOF
}

while [ $# -gt 0 ]; do
  case "${1:-}" in
    --json-only) JSON_ONLY=1; shift ;;
    --out)
      if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
        printf 'assess.sh: --out needs a directory\n' >&2
        exit 2
      fi
      OUT_DIR="$2"; shift 2 ;;
    --out=*) OUT_DIR="${1#--out=}"; shift ;;
    --help|-h) show_help; exit 0 ;;
    "") shift ;;
    *)
      printf 'assess.sh: unknown option %s\n\n' "$1" >&2
      show_help >&2
      exit 2 ;;
  esac
done

# The report path is quoted back to the operator and pasted into tickets, so
# it is always absolute.
while [ "${OUT_DIR#./}" != "$OUT_DIR" ]; do OUT_DIR="${OUT_DIR#./}"; done
case "$OUT_DIR" in
  /*) ;;
  *)  OUT_DIR="$(pwd)/${OUT_DIR}" ;;
esac
OUT_DIR="${OUT_DIR%/}"

# ---------- Colour ----------
# ANSI mapping of the PowerShell console colours, disabled when stdout is not
# a terminal or when NO_COLOR is set.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "$JSON_ONLY" -eq 0 ]; then
  C_RESET=$'\033[0m'
  C_YELLOW=$'\033[1;33m'
  C_DARKYELLOW=$'\033[0;33m'
  C_GREEN=$'\033[0;32m'
  C_RED=$'\033[0;31m'
  C_GRAY=$'\033[0;37m'
  C_DARKGRAY=$'\033[0;90m'
  C_CYAN=$'\033[0;36m'
else
  C_RESET=""; C_YELLOW=""; C_DARKYELLOW=""; C_GREEN=""
  C_RED=""; C_GRAY=""; C_DARKGRAY=""; C_CYAN=""
fi

# say <colour> <text>   - one console line, suppressed by --json-only
say() {
  [ "$JSON_ONLY" -eq 1 ] && return 0
  printf '%s%s%s\n' "$1" "$2" "$C_RESET"
}
# sayn <colour> <text>  - same, no trailing newline
sayn() {
  [ "$JSON_ONLY" -eq 1 ] && return 0
  printf '%s%s%s' "$1" "$2" "$C_RESET"
}
blank() {
  [ "$JSON_ONLY" -eq 1 ] && return 0
  printf '\n'
}

# =====================================================================
# PROBES - the only place external commands touch machine state.
# Each probe prints its answer and always returns 0.
# =====================================================================

# run_timed <seconds> <command> [args...]
# macOS has no timeout(1), so this is the hand-rolled watchdog. Used by every
# probe that can touch a network mount, a directory service, or a third-party
# binary. Returns 124 on timeout. A process wedged in an uninterruptible VFS
# wait cannot be killed, so this is the second line of defence; the first is
# simply never issuing a blocking call (no bare df, no ls -l /Volumes, no
# system_profiler, no softwareupdate -l).
run_timed() {
  local secs="$1"; shift
  # stdin is closed for the child: a probe must never swallow the caller's
  # loop input, and no probe is ever meant to read from the terminal.
  if [ -z "$ASSESS_TMP_DIR" ] || [ ! -d "$ASSESS_TMP_DIR" ]; then
    "$@" </dev/null 2>/dev/null
    return $?
  fi
  local out="${ASSESS_TMP_DIR}/.rt.$$"
  # The spool holds whatever the wrapped command printed, and one of those
  # commands is a plutil extract of mcpServers, i.e. live API keys. Create it
  # owner-only before anything is written to it.
  : >"$out" 2>/dev/null || { "$@" </dev/null 2>/dev/null; return $?; }
  /bin/chmod 600 "$out" 2>/dev/null
  "$@" </dev/null >"$out" 2>/dev/null &
  local pid=$!
  local n=0
  local limit=$(( secs * 10 ))
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$n" -ge "$limit" ]; then
      kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      rm -f "$out" 2>/dev/null
      return 124
    fi
    sleep 0.1 2>/dev/null || sleep 1
    n=$(( n + 1 ))
  done
  local rc
  wait "$pid" 2>/dev/null
  rc=$?
  cat "$out" 2>/dev/null
  rm -f "$out" 2>/dev/null
  return "$rc"
}

# --- generic filesystem probes ---
# A bare [ -d ] is a bash builtin and cannot be put under the watchdog, and on
# a File Provider sync root or a dead network mount the underlying stat blocks
# in an uninterruptible wait that Ctrl-C cannot break. Paths that can sit
# behind such a mount go through /bin/test under run_timed instead, so a wedged
# provider degrades to "not detected". Local paths keep the builtin: the
# watchdog costs a fork and a poll interval, and these probes are called
# several dozen times per scan.
path_is_risky() {
  case "$1" in
    /Volumes/*|/net/*|/Network/*) return 0 ;;
    "${HOME}/Library/CloudStorage"*) return 0 ;;
    "${HOME}/Library/Mobile Documents"*) return 0 ;;
    "${HOME}/OneDrive"*|"${HOME}/Dropbox"*|"${HOME}/Google Drive"*) return 0 ;;
  esac
  return 1
}

# timed_test <flag> <path> - guarded form of [ <flag> <path> ], printing 1 or 0.
# Not a probe_ function: it is part of the watchdog plumbing that probes call,
# the same way run_timed is.
timed_test() {
  if run_timed 3 /bin/test "$1" "$2" >/dev/null 2>&1; then printf '1'; else printf '0'; fi
  return 0
}

probe_path_exists() {
  if path_is_risky "$1"; then timed_test -e "$1"; return 0; fi
  if [ -e "$1" ]; then printf '1'; else printf '0'; fi; return 0
}
probe_file_exists() {
  if path_is_risky "$1"; then timed_test -f "$1"; return 0; fi
  if [ -f "$1" ]; then printf '1'; else printf '0'; fi; return 0
}
probe_dir_exists() {
  if path_is_risky "$1"; then timed_test -d "$1"; return 0; fi
  if [ -d "$1" ]; then printf '1'; else printf '0'; fi; return 0
}
probe_is_symlink() {
  if path_is_risky "$1"; then timed_test -L "$1"; return 0; fi
  if [ -L "$1" ]; then printf '1'; else printf '0'; fi; return 0
}
probe_is_exec() {
  if path_is_risky "$1"; then timed_test -x "$1"; return 0; fi
  if [ -x "$1" ]; then printf '1'; else printf '0'; fi; return 0
}

probe_readlink() { /usr/bin/readlink "$1" 2>/dev/null || true; return 0; }

# readdir only. Never ls -l: -l stats every entry, and one dead network volume
# then costs 30 seconds. Under the watchdog because the directory this is
# pointed at most often is ~/Library/CloudStorage, where the readdir is served
# by fileproviderd and a wedged OneDrive or iCloud provider never answers.
probe_list_names() { run_timed 3 /bin/ls -1 "$1" 2>/dev/null || true; return 0; }

probe_list_subdir_names() {
  local d="$1" e
  if [ -d "$d" ]; then
    for e in "$d"/*/; do
      [ -d "$e" ] || continue
      e="${e%/}"
      printf '%s\n' "${e##*/}"
    done
  fi
  return 0
}

probe_file_size() {
  local s
  s=$(/usr/bin/wc -c < "$1" 2>/dev/null | /usr/bin/tr -d ' ' || true)
  case "$s" in ''|*[!0-9]*) s=0 ;; esac
  printf '%s' "$s"
  return 0
}

# BSD stat first (that is what macOS ships). The GNU form is a fallback only so
# the script stays drivable on a Linux test box.
probe_file_mtime_epoch() {
  local s
  s=$(/usr/bin/stat -f '%m' "$1" 2>/dev/null || true)
  [ -n "$s" ] || s=$(/usr/bin/stat -c '%Y' "$1" 2>/dev/null || true)
  case "$s" in ''|*[!0-9]*) s="" ;; esac
  printf '%s' "$s"
  return 0
}

probe_file_head_hex3() {
  /usr/bin/head -c 3 "$1" 2>/dev/null | /usr/bin/od -An -tx1 2>/dev/null | /usr/bin/tr -d ' \n' || true
  return 0
}

probe_file_text() { /bin/cat "$1" 2>/dev/null || true; return 0; }

probe_command_path() { command -v "$1" 2>/dev/null || true; return 0; }

# First line of a command's output, under the watchdog. Used for version
# calls: 'claude --version' can stall behind an update check on a captive
# portal, which is the macOS analogue of the install.ps1 stdin hang.
probe_first_line_of() {
  local secs="$1"; shift
  run_timed "$secs" "$@" 2>/dev/null | /usr/bin/awk 'NR==1{print; exit}' || true
  return 0
}

# --- system metadata probes ---
probe_platform() { /usr/bin/uname -s 2>/dev/null || true; return 0; }
probe_arch()     { /usr/bin/uname -m 2>/dev/null || true; return 0; }

probe_sw_vers() {
  case "$1" in
    productName)    /usr/bin/sw_vers -productName 2>/dev/null || true ;;
    productVersion) /usr/bin/sw_vers -productVersion 2>/dev/null || true ;;
    buildVersion)   /usr/bin/sw_vers -buildVersion 2>/dev/null || true ;;
  esac
  return 0
}

probe_sysctl() { /usr/sbin/sysctl -n "$1" 2>/dev/null || true; return 0; }

# Free space on the writable boot volume. Single explicit path, never bare df.
# Note: df counts purgeable space (local snapshots, evicted iCloud files) as
# used, so it reads lower than Finder. Conservative, which is the right
# direction for a readiness check.
probe_df_free_kb() {
  local target="/System/Volumes/Data" out
  [ -d "$target" ] || target="/"
  out=$(run_timed 5 /bin/df -Pk "$target" 2>/dev/null || true)
  printf '%s\n' "$out" | /usr/bin/awk 'NR==2 {print $4; exit}' || true
  return 0
}

probe_hostname() {
  local h
  h=$(run_timed 3 /usr/sbin/scutil --get ComputerName 2>/dev/null || true)
  [ -n "$h" ] || h=$(/bin/hostname -s 2>/dev/null || true)
  printf '%s' "$h"
  return 0
}

probe_current_user() { /usr/bin/id -un 2>/dev/null || true; return 0; }
probe_uid()          { /usr/bin/id -u 2>/dev/null || true; return 0; }
probe_group_names()  { /usr/bin/id -Gn 2>/dev/null || true; return 0; }

# Local directory node only, so a bound-but-off-network Mac cannot hang here.
probe_dscl_admin_members() {
  run_timed 3 /usr/bin/dscl . -read /Groups/admin GroupMembership 2>/dev/null || true
  return 0
}

# Authoritative membership check, including nested groups. Parse the first
# word, never the exit code: dseditgroup returns 0 for both answers. This is
# the macOS analogue of the Windows deny-only-SID trap, where the naive check
# looked right and was wrong.
probe_dseditgroup_admin() {
  local user="$1" out
  out=$(run_timed 3 /usr/sbin/dseditgroup -o checkmember -m "$user" admin 2>/dev/null || true)
  printf '%s\n' "$out" | /usr/bin/awk 'NR==1{print $1; exit}' || true
  return 0
}

probe_ad_domains() {
  run_timed 3 /usr/bin/dscl localhost -list "/Active Directory" 2>/dev/null || true
  return 0
}

# 'profiles status' may or may not answer unprivileged. Never sudo: that would
# prompt for a password and break the non-interactive contract.
probe_mdm_enrollment() {
  run_timed 5 /usr/bin/profiles status -type enrollment 2>/dev/null || true
  return 0
}

probe_managed_prefs_names() { probe_list_names "/Library/Managed Preferences"; return 0; }

# Directory existence only, no exec. A named vendor agent is a strong signal;
# a bare configuration profile is not (see the false-positive note in
# check_machine_health).
probe_mdm_vendor_names() {
  local p
  for p in \
    "/usr/local/bin/jamf" \
    "/Library/Application Support/JAMF" \
    "/Library/Kandji" \
    "/Library/Addigy" \
    "/Library/Intune" \
    "/Library/Application Support/Microsoft/Intune" \
    "/Library/Application Support/AirWatch" \
    "/usr/local/mosyle" \
    "/Library/Application Support/Mosyle" \
    "/Library/SimpleMDM"
  do
    if [ -e "$p" ]; then
      p="${p%/}"
      printf '%s\n' "${p##*/}"
    fi
  done
  return 0
}

probe_gatekeeper() { run_timed 5 /usr/sbin/spctl --status 2>/dev/null || true; return 0; }

probe_security_product_names() {
  local p
  for p in \
    "/Applications/CrowdStrike Falcon.app" \
    "/Library/CS" \
    "/Applications/SentinelOne" \
    "/Applications/Sophos" \
    "/Library/Sophos Anti-Virus" \
    "/Applications/Microsoft Defender.app" \
    "/Library/Application Support/Malwarebytes" \
    "/Applications/ESET Endpoint Security.app" \
    "/Applications/Webroot SecureAnywhere.app" \
    "/Applications/Bitdefender" \
    "/Applications/Carbon Black"
  do
    if [ -e "$p" ]; then
      p="${p%/}"; p="${p##*/}"
      printf '%s\n' "${p%.app}"
    fi
  done
  return 0
}

probe_security_process_names() {
  local n
  for n in falconctl sentineld wdav CbOsxSensorService; do
    if run_timed 3 /usr/bin/pgrep -x "$n" >/dev/null 2>&1; then
      printf '%s\n' "$n"
    fi
  done
  return 0
}

probe_now_epoch() { /bin/date +%s 2>/dev/null || true; return 0; }
probe_now_stamp() { /bin/date +%Y-%m-%d-%H%M%S 2>/dev/null || true; return 0; }

# ISO 8601 local time with a colon in the offset, matching the PowerShell
# 'yyyy-MM-ddTHH:mm:sszzz' format.
probe_now_iso() {
  /bin/date "+%Y-%m-%dT%H:%M:%S%z" 2>/dev/null \
    | /usr/bin/sed -E 's/([+-][0-9][0-9])([0-9][0-9])$/\1:\2/' || true
  return 0
}

probe_epoch_to_date() {
  local e="$1" out
  [ -n "$e" ] || return 0
  out=$(/bin/date -r "$e" '+%Y-%m-%d' 2>/dev/null || true)
  [ -n "$out" ] || out=$(/bin/date -d "@${e}" '+%Y-%m-%d' 2>/dev/null || true)
  printf '%s' "$out"
  return 0
}

probe_boot_epoch() {
  local raw
  raw=$(probe_sysctl kern.boottime)
  printf '%s\n' "$raw" | /usr/bin/sed -n 's/.*sec = \([0-9][0-9]*\).*/\1/p' || true
  return 0
}

# One process name per line, no arguments. Cheap and stable.
probe_process_names() {
  run_timed 5 /bin/ps -axco comm 2>/dev/null | /usr/bin/grep -v '^COMMAND$' || true
  return 0
}

probe_claude_process_count() {
  local n
  n=$(run_timed 3 /usr/bin/pgrep -f "/Claude.app/" 2>/dev/null | /usr/bin/grep -c . || true)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
  return 0
}

# The kernel mount table, not df. df calls statfs per filesystem and blocks on
# a dead SMB or NFS mount; this is the macOS version of the 41s WMI lesson.
probe_mount_table() { run_timed 3 /sbin/mount 2>/dev/null || true; return 0; }

# Each readdir is watchdogged: an Applications folder can itself be redirected
# onto a network volume or a sync root.
probe_apps_names() {
  {
    run_timed 3 /bin/ls -1 /Applications
    run_timed 3 /bin/ls -1 "${HOME}/Applications"
    run_timed 3 /bin/ls -1 /System/Applications
  } 2>/dev/null | /usr/bin/sed 's/\.app$//' | /usr/bin/sort -u || true
  return 0
}

# Bundle id of the default https handler, e.g. com.google.chrome. The plist may
# be TCC-protected on recent macOS, so an empty answer means "unknown", never
# "no Google stack".
probe_default_browser() {
  local p="${HOME}/Library/Preferences/com.apple.LaunchServices/com.apple.launchservices.secure.plist"
  [ -f "$p" ] || return 0
  run_timed 3 /usr/bin/plutil -p "$p" 2>/dev/null | /usr/bin/awk '
    /\{/ { role = ""; scheme = "" }
    /"LSHandlerRoleAll"/  { if (match($0, /=> "[^"]*"/)) { s = substr($0, RSTART + 4, RLENGTH - 4); gsub(/"/, "", s); role = s } }
    /"LSHandlerURLScheme"/ { if (match($0, /=> "[^"]*"/)) { s = substr($0, RSTART + 4, RLENGTH - 4); gsub(/"/, "", s); scheme = s } }
    /\}/ { if (scheme == "https" && role != "") { print role; exit } }
  ' || true
  return 0
}

probe_plutil_available() {
  if [ -x /usr/bin/plutil ]; then printf '1'; else printf '0'; fi
  return 0
}

probe_plutil_lint() {
  if run_timed 5 /usr/bin/plutil -lint -s "$1" >/dev/null 2>&1; then printf '1'; else printf '0'; fi
  return 0
}

probe_plutil_lint_error() {
  local out
  out=$(run_timed 5 /usr/bin/plutil -lint "$1" 2>&1 || true)
  printf '%s\n' "$out" | /usr/bin/awk 'NR==1{sub(/^[^:]*: /, ""); print; exit}' || true
  return 0
}

probe_plutil_extract_raw()  { run_timed 5 /usr/bin/plutil -extract "$1" raw -o - "$2" 2>/dev/null || true; return 0; }
probe_plutil_extract_json() { run_timed 5 /usr/bin/plutil -extract "$1" json -o - "$2" 2>/dev/null || true; return 0; }

probe_mkdir() {
  if /bin/mkdir -p "$1" 2>/dev/null; then printf '1'; else printf '0'; fi
  return 0
}

# The single write this script is allowed to make, inside the output dir.
probe_write_file() {
  local path="$1"
  if /bin/cat > "$path" 2>/dev/null; then printf '1'; else printf '0'; fi
  return 0
}

probe_bash_version() { printf '%s' "${BASH_VERSION:-unknown}"; return 0; }

# =====================================================================
# Pure text helpers (no machine state; safe to leave alone when stubbing)
# =====================================================================

# Escape a string for a JSON double-quoted literal: backslash, double quote,
# and every control character below 0x20. Fast path skips awk entirely for the
# overwhelming majority of strings, which contain none of those.
json_escape() {
  case "$1" in
    *\\*|*\"*) ;;
    *[![:print:]]*) ;;
    *) printf '%s' "$1"; return 0 ;;
  esac
  printf '%s' "$1" | LC_ALL=C /usr/bin/awk '
    BEGIN { ORS = ""; for (i = 1; i < 256; i++) ord[sprintf("%c", i)] = i }
    {
      if (NR > 1) printf "\\n"
      n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        v = ord[c]
        if (c == "\\") printf "\\\\"
        else if (c == "\"") printf "\\\""
        else if (v != "" && v < 32) printf "\\u%04x", v
        else printf "%s", c
      }
    }'
  return 0
}

# JSON array literal from newline-delimited items on stdin. Always emits an
# array, even for zero or one element.
json_array_lines() {
  local out="[" first=1 line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ "$first" -eq 1 ]; then first=0; else out="${out},"; fi
    out="${out}\"$(json_escape "$line")\""
  done
  printf '%s]' "$out"
  return 0
}

# json_scan_block <blockname|--root>   (JSON on stdin)
# Prints "<key><TAB><raw value>" for every key directly inside that block.
# Hand-rolled because a clean Mac has no jq and no python3, and invoking the
# python3 shim on a machine without Xcode CLT pops a GUI install dialog.
json_scan_block() {
  LC_ALL=C /usr/bin/awk -v BLOCK="$1" '
  function skipval(s, i, n,   d, ins, esc, c) {
    d = 0; ins = 0; esc = 0
    while (i <= n) {
      c = substr(s, i, 1)
      if (ins) {
        if (esc) esc = 0
        else if (c == "\\") esc = 1
        else if (c == "\"") ins = 0
        i++
        continue
      }
      if (c == "\"") { ins = 1; i++; continue }
      if (c == "{" || c == "[") { d++; i++; continue }
      if (c == "}" || c == "]") {
        if (d == 0) return i
        d--; i++
        if (d == 0) return i
        continue
      }
      if (c == "," && d == 0) return i
      i++
    }
    return i
  }
  { txt = txt $0 "\n" }
  END {
    n = length(txt)
    if (BLOCK == "--root") {
      i = index(txt, "{")
      if (i == 0) exit
      i++
    } else {
      pat = "\"" BLOCK "\""
      j = index(txt, pat)
      if (j == 0) exit
      i = j + length(pat)
      while (i <= n && substr(txt, i, 1) != "{") {
        c = substr(txt, i, 1)
        if (c != " " && c != "\t" && c != "\n" && c != "\r" && c != ":") exit
        i++
      }
      if (i > n) exit
      i++
    }
    ins = 0; esc = 0; cur = ""; lastst = ""
    while (i <= n) {
      c = substr(txt, i, 1)
      if (ins) {
        if (esc) { esc = 0; cur = cur c }
        else if (c == "\\") { esc = 1; cur = cur c }
        else if (c == "\"") { ins = 0; lastst = cur }
        else cur = cur c
        i++
        continue
      }
      if (c == "\"") { ins = 1; cur = ""; i++; continue }
      if (c == "}") break
      if (c == ":") {
        i++
        while (i <= n) {
          c = substr(txt, i, 1)
          if (c == " " || c == "\t" || c == "\n" || c == "\r") i++
          else break
        }
        vs = i
        ve = skipval(txt, i, n)
        val = substr(txt, vs, ve - vs)
        gsub(/[\n\r\t]/, " ", val)
        printf "%s\t%s\n", lastst, val
        i = ve
        continue
      }
      i++
    }
  }' || true
  return 0
}

# Tenths to a one-decimal string, dropping a trailing .0 so whole numbers read
# the way the PowerShell version renders them.
fmt_tenths() {
  local t="${1:-0}" whole frac
  case "$t" in ''|*[!0-9]*) t=0 ;; esac
  whole=$(( t / 10 ))
  frac=$(( t % 10 ))
  if [ "$frac" -eq 0 ]; then printf '%s' "$whole"; else printf '%s.%s' "$whole" "$frac"; fi
  return 0
}

count_lines() {
  local n=0 line
  while IFS= read -r line; do
    [ -n "$line" ] && n=$(( n + 1 ))
  done
  printf '%s' "$n"
  return 0
}

join_lines() {
  local sep="$1" out="" first=1 line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [ "$first" -eq 1 ]; then out="$line"; first=0; else out="${out}${sep}${line}"; fi
  done
  printf '%s' "$out"
  return 0
}

# =====================================================================
# Finding store
# =====================================================================
F_COUNT=0
F_ID=(); F_CAT=(); F_STATUS=(); F_EVIDENCE=(); F_REC=(); F_DATA=()

# add_finding <id> <category> <status> [evidence] [recommendation] [data-json]
# evidence defaults to the empty string, never null.
# recommendation and data default to null, never "" and never {}. An empty
# argument means null: that distinction is load-bearing for the "What we would
# do" list and for schema parity with the Windows report.
add_finding() {
  local id="$1" cat="$2" status="$3"
  local evidence="${4:-}" rec="${5:-}" data="${6:-}"
  case "$status" in
    ok|gap|missing|info) ;;
    *) printf 'assess.sh: invalid status "%s" for finding %s\n' "$status" "$id" >&2; exit 1 ;;
  esac
  F_ID[$F_COUNT]="$id"
  F_CAT[$F_COUNT]="$cat"
  F_STATUS[$F_COUNT]="$status"
  F_EVIDENCE[$F_COUNT]="$evidence"
  F_REC[$F_COUNT]="$rec"
  F_DATA[$F_COUNT]="$data"
  F_COUNT=$(( F_COUNT + 1 ))
  return 0
}

# Index of the LAST finding with this id, or -1. Last wins, matching the
# PowerShell hashtable build.
finding_index() {
  local want="$1" i=0 found=-1
  while [ "$i" -lt "$F_COUNT" ]; do
    [ "${F_ID[$i]}" = "$want" ] && found=$i
    i=$(( i + 1 ))
  done
  printf '%s' "$found"
  return 0
}

finding_status() {
  local idx
  idx=$(finding_index "$1")
  [ "$idx" -ge 0 ] && printf '%s' "${F_STATUS[$idx]}"
  return 0
}

finding_evidence() {
  local idx
  idx=$(finding_index "$1")
  [ "$idx" -ge 0 ] && printf '%s' "${F_EVIDENCE[$idx]}"
  return 0
}

finding_data() {
  local idx
  idx=$(finding_index "$1")
  [ "$idx" -ge 0 ] && printf '%s' "${F_DATA[$idx]}"
  return 0
}

# =====================================================================
# JSON file reader (port of Get-JsonSafe)
# =====================================================================
JS_EXISTS=0; JS_VALID=0; JS_HASBOM=0; JS_ERROR=""

# bom_free_path <path> - the path to hand a JSON parser.
# plutil rejects a leading UTF-8 BOM outright, which would report a BOM'd but
# otherwise healthy config as corrupt: the one case the whole BOM check exists
# to describe. When the file starts with a BOM, work from a stripped copy in
# the scratch dir (it holds config contents, so it is cleaned up on exit).
# Falls back to the original path whenever the copy cannot be made.
bom_free_path() {
  local path="$1" copy
  if [ "$(probe_file_head_hex3 "$path")" != "efbbbf" ]; then
    printf '%s' "$path"
    return 0
  fi
  if [ -z "$ASSESS_TMP_DIR" ] || [ ! -d "$ASSESS_TMP_DIR" ]; then
    printf '%s' "$path"
    return 0
  fi
  copy="${ASSESS_TMP_DIR}/.nobom.$$"
  # tail is a pure byte transform over what a probe already read.
  if [ "$(probe_file_text "$path" | /usr/bin/tail -c +4 | probe_write_file "$copy")" = "1" ]; then
    printf '%s' "$copy"
  else
    printf '%s' "$path"
  fi
  return 0
}

json_safe() {
  local path="$1" parse_path
  JS_EXISTS=0; JS_VALID=0; JS_HASBOM=0; JS_ERROR=""
  [ "$(probe_file_exists "$path")" = "1" ] || return 0
  JS_EXISTS=1
  # A UTF-8 BOM is reported independently of lint: Claude Desktop's Node
  # JSON.parse rejects a BOM outright even when the rest of the file is fine.
  [ "$(probe_file_head_hex3 "$path")" = "efbbbf" ] && JS_HASBOM=1
  parse_path=$(bom_free_path "$path")
  if [ "$(probe_plutil_available)" != "1" ]; then
    # No parser on this machine. Degrade to "assume valid" rather than
    # reporting a healthy config as corrupt.
    JS_VALID=1
    return 0
  fi
  if [ "$(probe_plutil_lint "$parse_path")" = "1" ]; then
    JS_VALID=1
  else
    JS_ERROR=$(probe_plutil_lint_error "$parse_path")
    [ -n "$JS_ERROR" ] || JS_ERROR="could not parse"
  fi
  return 0
}

# Newline-delimited "<name><TAB><raw value>" for the mcpServers block of a
# config file. plutil first (exact, and immune to a same-named key deeper in
# the document), the hand-rolled scanner second.
read_mcp_servers() {
  local path="$1" parse_path sub size
  # plutil -extract fails on a leading BOM the same way plutil -lint does, so
  # feed it the stripped copy. The hand-rolled scanner below tolerates a BOM
  # (it searches for the "mcpServers" key inside the text), so the fallback can
  # stay on the original path.
  parse_path=$(bom_free_path "$path")
  sub=$(probe_plutil_extract_json mcpServers "$parse_path")
  case "$sub" in
    \{*) printf '%s\n' "$sub" | json_scan_block --root; return 0 ;;
  esac
  size=$(probe_file_size "$path")
  # ~/.claude.json carries project history and can run to megabytes. Scanning
  # that character by character in awk is not worth it; plutil already had its
  # chance above.
  if [ "$size" -gt 0 ] && [ "$size" -lt 524288 ]; then
    probe_file_text "$path" | json_scan_block mcpServers
  fi
  return 0
}

# =====================================================================
# Claude Desktop context (port of Get-ClaudeDesktopContext)
# =====================================================================
CTX_INSTALL_TYPE="none"; CTX_VERSION=""; CTX_CONFIG_DIR=""; CTX_CONFIG_PATH=""; CTX_APP=""

claude_desktop_context() {
  CTX_INSTALL_TYPE="none"; CTX_VERSION=""; CTX_CONFIG_DIR=""; CTX_CONFIG_PATH=""; CTX_APP=""
  local cand
  for cand in "/Applications/Claude.app" "${HOME}/Applications/Claude.app"; do
    if [ "$(probe_dir_exists "$cand")" = "1" ]; then
      CTX_APP="$cand"
      break
    fi
  done
  [ -n "$CTX_APP" ] || return 0
  # macOS has one install shape. 'msix' stays in the schema enum for
  # cross-platform compatibility but is never emitted here.
  CTX_INSTALL_TYPE="standard"
  CTX_VERSION=$(probe_plutil_extract_raw CFBundleShortVersionString "${CTX_APP}/Contents/Info.plist")
  CTX_CONFIG_DIR="${HOME}/Library/Application Support/Claude"
  CTX_CONFIG_PATH="${CTX_CONFIG_DIR}/claude_desktop_config.json"
  return 0
}

# =====================================================================
# Check 1: machine health (14 findings, always all 14)
# =====================================================================
check_machine_health() {
  local c="machine-health"

  # --- 1. OS support. macOS 13 Ventura is the Claude Code floor.
  local os_ver os_build os_major
  os_ver=$(probe_sw_vers productVersion)
  os_build=$(probe_sw_vers buildVersion)
  os_major="${os_ver%%.*}"
  case "$os_major" in ''|*[!0-9]*) os_major=0 ;; esac
  if [ "$os_major" -ge 13 ]; then
    add_finding 'machine.osSupport' "$c" 'ok' "macOS ${os_ver} (build ${os_build})"
  else
    add_finding 'machine.osSupport' "$c" 'missing' \
      "macOS ${os_ver} (build ${os_build}) - below the supported floor of macOS 13" \
      'Upgrade to macOS 13 Ventura or newer, or replace the machine before any install'
  fi

  # --- 2. Patch state. No offline equivalent of Get-HotFix, so this uses the
  # mtime of SystemVersion.plist, which is rewritten on every OS update.
  local sv_epoch now_epoch age_days last_date
  sv_epoch=$(probe_file_mtime_epoch "/System/Library/CoreServices/SystemVersion.plist")
  now_epoch=$(probe_now_epoch)
  if [ -n "$sv_epoch" ] && [ -n "$now_epoch" ]; then
    age_days=$(( ( now_epoch - sv_epoch ) / 86400 ))
    last_date=$(probe_epoch_to_date "$sv_epoch")
    # 90-day staleness threshold, matching assess.ps1 so the two platforms
    # score patch state the same way and their friction estimates compare.
    if [ "$age_days" -le 90 ]; then
      add_finding 'machine.patchState' "$c" 'ok' "Last system update ${last_date}"
    else
      add_finding 'machine.patchState' "$c" 'gap' "No system update since ${last_date}" \
        'Run Software Update before install day (a macOS update can take an hour)'
    fi
  else
    add_finding 'machine.patchState' "$c" 'info' 'Could not read update history'
  fi

  # --- 3. RAM. hw.memsize is installed DRAM, the honest analogue of
  # TotalPhysicalMemory. Not hw.usermem, not vm_stat.
  local mem_bytes ram_tenths ram_gb ram_status ram_rec
  mem_bytes=$(probe_sysctl hw.memsize)
  case "$mem_bytes" in ''|*[!0-9]*) mem_bytes=0 ;; esac
  ram_tenths=$(( mem_bytes * 10 / 1073741824 ))
  ram_gb=$(fmt_tenths "$ram_tenths")
  if [ "$ram_tenths" -ge 80 ]; then
    ram_status="ok"; ram_rec=""
  else
    ram_status="gap"
    ram_rec='8 GB minimum for Claude Desktop plus MCP servers; expect sluggish performance'
  fi
  add_finding 'machine.ram' "$c" "$ram_status" "${ram_gb} GB RAM" "$ram_rec" "{\"gb\":${ram_gb}}"

  # --- 4. Free disk space on the startup disk.
  local free_kb disk_tenths free_gb disk_status disk_rec
  free_kb=$(probe_df_free_kb)
  case "$free_kb" in ''|*[!0-9]*) free_kb=0 ;; esac
  disk_tenths=$(( free_kb * 10 / 1048576 ))
  free_gb=$(fmt_tenths "$disk_tenths")
  if [ "$disk_tenths" -ge 100 ]; then
    disk_status="ok"; disk_rec=""
  else
    disk_status="gap"; disk_rec='Free at least 10 GB before install'
  fi
  add_finding 'machine.disk' "$c" "$disk_status" "${free_gb} GB free on the startup disk" \
    "$disk_rec" "{\"freeGb\":${free_gb}}"

  # --- 5. CPU.
  local cpu_brand cpu_cores
  cpu_brand=$(probe_sysctl machdep.cpu.brand_string)
  [ -n "$cpu_brand" ] || cpu_brand="Unknown CPU"
  cpu_cores=$(probe_sysctl hw.physicalcpu)
  [ -n "$cpu_cores" ] || cpu_cores=$(probe_sysctl hw.ncpu)
  [ -n "$cpu_cores" ] || cpu_cores="?"
  add_finding 'machine.cpu' "$c" 'info' "${cpu_brand} (${cpu_cores} cores)"

  # --- 6. Architecture. Polarity is the opposite of Windows: on macOS both
  # arm64 and x86_64 are supported, so neither is a hard stop.
  local arch is_arm translated arch_real arch_note arch_status
  arch=$(probe_arch)
  is_arm=$(probe_sysctl hw.optional.arm64)
  translated=$(probe_sysctl sysctl.proc_translated)
  arch_real="$arch"
  arch_note=""
  if [ "$is_arm" = "1" ]; then
    arch_real="arm64"
    arch_note=" (Apple Silicon)"
    [ "$translated" = "1" ] && arch_note=" (Apple Silicon, this shell is running under Rosetta)"
  elif [ "$arch_real" = "x86_64" ]; then
    arch_note=" (Intel Mac, supported)"
  fi
  case "$arch_real" in
    arm64|x86_64) arch_status="ok" ;;
    *)            arch_status="missing" ;;
  esac
  if [ "$arch_status" = "ok" ]; then
    add_finding 'machine.arch' "$c" 'ok' "${arch_real}${arch_note}"
  else
    add_finding 'machine.arch' "$c" 'missing' "${arch_real:-unknown}" \
      'Unrecognised architecture: verify Claude Desktop and MCP support before committing'
  fi

  # --- 7. Admin reality. Several fallbacks before declaring someone not an
  # administrator: the Windows version got this wrong on its first real run and
  # read almost every admin as a standard user.
  local uid me admin_members dsedit groups admin_ok admin_evidence
  uid=$(probe_uid)
  me=$(probe_current_user)
  admin_ok=0; admin_evidence=""
  if [ "$uid" = "0" ]; then
    admin_ok=1; admin_evidence="Running as root"
  fi
  if [ "$admin_ok" -eq 0 ] && [ -n "$me" ]; then
    # "GroupMembership: root ben alice" -> whole-word match on the short name.
    admin_members=$(probe_dscl_admin_members)
    admin_members="${admin_members//$'\n'/ }"
    case " ${admin_members} " in
      *" ${me} "*) admin_ok=1; admin_evidence="User is an administrator" ;;
    esac
  fi
  if [ "$admin_ok" -eq 0 ] && [ -n "$me" ]; then
    dsedit=$(probe_dseditgroup_admin "$me")
    if [ "$dsedit" = "yes" ]; then
      admin_ok=1; admin_evidence="User is an administrator (confirmed by directory services)"
    fi
  fi
  if [ "$admin_ok" -eq 0 ]; then
    groups=$(probe_group_names)
    groups="${groups//$'\n'/ }"
    case " ${groups} " in
      *" admin "*) admin_ok=1; admin_evidence="User is an administrator (group membership)" ;;
    esac
  fi
  if [ "$admin_ok" -eq 1 ]; then
    add_finding 'machine.admin' "$c" 'ok' "$admin_evidence"
  else
    add_finding 'machine.admin' "$c" 'missing' 'Current user is not an administrator' \
      'Get the machine admin password or an admin account before install day'
  fi

  # --- 8. Directory binding (the domain-join analogue).
  local ad_out ad_count ad_first
  ad_out=$(probe_ad_domains)
  ad_count=$(printf '%s\n' "$ad_out" | count_lines)
  if [ "$ad_count" -gt 0 ]; then
    ad_first=$(printf '%s\n' "$ad_out" | /usr/bin/awk 'NF{print; exit}' || true)
    add_finding 'machine.domainJoin' "$c" 'gap' "Domain-joined: ${ad_first}" \
      'Company-managed machine: IT sign-off required before install'
  else
    add_finding 'machine.domainJoin' "$c" 'ok' 'Not domain-joined'
  fi

  # --- 9. MDM. A configuration profile is NOT MDM. Plenty of unmanaged Macs
  # carry an Apple beta profile, a school Wi-Fi profile, or a VPN profile, and
  # calling those "managed" would repeat the Windows false positive where every
  # machine read as enrolled because of built-in placeholder providers. Only an
  # explicit enrolment line or a named vendor agent counts.
  local mdm_out mdm_line dep_line vendors vendor_list prefs_count
  mdm_out=$(probe_mdm_enrollment)
  mdm_line=$(printf '%s\n' "$mdm_out" | /usr/bin/awk -F': ' '/^MDM enrollment/ {print $2; exit}' || true)
  dep_line=$(printf '%s\n' "$mdm_out" | /usr/bin/awk -F': ' '/^Enrolled via DEP/ {print $2; exit}' || true)
  vendors=$(probe_mdm_vendor_names)
  vendor_list=$(printf '%s\n' "$vendors" | join_lines ', ')
  prefs_count=$(probe_managed_prefs_names | count_lines)
  case "$mdm_line" in
    Yes*)
      add_finding 'machine.mdm' "$c" 'missing' \
        "MDM enrolment detected: ${mdm_line} (DEP: ${dep_line:-unknown})" \
        'Corporate-managed machine: out of standard scope, needs IT involvement'
      ;;
    *)
      if [ -n "$vendor_list" ]; then
        add_finding 'machine.mdm' "$c" 'missing' "Device management agent present: ${vendor_list}" \
          'Corporate-managed machine: out of standard scope, needs IT involvement'
      elif [ -z "$mdm_out" ]; then
        # The probe returned nothing at all: the enrolment state is genuinely
        # unreadable (the watchdog killed a slow 'profiles status', the binary
        # is missing, or policy blocked it), which is not the same as a machine
        # that answered "No". Fail closed, matching every other hard-stop gate
        # (osSupport, arch, admin all read an unreadable probe as not-ok) and
        # the posture the readiness layer was hardened to in 1590f7a.
        add_finding 'machine.mdm' "$c" 'gap' \
          'MDM enrolment state could not be read (management check timed out or was blocked)' \
          'Confirm with the customer whether this machine is company-managed before install day'
      elif [ -z "$mdm_line" ]; then
        # The probe answered but carried no enrolment line, and nothing else
        # corroborates management. Reported ok: a readable answer with no
        # management signal, not the unreadable case above.
        add_finding 'machine.mdm' "$c" 'ok' 'No MDM enrolment (no enrolment line, no management signals)'
      elif [ "$prefs_count" -gt 0 ]; then
        add_finding 'machine.mdm' "$c" 'ok' "No MDM enrolment (${prefs_count} configuration profiles present)"
      else
        add_finding 'machine.mdm' "$c" 'ok' 'No MDM enrolment'
      fi
      ;;
  esac

  # --- 10. Package manager. Kept under the Windows id for schema stability.
  # Homebrew is genuinely optional on macOS: the installer uses a signed
  # download plus curl, so a missing brew is never friction.
  local brew
  brew=$(probe_command_path brew)
  if [ -z "$brew" ]; then
    [ "$(probe_is_exec /opt/homebrew/bin/brew)" = "1" ] && brew="/opt/homebrew/bin/brew"
  fi
  if [ -z "$brew" ]; then
    [ "$(probe_is_exec /usr/local/bin/brew)" = "1" ] && brew="/usr/local/bin/brew"
  fi
  if [ -n "$brew" ]; then
    add_finding 'machine.winget' "$c" 'ok' "Homebrew available at ${brew}"
  else
    add_finding 'machine.winget' "$c" 'info' 'Homebrew not installed (not required on macOS)'
  fi

  # --- 11. Shell version (the PowerShell version analogue).
  add_finding 'machine.psVersion' "$c" 'info' "Bash $(probe_bash_version)"

  # --- 12. Gatekeeper (the closest thing to an execution policy). Notarised
  # installers run fine with Gatekeeper on, so this never becomes friction.
  local gk gk_text
  gk=$(probe_gatekeeper)
  case "$gk" in
    *enabled*)  gk_text="enabled" ;;
    *disabled*) gk_text="disabled" ;;
    *)          gk_text="unknown" ;;
  esac
  add_finding 'machine.executionPolicy' "$c" 'ok' "Gatekeeper: ${gk_text}"

  # --- 13. Third-party endpoint security. Worth more on macOS than Windows:
  # EDR products commonly block unsigned child processes, which is exactly what
  # an npx-launched MCP server is.
  local av_names av_list
  av_names=$( { probe_security_product_names; probe_security_process_names; } | /usr/bin/sort -u || true)
  av_list=$(printf '%s\n' "$av_names" | join_lines ', ')
  if [ -n "$av_list" ]; then
    add_finding 'machine.antivirus' "$c" 'gap' "Third-party endpoint security: ${av_list}" \
      'Third-party antivirus can block or slow installers; budget extra time'
  else
    add_finding 'machine.antivirus' "$c" 'ok' 'No third-party endpoint security detected'
  fi

  # --- 14. Pending reboot. macOS has no reliable unprivileged "reboot
  # pending" flag, so this reports the legacy marker plus long uptime.
  local boot_epoch up_days
  boot_epoch=$(probe_boot_epoch)
  up_days=""
  if [ -n "$boot_epoch" ] && [ -n "$now_epoch" ]; then
    up_days=$(( ( now_epoch - boot_epoch ) / 86400 ))
  fi
  if [ "$(probe_path_exists /var/db/.SoftwareUpdateAtLogout)" = "1" ]; then
    add_finding 'machine.pendingReboot' "$c" 'gap' 'Reboot pending' 'Reboot before install day'
  elif [ -n "$up_days" ] && [ "$up_days" -ge 30 ]; then
    # Long uptime is worth flagging to the operator but is NOT a pending reboot.
    # assess.ps1 and spec 9 row 14 have only two outcomes (reboot marker -> gap,
    # otherwise ok), so this is 'info': it surfaces the observation without
    # entering the friction table or flipping the verdict the way a 'gap' would.
    add_finding 'machine.pendingReboot' "$c" 'info' "No pending reboot (up ${up_days} days without a restart)"
  elif [ -n "$up_days" ]; then
    add_finding 'machine.pendingReboot' "$c" 'ok' "No pending reboot (up ${up_days} days)"
  else
    add_finding 'machine.pendingReboot' "$c" 'ok' 'No pending reboot'
  fi

  return 0
}

# =====================================================================
# Check 2: Claude Desktop (1 to 5 findings, two early returns)
# =====================================================================
check_claude_desktop() {
  local c="claude-desktop"
  claude_desktop_context

  if [ "$CTX_INSTALL_TYPE" = "none" ]; then
    add_finding 'desktop.installed' "$c" 'missing' 'Claude Desktop not installed' \
      'Install Claude Desktop (download from claude.ai/download)'
    return 0
  fi

  local ver_text="version unknown"
  [ -n "$CTX_VERSION" ] && ver_text="v${CTX_VERSION}"
  add_finding 'desktop.installed' "$c" 'ok' "${CTX_INSTALL_TYPE} install, ${ver_text}"

  json_safe "$CTX_CONFIG_PATH"
  if [ "$JS_EXISTS" -eq 0 ]; then
    add_finding 'desktop.config' "$c" 'missing' 'No claude_desktop_config.json' \
      'No MCP configuration exists; full setup required'
    return 0
  fi
  if [ "$JS_VALID" -eq 0 ]; then
    add_finding 'desktop.config' "$c" 'gap' "Config invalid JSON: ${JS_ERROR}" \
      'Config is corrupt; Claude Desktop cannot load it'
    return 0
  fi
  if [ "$JS_HASBOM" -eq 1 ]; then
    add_finding 'desktop.config' "$c" 'gap' 'Config valid (has UTF-8 BOM - Claude rejects this)' \
      'Rewrite config as BOM-less UTF-8'
  else
    add_finding 'desktop.config' "$c" 'ok' 'Config valid'
  fi

  local pairs names count names_json list
  pairs=$(read_mcp_servers "$CTX_CONFIG_PATH")
  names=$(printf '%s\n' "$pairs" | /usr/bin/awk -F'\t' 'NF && $1 != "" {print $1}' || true)
  count=$(printf '%s\n' "$names" | count_lines)
  names_json=$(printf '%s\n' "$names" | json_array_lines)
  if [ "$count" -gt 0 ]; then
    list=$(printf '%s\n' "$names" | join_lines ', ')
    add_finding 'desktop.mcpServers' "$c" 'ok' "${count} MCP servers: ${list}" "" \
      "{\"count\":${count},\"names\":${names_json}}"
  else
    add_finding 'desktop.mcpServers' "$c" 'gap' 'Config exists but no MCP servers configured' \
      'Install the Engine AI MCP bundle' "{\"count\":0,\"names\":[]}"
  fi

  if [ "$(probe_file_exists "${CTX_CONFIG_DIR}/developer_settings.json")" = "1" ]; then
    add_finding 'desktop.devSettings' "$c" 'ok' 'developer_settings.json present'
  else
    add_finding 'desktop.devSettings' "$c" 'info' 'No developer_settings.json'
  fi

  # Read-only: we look, we never pkill. The installer kills Claude; the
  # assessor must not.
  if [ "$(probe_claude_process_count)" -gt 0 ]; then
    add_finding 'desktop.running' "$c" 'info' 'Claude Desktop is currently running'
  else
    add_finding 'desktop.running' "$c" 'info' 'Claude Desktop not running'
  fi

  return 0
}

# =====================================================================
# Check 3: Claude Code CLI (1 or 5 findings, one early return)
# =====================================================================
check_claude_code() {
  local c="claude-code"
  local claude_dir="${HOME}/.claude"
  local cli cand ver

  cli=$(probe_command_path claude)
  if [ -n "$cli" ]; then
    ver=$(probe_first_line_of 8 "$cli" --version)
    if [ -n "$ver" ]; then
      add_finding 'code.installed' "$c" 'ok' "On PATH, ${ver}"
    else
      add_finding 'code.installed' "$c" 'ok' 'On PATH'
    fi
  else
    for cand in "${HOME}/.local/bin/claude" "${claude_dir}/bin/claude" \
                "/opt/homebrew/bin/claude" "/usr/local/bin/claude"; do
      if [ "$(probe_is_exec "$cand")" = "1" ]; then
        cli="$cand"
        break
      fi
    done
    if [ -n "$cli" ]; then
      add_finding 'code.installed' "$c" 'ok' "Installed at ${cli} (not on PATH in this shell)"
    else
      add_finding 'code.installed' "$c" 'missing' 'Claude Code CLI not installed' \
        'Install Claude Code (skills and agent workflows run here)'
      return 0
    fi
  fi

  if [ "$(probe_file_exists "${claude_dir}/settings.json")" = "1" ]; then
    add_finding 'code.settings' "$c" 'ok' 'settings.json present'
  else
    add_finding 'code.settings' "$c" 'gap' 'No settings.json' 'Apply Engine AI baseline settings'
  fi

  local skills skill_count skills_json skill_list
  skills=$(probe_list_subdir_names "${claude_dir}/skills")
  skill_count=$(printf '%s\n' "$skills" | count_lines)
  if [ "$skill_count" -gt 0 ]; then
    skills_json=$(printf '%s\n' "$skills" | json_array_lines)
    skill_list=$(printf '%s\n' "$skills" | join_lines ', ')
    add_finding 'code.skills' "$c" 'ok' "${skill_count} skills: ${skill_list}" "" \
      "{\"names\":${skills_json}}"
  else
    add_finding 'code.skills' "$c" 'gap' 'No skills installed' 'Install the Engine AI skill bundle'
  fi

  if [ "$(probe_file_exists "${claude_dir}/CLAUDE.md")" = "1" ]; then
    add_finding 'code.claudeMd' "$c" 'ok' 'Global CLAUDE.md present'
  else
    add_finding 'code.claudeMd' "$c" 'info' 'No global CLAUDE.md'
  fi

  local code_cfg pairs names count names_json list
  code_cfg="${HOME}/.claude.json"
  names=""
  json_safe "$code_cfg"
  if [ "$JS_EXISTS" -eq 1 ] && [ "$JS_VALID" -eq 1 ]; then
    pairs=$(read_mcp_servers "$code_cfg")
    names=$(printf '%s\n' "$pairs" | /usr/bin/awk -F'\t' 'NF && $1 != "" {print $1}' || true)
  fi
  count=$(printf '%s\n' "$names" | count_lines)
  names_json=$(printf '%s\n' "$names" | json_array_lines)
  if [ "$count" -gt 0 ]; then
    list=$(printf '%s\n' "$names" | join_lines ', ')
    add_finding 'code.mcpServers' "$c" 'ok' "${count} MCP servers: ${list}" "" \
      "{\"count\":${count},\"names\":${names_json}}"
  else
    add_finding 'code.mcpServers' "$c" 'info' 'No Code-side MCP servers' "" \
      "{\"count\":0,\"names\":[]}"
  fi

  return 0
}

# =====================================================================
# Check 4: MCP runtime (2 + N findings)
# =====================================================================

# Pure per-server check. Problems accumulate; none short-circuit.
# Sets MCP_ENTRY_STATUS and MCP_ENTRY_EVIDENCE.
MCP_ENTRY_STATUS=""; MCP_ENTRY_EVIDENCE=""
mcp_server_entry() {
  local name="$1" raw="$2" npx_available="$3"
  local problems="" cmd re_ph re_cmd
  MCP_ENTRY_STATUS=""; MCP_ENTRY_EVIDENCE=""

  re_ph='\{\{[A-Za-z0-9_-]+\}\}'
  if [[ $raw =~ $re_ph ]]; then
    problems="unfilled placeholder tokens"
  fi

  cmd=""
  re_cmd='"command"[[:space:]]*:[[:space:]]*"([^"]*)"'
  if [[ $raw =~ $re_cmd ]]; then
    cmd="${BASH_REMATCH[1]}"
  fi

  local problem=""
  if [ -z "$cmd" ]; then
    problem="no command"
  else
    case "$cmd" in
      /*)
        [ "$(probe_path_exists "$cmd")" = "1" ] || problem="command not found: ${cmd}"
        ;;
      npx)
        [ "$npx_available" = "1" ] || problem="npx not available (Node missing)"
        ;;
      *)
        [ -n "$(probe_command_path "$cmd")" ] || problem="command not on PATH: ${cmd}"
        ;;
    esac
  fi
  if [ -n "$problem" ]; then
    if [ -n "$problems" ]; then problems="${problems}; ${problem}"; else problems="$problem"; fi
  fi

  if [ -z "$problems" ]; then
    MCP_ENTRY_STATUS="ok"
    MCP_ENTRY_EVIDENCE="Resolvable, no placeholders"
  else
    MCP_ENTRY_STATUS="gap"
    MCP_ENTRY_EVIDENCE="$problems"
  fi
  return 0
}

check_mcp_runtime() {
  local c="mcp-runtime"
  local node npx npx_available node_ver node_note

  node=$(probe_command_path node)
  npx=$(probe_command_path npx)
  npx_available=0
  [ -n "$npx" ] && npx_available=1

  if [ -n "$node" ]; then
    node_ver=$(probe_first_line_of 5 "$node" --version)
    [ -n "$node_ver" ] || node_ver="version unknown"
    node_note=""
    # A node installed by nvm is on the shell PATH but not on the PATH that a
    # Dock-launched Claude Desktop inherits from launchd, so MCP servers fail
    # at runtime even though node looks present here.
    case "$node" in
      *"/.nvm/"*) node_note=" (nvm install: Claude Desktop launched from the Dock may not see it)" ;;
    esac
    add_finding 'mcp.node' "$c" 'ok' "Node ${node_ver}${node_note}"
  else
    add_finding 'mcp.node' "$c" 'missing' 'Node.js not installed' \
      'MCP servers cannot run without Node.js'
  fi

  # Only the Desktop config is walked, matching the Windows implementation.
  claude_desktop_context
  local fs_ok=0 pairs name raw line
  if [ -n "$CTX_CONFIG_PATH" ]; then
    json_safe "$CTX_CONFIG_PATH"
    if [ "$JS_EXISTS" -eq 1 ] && [ "$JS_VALID" -eq 1 ]; then
      pairs=$(read_mcp_servers "$CTX_CONFIG_PATH")
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        name="${line%%	*}"
        raw="${line#*	}"
        [ -n "$name" ] || continue
        mcp_server_entry "$name" "$raw" "$npx_available"
        if [ "$MCP_ENTRY_STATUS" = "ok" ]; then
          add_finding "mcp.server.${name}" "$c" 'ok' "$MCP_ENTRY_EVIDENCE"
        else
          add_finding "mcp.server.${name}" "$c" 'gap' "$MCP_ENTRY_EVIDENCE" \
            "Server '${name}' is configured but cannot work as-is"
        fi
        # Case-insensitive, matching assess.ps1 where -match is case-insensitive
        # by default. A hand-edited config keyed "Filesystem" or "FileSystem"
        # must still count, or the two platforms disagree on maturity level.
        shopt -s nocasematch
        if [[ $name =~ filesystem ]] && [ "$MCP_ENTRY_STATUS" = "ok" ]; then fs_ok=1; fi
        shopt -u nocasematch
      done <<EOF
$pairs
EOF
    fi
  fi

  if [ "$fs_ok" -eq 1 ]; then
    add_finding 'mcp.filesystem' "$c" 'ok' 'Working filesystem MCP configured'
  else
    add_finding 'mcp.filesystem' "$c" 'gap' 'No working filesystem MCP' \
      'Claude cannot reach local files; connect the filesystem MCP to where the files live'
  fi

  return 0
}

# =====================================================================
# Check 5: data landscape (exactly 5 findings)
# =====================================================================
check_data_landscape() {
  local c="data-landscape"
  local cs_dir="${HOME}/Library/CloudStorage"
  local cs entry

  cs=$(probe_list_names "$cs_dir")

  # --- 1. OneDrive. Since macOS 12.3 every File Provider sync root lives
  # under ~/Library/CloudStorage. Stop at the top level: recursing asks the
  # File Provider to materialise placeholders, which is a network fetch and a
  # write to the provider's state.
  local od_paths=""
  while IFS= read -r entry; do
    case "$entry" in
      OneDrive*) od_paths="${od_paths}${cs_dir}/${entry}
" ;;
    esac
  done <<EOF
$cs
EOF
  if [ "$(probe_dir_exists "${HOME}/OneDrive")" = "1" ]; then
    od_paths="${od_paths}${HOME}/OneDrive
"
  fi
  local od_count od_json od_list
  od_count=$(printf '%s' "$od_paths" | count_lines)
  od_json=$(printf '%s' "$od_paths" | json_array_lines)
  if [ "$od_count" -gt 0 ]; then
    od_list=$(printf '%s' "$od_paths" | join_lines '; ')
    add_finding 'data.oneDrive' "$c" 'ok' "OneDrive: ${od_list}" "" "{\"paths\":${od_json}}"
  else
    add_finding 'data.oneDrive' "$c" 'info' 'No OneDrive detected' "" '{"paths":[]}'
  fi

  # --- 2. Redirected home folders. Windows calls this Known Folder Move; on
  # macOS the same thing happens through iCloud Desktop & Documents or a
  # OneDrive folder move, both of which present as a symlink.
  local docs desktop docs_target desktop_target redirected redirect_kind
  docs="${HOME}/Documents"
  desktop="${HOME}/Desktop"
  redirected="false"
  redirect_kind=""
  if [ "$(probe_is_symlink "$docs")" = "1" ]; then
    docs_target=$(probe_readlink "$docs")
    [ -n "$docs_target" ] && docs="$docs_target"
  fi
  if [ "$(probe_is_symlink "$desktop")" = "1" ]; then
    desktop_target=$(probe_readlink "$desktop")
    [ -n "$desktop_target" ] && desktop="$desktop_target"
  fi
  case "${docs}${desktop}" in
    *com~apple~CloudDocs*) redirected="true"; redirect_kind="iCloud Drive" ;;
    *CloudStorage/OneDrive*) redirected="true"; redirect_kind="OneDrive" ;;
  esac
  if [ "$redirected" = "true" ]; then
    add_finding 'data.kfm' "$c" 'info' \
      "Desktop/Documents redirected into ${redirect_kind} (Documents: ${docs})" "" \
      "{\"redirected\":true,\"documents\":\"$(json_escape "$docs")\",\"desktop\":\"$(json_escape "$desktop")\"}"
  else
    add_finding 'data.kfm' "$c" 'info' "Desktop/Documents local (Documents: ${docs})" "" \
      "{\"redirected\":false,\"documents\":\"$(json_escape "$docs")\",\"desktop\":\"$(json_escape "$desktop")\"}"
  fi

  # --- 3. Google Drive for desktop.
  local gd_paths=""
  while IFS= read -r entry; do
    case "$entry" in
      GoogleDrive*) gd_paths="${gd_paths}${cs_dir}/${entry}
" ;;
    esac
  done <<EOF
$cs
EOF
  if [ "$(probe_dir_exists "/Volumes/GoogleDrive")" = "1" ]; then
    gd_paths="${gd_paths}/Volumes/GoogleDrive
"
  fi
  local gd_count gd_json gd_list
  gd_count=$(printf '%s' "$gd_paths" | count_lines)
  if [ "$gd_count" -eq 0 ] && [ "$(probe_dir_exists "/Applications/Google Drive.app")" = "1" ]; then
    gd_paths="installed (mount not found)
"
    gd_count=1
  fi
  gd_json=$(printf '%s' "$gd_paths" | json_array_lines)
  if [ "$gd_count" -gt 0 ]; then
    gd_list=$(printf '%s' "$gd_paths" | join_lines '; ')
    add_finding 'data.googleDrive' "$c" 'ok' "Google Drive for desktop: ${gd_list}" "" \
      "{\"paths\":${gd_json}}"
  else
    add_finding 'data.googleDrive' "$c" 'info' 'No Google Drive for desktop' "" '{"paths":[]}'
  fi

  # --- 4. Dropbox.
  local dropbox=""
  if [ "$(probe_dir_exists "${cs_dir}/Dropbox")" = "1" ]; then
    dropbox="${cs_dir}/Dropbox"
  elif [ "$(probe_dir_exists "${HOME}/Dropbox")" = "1" ]; then
    dropbox="${HOME}/Dropbox"
  fi
  if [ -n "$dropbox" ]; then
    add_finding 'data.dropbox' "$c" 'info' "Dropbox at ${dropbox}"
  else
    add_finding 'data.dropbox' "$c" 'info' 'No Dropbox'
  fi

  # --- 5. Network mounts. The Windows version reads the registry instead of
  # WMI because WMI resolved each SMB provider serially (41s for six drives).
  # Same principle here: read the mount table, never stat the mounts.
  local mnt line src rest mp desc="" drives_json="[]" first=1 drive_count=0
  mnt=$(probe_mount_table)
  while IFS= read -r line; do
    case "$line" in
      *"(smbfs"*|*"(nfs"*|*"(afpfs"*|*"(webdav"*|*"(ftpfs"*|*"(cifs"*)
        src="${line%% on *}"
        rest="${line#* on }"
        mp="${rest%% (*}"
        [ -n "$mp" ] || continue
        drive_count=$(( drive_count + 1 ))
        if [ -n "$desc" ]; then desc="${desc}; ${mp} -> ${src}"; else desc="${mp} -> ${src}"; fi
        if [ "$first" -eq 1 ]; then
          drives_json="[{\"letter\":\"$(json_escape "$mp")\",\"unc\":\"$(json_escape "$src")\"}"
          first=0
        else
          drives_json="${drives_json},{\"letter\":\"$(json_escape "$mp")\",\"unc\":\"$(json_escape "$src")\"}"
        fi
        ;;
    esac
  done <<EOF
$mnt
EOF
  if [ "$drive_count" -gt 0 ]; then
    drives_json="${drives_json}]"
    add_finding 'data.mappedDrives' "$c" 'ok' "Mapped drives: ${desc}" "" \
      "{\"drives\":${drives_json}}"
  else
    add_finding 'data.mappedDrives' "$c" 'info' 'No mapped network drives'
  fi

  return 0
}

# =====================================================================
# Installed application inventory (memoised, the Get-InstalledPrograms port)
# =====================================================================
INSTALLED_APPS=""
INSTALLED_APPS_LOADED=0
installed_apps() {
  if [ "$INSTALLED_APPS_LOADED" -eq 0 ]; then
    # Deliberately not system_profiler SPApplicationsDataType: 12-18s and
    # 1.2-1.8 GB on an M-series Mac, which alone would blow the scan budget.
    INSTALLED_APPS=$(probe_apps_names)
    INSTALLED_APPS_LOADED=1
  fi
  printf '%s\n' "$INSTALLED_APPS"
  return 0
}

RUNNING_PROCS=""
RUNNING_PROCS_LOADED=0
running_procs() {
  if [ "$RUNNING_PROCS_LOADED" -eq 0 ]; then
    RUNNING_PROCS=$(probe_process_names)
    RUNNING_PROCS_LOADED=1
  fi
  printf '%s\n' "$RUNNING_PROCS"
  return 0
}

# Case-insensitive regex match of a pattern against a newline-delimited list.
list_matches() {
  local pattern="$1" list="$2" line rc=1
  shopt -s nocasematch
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    if [[ $line =~ $pattern ]]; then rc=0; break; fi
  done <<EOF
$list
EOF
  shopt -u nocasematch
  return "$rc"
}

# =====================================================================
# Check 6: work stack (exactly 3 findings, all info)
# =====================================================================
check_work_stack() {
  local c="work-stack"
  local apps cloud ms="" g="" stack browser
  apps=$(installed_apps)
  cloud=$(probe_list_names "${HOME}/Library/CloudStorage")

  if list_matches '^Microsoft (Word|Excel|Outlook|PowerPoint|OneNote)' "$apps"; then
    ms="Office listed in programs"
  fi
  if list_matches '^Microsoft Teams' "$apps" || list_matches 'Teams' "$(running_procs)"; then
    if [ -n "$ms" ]; then ms="${ms}, Teams"; else ms="Teams"; fi
  fi
  if list_matches '^OneDrive' "$cloud"; then
    if [ -n "$ms" ]; then ms="${ms}, OneDrive"; else ms="OneDrive"; fi
  fi

  if list_matches '^GoogleDrive' "$cloud" || \
     [ "$(probe_dir_exists "/Applications/Google Drive.app")" = "1" ]; then
    g="Google Drive for desktop"
  fi
  browser=$(probe_default_browser)
  case "$browser" in
    *google.chrome*)
      if [ -n "$g" ]; then g="${g}, Chrome default browser"; else g="Chrome default browser"; fi
      ;;
  esac

  if [ -n "$ms" ]; then
    add_finding 'stack.microsoft' "$c" 'info' "$ms"
  else
    add_finding 'stack.microsoft' "$c" 'info' 'No Microsoft stack signals'
  fi
  if [ -n "$g" ]; then
    add_finding 'stack.google' "$c" 'info' "$g"
  else
    add_finding 'stack.google' "$c" 'info' 'No Google stack signals'
  fi

  if [ -n "$ms" ] && [ -n "$g" ]; then
    stack="mixed"
  elif [ -n "$ms" ]; then
    stack="microsoft"
  elif [ -n "$g" ]; then
    stack="google"
  else
    stack="unknown"
  fi
  add_finding 'stack.verdict' "$c" 'info' "Work stack: ${stack}" "" "{\"stack\":\"${stack}\"}"

  return 0
}

# =====================================================================
# Check 7: opportunity scan (0-11 app findings + 1 summary, all info)
# =====================================================================
# key|display name|app bundle regex|process regex|mcp available
# Same keys, same display names, and same mcp flags as the Windows table, so
# the finding ids and evidence strings match. Only the match patterns are
# macOS-shaped (the bundle is literally named zoom.us, for instance).
# The fields are pipe-delimited, so a pattern must never contain a pipe: use a
# substring instead of regex alternation.
KNOWN_APPS='slack|Slack|^Slack$|^Slack$|true
teams|Microsoft Teams|^Microsoft Teams|Teams|true
zoom|Zoom|^zoom\.us$|^zoom\.us$|false
notion|Notion|^Notion|^Notion$|true
xero|Xero|Xero|Xero|true
myob|MYOB|MYOB|MYOB|false
quickbooks|QuickBooks|QuickBooks|QuickBooks|false
dropbox|Dropbox|^Dropbox$|^Dropbox$|true
chatgpt|ChatGPT Desktop|^ChatGPT$|^ChatGPT$|false
copilot|GitHub Copilot|GitHub Copilot||false
cursor|Cursor|^Cursor$|^Cursor$|false'

check_opportunity_scan() {
  local c="opportunity-scan"
  local apps procs row key name match proc mcp
  local detected="" mcp_ready="" detected_count=0 mcp_count=0 hit note

  apps=$(installed_apps)
  procs=$(running_procs)

  while IFS= read -r row; do
    [ -n "$row" ] || continue
    key="${row%%|*}"; row="${row#*|}"
    name="${row%%|*}"; row="${row#*|}"
    match="${row%%|*}"; row="${row#*|}"
    proc="${row%%|*}"; row="${row#*|}"
    mcp="$row"

    hit=0
    if [ -n "$match" ] && list_matches "$match" "$apps"; then hit=1; fi
    if [ "$hit" -eq 0 ] && [ -n "$proc" ] && list_matches "$proc" "$procs"; then hit=1; fi
    [ "$hit" -eq 1 ] || continue

    detected="${detected}${name}
"
    detected_count=$(( detected_count + 1 ))
    if [ "$mcp" = "true" ]; then
      mcp_ready="${mcp_ready}${name}
"
      mcp_count=$(( mcp_count + 1 ))
      note="MCP connector available"
    else
      note="no MCP connector yet"
    fi
    add_finding "apps.${key}" "$c" 'info' "${name} detected (${note})" "" \
      "{\"mcpAvailable\":${mcp}}"
  done <<EOF
$KNOWN_APPS
EOF

  local detected_json mcp_json rec
  detected_json=$(printf '%s' "$detected" | json_array_lines)
  mcp_json=$(printf '%s' "$mcp_ready" | json_array_lines)
  rec=""
  if [ "$mcp_count" -gt 0 ]; then
    rec="Connect Claude to: $(printf '%s' "$mcp_ready" | join_lines ', ')"
  fi
  add_finding 'apps.summary' "$c" 'info' \
    "${detected_count} known business apps detected, ${mcp_count} connectable to Claude" \
    "$rec" "{\"detected\":${detected_json},\"mcpReady\":${mcp_json}}"

  return 0
}

# =====================================================================
# Maturity level (0-4)
# =====================================================================
MATURITY=0
maturity_level() {
  local desktop_ok=0 code_ok=0 node_ok=0 fs_ok=0 skills_ok=0 mcp_count=0 data
  [ "$(finding_status 'desktop.installed')" = "ok" ] && desktop_ok=1
  [ "$(finding_status 'code.installed')" = "ok" ] && code_ok=1
  if [ "$desktop_ok" -eq 0 ] && [ "$code_ok" -eq 0 ]; then MATURITY=0; return 0; fi

  data=$(finding_data 'desktop.mcpServers')
  if [ -n "$data" ]; then
    mcp_count=$(printf '%s' "$data" | /usr/bin/sed -n 's/.*"count":\([0-9][0-9]*\).*/\1/p' || true)
    case "$mcp_count" in ''|*[!0-9]*) mcp_count=0 ;; esac
  fi
  if [ "$mcp_count" -eq 0 ]; then MATURITY=1; return 0; fi

  [ "$(finding_status 'mcp.node')" = "ok" ] && node_ok=1
  [ "$(finding_status 'mcp.filesystem')" = "ok" ] && fs_ok=1
  if [ "$node_ok" -eq 0 ] || [ "$fs_ok" -eq 0 ]; then MATURITY=2; return 0; fi

  [ "$(finding_status 'code.skills')" = "ok" ] && skills_ok=1
  if [ "$code_ok" -eq 1 ] && [ "$skills_ok" -eq 1 ]; then MATURITY=4; return 0; fi
  MATURITY=3
  return 0
}

maturity_label() {
  case "$1" in
    0) printf 'Level 0 - Web only' ;;
    1) printf 'Level 1 - Desktop installed' ;;
    2) printf 'Level 2 - Partially connected' ;;
    3) printf 'Level 3 - Connected' ;;
    4) printf 'Level 4 - Orchestrated' ;;
  esac
  return 0
}

# =====================================================================
# Readiness verdict
# =====================================================================
VERDICT=""
B_COUNT=0
B_ID=(); B_EVIDENCE=(); B_EST=()

HARD_STOP_IDS="machine.osSupport machine.admin machine.mdm machine.arch"
# id:minutes, in emission order. Same ids and same minutes as the Windows
# table so the two reports add up the same way, with one deliberate platform
# divergence: machine.winget carries no estimate here. On Windows winget is the
# install path for Claude Desktop, so a missing winget is real friction (gap,
# 20 min). On macOS the installer uses a signed download plus curl and never
# touches Homebrew, so machine.winget is only ever 'ok' or 'info', never 'gap'.
# A machine.winget:20 row would be dead code implying a gate that can never
# fire, so it is intentionally omitted.
FRICTION_ESTIMATES="machine.patchState:45
machine.disk:20
machine.ram:0
machine.antivirus:15
machine.pendingReboot:10
machine.executionPolicy:10"

add_blocker() {
  B_ID[$B_COUNT]="$1"
  B_EVIDENCE[$B_COUNT]="$2"
  B_EST[$B_COUNT]="$3"
  B_COUNT=$(( B_COUNT + 1 ))
  return 0
}

readiness_verdict() {
  local hard=0 id idx row est
  B_COUNT=0; B_ID=(); B_EVIDENCE=(); B_EST=()

  # Fail closed. An absent hard-stop finding is treated exactly like a failing
  # one: if a check crashed, the verdict must not silently read "ready".
  for id in $HARD_STOP_IDS; do
    idx=$(finding_index "$id")
    if [ "$idx" -lt 0 ]; then
      hard=1
      add_blocker "$id" "Health check incomplete: ${id} missing" ""
    elif [ "${F_STATUS[$idx]}" != "ok" ]; then
      hard=1
      add_blocker "$id" "${F_EVIDENCE[$idx]}" ""
    fi
  done

  while IFS= read -r row; do
    [ -n "$row" ] || continue
    id="${row%%:*}"
    est="${row##*:}"
    idx=$(finding_index "$id")
    if [ "$idx" -ge 0 ] && [ "${F_STATUS[$idx]}" = "gap" ]; then
      add_blocker "$id" "${F_EVIDENCE[$idx]}" "$est"
    fi
  done <<EOF
$FRICTION_ESTIMATES
EOF

  if [ "$hard" -eq 1 ]; then
    VERDICT="not-ready"
  elif [ "$B_COUNT" -gt 0 ]; then
    VERDICT="ready-with-friction"
  else
    VERDICT="ready"
  fi
  return 0
}

# Sum of friction minutes. An estimate of 0 (machine.ram) is excluded on
# purpose: low RAM is a blocker line but adds no time to the install.
friction_minutes() {
  local i=0 total=0 e
  while [ "$i" -lt "$B_COUNT" ]; do
    e="${B_EST[$i]}"
    case "$e" in
      ''|*[!0-9]*) ;;
      *) [ "$e" -gt 0 ] && total=$(( total + e )) ;;
    esac
    i=$(( i + 1 ))
  done
  printf '%s' "$total"
  return 0
}

# =====================================================================
# JSON export
# =====================================================================
REPORT_PATH=""
export_json() {
  local stamp i status ok_count=0 gap_count=0 missing_count=0
  stamp=$(probe_now_stamp)
  [ -n "$stamp" ] || stamp="report"
  REPORT_PATH="${OUT_DIR}/${stamp}.json"

  i=0
  while [ "$i" -lt "$F_COUNT" ]; do
    status="${F_STATUS[$i]}"
    case "$status" in
      ok)      ok_count=$(( ok_count + 1 )) ;;
      gap)     gap_count=$(( gap_count + 1 )) ;;
      missing) missing_count=$(( missing_count + 1 )) ;;
    esac
    i=$(( i + 1 ))
  done

  local os_ver os_build host user arch is_arm
  os_ver=$(probe_sw_vers productVersion)
  os_build=$(probe_sw_vers buildVersion)
  host=$(probe_hostname)
  user=$(probe_current_user)
  arch=$(probe_arch)
  is_arm=$(probe_sysctl hw.optional.arm64)
  [ "$is_arm" = "1" ] && arch="arm64"

  # Plain UTF-8, no BOM. Never prepend one: the Node JSON parser on the other
  # side of this pipeline rejects it.
  {
    printf '{\n'
    printf '  "schemaVersion": %s,\n' "$SCHEMA_VERSION"
    printf '  "assessVersion": "%s",\n' "$(json_escape "$ASSESS_VERSION")"
    printf '  "timestamp": "%s",\n' "$(json_escape "$(probe_now_iso)")"
    printf '  "machine": {\n'
    printf '    "hostname": "%s",\n' "$(json_escape "$host")"
    printf '    "user": "%s",\n' "$(json_escape "$user")"
    printf '    "os": "%s",\n' "$(json_escape "macOS ${os_ver} (${os_build})")"
    printf '    "arch": "%s"\n' "$(json_escape "$arch")"
    printf '  },\n'
    printf '  "maturityLevel": %s,\n' "$MATURITY"
    printf '  "readiness": {\n'
    printf '    "verdict": "%s",\n' "$VERDICT"
    printf '    "blockers": ['
    i=0
    while [ "$i" -lt "$B_COUNT" ]; do
      [ "$i" -gt 0 ] && printf ','
      printf '\n      { "id": "%s", "evidence": "%s", "estimateMinutes": %s }' \
        "$(json_escape "${B_ID[$i]}")" \
        "$(json_escape "${B_EVIDENCE[$i]}")" \
        "$( [ -n "${B_EST[$i]}" ] && printf '%s' "${B_EST[$i]}" || printf 'null' )"
      i=$(( i + 1 ))
    done
    [ "$B_COUNT" -gt 0 ] && printf '\n    '
    printf ']\n'
    printf '  },\n'
    printf '  "findings": ['
    i=0
    while [ "$i" -lt "$F_COUNT" ]; do
      [ "$i" -gt 0 ] && printf ','
      printf '\n    {\n'
      printf '      "id": "%s",\n' "$(json_escape "${F_ID[$i]}")"
      printf '      "category": "%s",\n' "$(json_escape "${F_CAT[$i]}")"
      printf '      "status": "%s",\n' "$(json_escape "${F_STATUS[$i]}")"
      printf '      "evidence": "%s",\n' "$(json_escape "${F_EVIDENCE[$i]}")"
      if [ -n "${F_REC[$i]}" ]; then
        printf '      "recommendation": "%s",\n' "$(json_escape "${F_REC[$i]}")"
      else
        printf '      "recommendation": null,\n'
      fi
      if [ -n "${F_DATA[$i]}" ]; then
        printf '      "data": %s\n' "${F_DATA[$i]}"
      else
        printf '      "data": null\n'
      fi
      printf '    }'
      i=$(( i + 1 ))
    done
    [ "$F_COUNT" -gt 0 ] && printf '\n  '
    printf '],\n'
    printf '  "summary": { "ok": %s, "gap": %s, "missing": %s }\n' \
      "$ok_count" "$gap_count" "$missing_count"
    printf '}\n'
  } | probe_write_file "$REPORT_PATH" >/dev/null

  return 0
}

# =====================================================================
# Console rendering (mirrors Write-AssessConsole)
# =====================================================================
write_console() {
  local cat i any status prefix colour rec_shown=0

  for cat in $CATEGORY_ORDER; do
    any=0
    i=0
    while [ "$i" -lt "$F_COUNT" ]; do
      [ "${F_CAT[$i]}" = "$cat" ] && { any=1; break; }
      i=$(( i + 1 ))
    done
    [ "$any" -eq 1 ] || continue

    blank
    say "$C_YELLOW" "== ${cat} =="
    i=0
    while [ "$i" -lt "$F_COUNT" ]; do
      if [ "${F_CAT[$i]}" = "$cat" ]; then
        status="${F_STATUS[$i]}"
        case "$status" in
          ok)      prefix="  [OK]  "; colour="$C_GREEN" ;;
          gap)     prefix="  [GAP] "; colour="$C_DARKYELLOW" ;;
          missing) prefix="  [--]  "; colour="$C_RED" ;;
          *)       prefix="  [i]   "; colour="$C_GRAY" ;;
        esac
        say "$colour" "${prefix}${F_EVIDENCE[$i]}"
      fi
      i=$(( i + 1 ))
    done
  done

  blank
  sayn "" "Claude maturity: "
  say "$C_CYAN" "$(maturity_label "$MATURITY")"

  sayn "" "Install readiness: "
  case "$VERDICT" in
    ready)
      say "$C_GREEN" "READY (about 30 min standard install)"
      ;;
    ready-with-friction)
      say "$C_DARKYELLOW" "READY WITH FRICTION (add roughly $(friction_minutes) min)"
      i=0
      while [ "$i" -lt "$B_COUNT" ]; do
        say "$C_DARKYELLOW" "    - ${B_EVIDENCE[$i]}"
        i=$(( i + 1 ))
      done
      ;;
    not-ready)
      say "$C_RED" "NOT READY"
      i=0
      while [ "$i" -lt "$B_COUNT" ]; do
        say "$C_RED" "    - ${B_EVIDENCE[$i]}"
        i=$(( i + 1 ))
      done
      ;;
  esac

  # First five recommendations attached to a gap or missing finding, in
  # findings order.
  i=0
  while [ "$i" -lt "$F_COUNT" ] && [ "$rec_shown" -lt 5 ]; do
    if [ -n "${F_REC[$i]}" ]; then
      case "${F_STATUS[$i]}" in
        gap|missing)
          if [ "$rec_shown" -eq 0 ]; then
            blank
            say "$C_YELLOW" 'What we would do:'
          fi
          rec_shown=$(( rec_shown + 1 ))
          say "" "  ${rec_shown}. ${F_REC[$i]}"
          ;;
      esac
    fi
    i=$(( i + 1 ))
  done

  return 0
}

# =====================================================================
# Crash-safe check dispatch
# =====================================================================
# Each check mutates the global finding arrays through add_finding. To keep a
# coding slip inside one check (an unbound variable under 'set -u', say) from
# aborting the whole scan, the check runs in a subshell. The subshell serialises
# every finding it added; the parent replays them into its own arrays. If the
# subshell dies before it can serialise, the parent survives, sees the non-zero
# exit, and records exactly one internal finding, which is what spec 0 and 2.8
# require and what the fail-closed readiness layer depends on.

# One field per line, newlines and tabs flattened to spaces (real evidence and
# data are single-line; this only guards a future field that is not).
_field_flat() {
  local s="$1"
  s="${s//$'\n'/ }"
  s="${s//$'\t'/ }"
  s="${s//$'\r'/ }"
  printf '%s' "$s"
}

# dump_findings_from <start-index>   (six lines per finding, on stdout)
dump_findings_from() {
  local i="$1"
  while [ "$i" -lt "$F_COUNT" ]; do
    _field_flat "${F_ID[$i]}";       printf '\n'
    _field_flat "${F_CAT[$i]}";      printf '\n'
    _field_flat "${F_STATUS[$i]}";   printf '\n'
    _field_flat "${F_EVIDENCE[$i]}"; printf '\n'
    _field_flat "${F_REC[$i]}";      printf '\n'
    _field_flat "${F_DATA[$i]}";     printf '\n'
    i=$(( i + 1 ))
  done
  return 0
}

# replay_findings <dumpfile>
replay_findings() {
  local id cat status ev rec data
  while IFS= read -r id; do
    IFS= read -r cat    || break
    IFS= read -r status || break
    IFS= read -r ev     || break
    IFS= read -r rec    || break
    IFS= read -r data   || break
    add_finding "$id" "$cat" "$status" "$ev" "$rec" "$data"
  done < "$1"
  return 0
}

# run_check <display> <fn>
run_check() {
  local display="$1" fn="$2" before="$F_COUNT" msg
  local dump errf
  if [ -n "$ASSESS_TMP_DIR" ] && [ -d "$ASSESS_TMP_DIR" ]; then
    dump="${ASSESS_TMP_DIR}/.check.$$.out"
    errf="${ASSESS_TMP_DIR}/.check.$$.err"
    # </dev/null so a check can never consume the dispatch loop's own input.
    if ( "$fn" </dev/null; dump_findings_from "$before" ) >"$dump" 2>"$errf"; then
      replay_findings "$dump"
    else
      msg=$(/usr/bin/tail -n 1 "$errf" 2>/dev/null | /usr/bin/sed 's/^[^:]*: line [0-9]*: //' || true)
      [ -n "$msg" ] || msg="check aborted before it could finish"
      add_finding "${display}.error" 'internal' 'gap' "Check ${display} failed: ${msg}"
    fi
    rm -f "$dump" "$errf" 2>/dev/null
  else
    # No scratch dir (should not happen in a real run): fall back to running the
    # check directly. Still guarded against a non-zero return.
    if ! "$fn" </dev/null; then
      add_finding "${display}.error" 'internal' 'gap' "Check ${display} failed"
    fi
  fi
  return 0
}

# Wall-clock tenths-of-a-second, for the footer only. Timer infrastructure like
# run_timed, not an assessment probe: it feeds no finding, so it is deliberately
# not a probe_ function. GNU date (the Linux dev box) carries nanoseconds; macOS
# BSD date has only whole seconds, so perl (which ships with macOS) supplies the
# fraction; the last resort is whole seconds so the footer still renders.
now_tenths() {
  local t
  t=$(/bin/date +%s%N 2>/dev/null)
  case "$t" in ''|*[!0-9]*) t="" ;; esac
  if [ -n "$t" ] && [ "${#t}" -ge 11 ]; then
    printf '%s' "${t%????????}"
    return 0
  fi
  t=$(/usr/bin/perl -MTime::HiRes -e 'printf "%d", Time::HiRes::time()*10' 2>/dev/null)
  case "$t" in ''|*[!0-9]*) t="" ;; esac
  if [ -n "$t" ]; then printf '%s' "$t"; return 0; fi
  t=$(/bin/date +%s 2>/dev/null)
  case "$t" in ''|*[!0-9]*) t=0 ;; esac
  printf '%s' "$(( t * 10 ))"
  return 0
}

# Remove every transient file this run created. Set as an EXIT/signal trap so a
# Ctrl-C, a closed Terminal, or a mid-scan sleep never leaves a spooled config
# (which can contain live MCP API keys) behind in the report folder.
assess_cleanup() {
  [ -n "${ASSESS_TMP_DIR:-}" ] || return 0
  case "$ASSESS_TMP_DIR" in
    */.tmp.*) rm -rf "$ASSESS_TMP_DIR" 2>/dev/null ;;
    *)
      rm -f "${ASSESS_TMP_DIR}/.rt.$$" \
            "${ASSESS_TMP_DIR}/.nobom.$$" \
            "${ASSESS_TMP_DIR}/.check.$$.out" \
            "${ASSESS_TMP_DIR}/.check.$$.err" 2>/dev/null ;;
  esac
  return 0
}

# =====================================================================
# Runner
# =====================================================================
run_assessment() {
  local platform start_tenths end_tenths elapsed_tenths row display fn

  platform=$(probe_platform)
  if [ "$platform" != "Darwin" ] && [ -z "${ASSESS_FAKE_PLATFORM:-}" ]; then
    printf '\n' >&2
    printf 'This health check is the macOS version and this machine is not a Mac.\n' >&2
    printf 'On Windows, run the PowerShell version instead:\n' >&2
    printf '  irm https://raw.githubusercontent.com/engineai-nz/claude-installer/main/installer/assess.ps1 | iex\n' >&2
    printf '\n' >&2
    exit 1
  fi

  # Owner-only for everything from here on: the report and every transient file
  # (a spooled config can hold live MCP API keys) are created 0600 / 0700.
  umask 077

  if [ "$(probe_mkdir "$OUT_DIR")" != "1" ]; then
    printf 'Could not create the report folder: %s\n' "$OUT_DIR" >&2
    printf 'Pass a writable folder with --out <dir> and try again.\n' >&2
    exit 1
  fi
  # Transient files live in a dedicated per-run subdir, never beside the report,
  # so the cleanup trap can remove the whole thing without touching the report.
  ASSESS_TMP_DIR="${OUT_DIR}/.tmp.$$"
  if [ "$(probe_mkdir "$ASSESS_TMP_DIR")" != "1" ]; then
    ASSESS_TMP_DIR="$OUT_DIR"
  fi
  trap 'assess_cleanup' EXIT
  trap 'assess_cleanup; exit 130' INT TERM HUP

  blank
  sayn "$C_YELLOW" 'Engine AI Claude Health Check'
  say "$C_DARKGRAY" " v${ASSESS_VERSION} (read-only)"
  blank

  start_tenths=$(now_tenths)

  while IFS= read -r row; do
    [ -n "$row" ] || continue
    display="${row%%:*}"
    fn="${row##*:}"
    say "$C_DARKGRAY" "  scanning: ${display}"
    run_check "$display" "$fn"
  done <<EOF
$CHECKS
EOF

  maturity_level
  readiness_verdict
  write_console
  export_json

  end_tenths=$(now_tenths)
  elapsed_tenths=0
  case "${start_tenths}${end_tenths}" in
    *[!0-9]*|'') ;;
    *) [ "$end_tenths" -ge "$start_tenths" ] && elapsed_tenths=$(( end_tenths - start_tenths )) ;;
  esac

  blank
  say "$C_DARKGRAY" "Scan took $(fmt_tenths "$elapsed_tenths")s"
  say "$C_CYAN" "Report: ${REPORT_PATH}"
  blank

  if [ "$JSON_ONLY" -eq 1 ]; then
    probe_file_text "$REPORT_PATH"
  fi

  return 0
}

# Library mode: define everything, run nothing. Used by the test harness.
if [ "${ENGINEAI_ASSESS_LIBONLY:-}" != "1" ]; then
  run_assessment
fi
