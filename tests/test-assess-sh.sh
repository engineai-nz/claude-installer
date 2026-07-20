#!/usr/bin/env bash
# Test harness for installer/assess.sh (Engine AI Claude Health Check, macOS port).
#
# Pure bash. No bats, no jq, no python. Runs on Linux (dev box) and on macOS
# with the stock /bin/bash 3.2.57.
#
# Coverage target: parity with tests/assess.Tests.ps1 (Pester), plus the
# scenario matrix the Windows suite cannot express because assess.ps1 reads
# the live machine.
#
# How it works
#   1. assess.sh is sourced in library mode (ASSESS_SOURCE_ONLY=1, plus the
#      spec-named ENGINEAI_ASSESS_LIBONLY=1) so nothing auto-runs.
#   2. Every platform probe (function named probe_*) is redefined by a stub
#      file sourced after assess.sh, so each scenario is a pure fixture.
#   3. $HOME points at a per-scenario fixture tree, so filesystem-derived state
#      (Desktop config, skills, settings) is fixture-controlled too.
#   4. ASSESS_FAKE_PLATFORM=Darwin lets the whole thing run off a Mac.
#   5. The emitted report is parsed with grep/sed/tr only.
#
# Usage:  bash tests/test-assess-sh.sh
#         KEEP_TMP=1 bash tests/test-assess-sh.sh   (leave fixtures on disk)
#
# Exit code: 0 when every test passed, 1 otherwise.

# Deliberately no `set -e`: a failing assertion must not abort the run.

# ---------------------------------------------------------------------------
# Paths and teardown
# ---------------------------------------------------------------------------

TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$TESTS_DIR/.." && pwd)
ASSESS_SH="$REPO_ROOT/installer/assess.sh"

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/assess-sh-tests.XXXXXX") || exit 1
mkdir -p "$TMPROOT/homes" "$TMPROOT/out" "$TMPROOT/logs" "$TMPROOT/drivers" "$TMPROOT/stubs"

cleanup() {
  if [ "${KEEP_TMP:-0}" = "1" ]; then
    printf '\nFixtures kept at: %s\n' "$TMPROOT"
  else
    rm -rf "$TMPROOT"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT

LIB_HOME="$TMPROOT/homes/_library"
mkdir -p "$LIB_HOME"

# ---------------------------------------------------------------------------
# Assertion library
# ---------------------------------------------------------------------------

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_WARNED=0
FAILED_LIST=""
WARN_LIST=""

section() { printf '\n%s\n' "$1"; }

pass() {
  TESTS_PASSED=$((TESTS_PASSED + 1))
  printf '  [PASS] %s\n' "$1"
}

fail() {
  TESTS_FAILED=$((TESTS_FAILED + 1))
  FAILED_LIST="$FAILED_LIST
  - $1"
  printf '  [FAIL] %s\n' "$1"
  if [ -n "${2:-}" ]; then
    printf '         %s\n' "$2"
  fi
}

warn() {
  TESTS_WARNED=$((TESTS_WARNED + 1))
  WARN_LIST="$WARN_LIST
  - $1"
  printf '  [WARN] %s\n' "$1"
}

# assert_equals <expected> <actual> <name>
assert_equals() {
  if [ "$1" = "$2" ]; then
    pass "$3"
  else
    fail "$3" "expected [$1] but got [$2]"
  fi
}

# assert_contains <haystack> <needle> <name>
assert_contains() {
  if printf '%s' "$1" | grep -Fq -- "$2"; then
    pass "$3"
  else
    fail "$3" "expected output to contain: $2"
  fi
}

# assert_not_contains <haystack> <needle> <name>
assert_not_contains() {
  if printf '%s' "$1" | grep -Fq -- "$2"; then
    fail "$3" "expected output NOT to contain: $2"
  else
    pass "$3"
  fi
}

# assert_exit_code <expected> <actual> <name>
assert_exit_code() {
  if [ "$1" = "$2" ]; then
    pass "$3"
  else
    fail "$3" "expected exit code $1 but got $2"
  fi
}

# assert_json_has_key <file> <key> <name>
assert_json_has_key() {
  if [ ! -f "$1" ]; then
    fail "$3" "no report file at [$1]"
    return 0
  fi
  if grep -q "\"$2\"[[:space:]]*:" "$1"; then
    pass "$3"
  else
    fail "$3" "report has no key \"$2\""
  fi
}

# assert_file_contains <file> <literal> <name>
assert_file_contains() {
  if [ ! -f "$1" ]; then
    fail "$3" "no file at [$1]"
    return 0
  fi
  if grep -Fq -- "$2" "$1"; then
    pass "$3"
  else
    fail "$3" "file does not contain: $2"
  fi
}

# assert_file_matches <file> <ERE> <name>
assert_file_matches() {
  if [ ! -f "$1" ]; then
    fail "$3" "no file at [$1]"
    return 0
  fi
  if grep -Eq -- "$2" "$1"; then
    pass "$3"
  else
    fail "$3" "file does not match: $2"
  fi
}

# assert_file_not_matches <file> <ERE> <name>
assert_file_not_matches() {
  if [ ! -f "$1" ]; then
    fail "$3" "no file at [$1]"
    return 0
  fi
  if grep -Eq -- "$2" "$1"; then
    fail "$3" "file unexpectedly matches: $2"
  else
    pass "$3"
  fi
}

# ---------------------------------------------------------------------------
# JSON readers (grep/sed/tr only, tolerant of pretty and compact output)
# ---------------------------------------------------------------------------

# json_flatten <file> -> one key or value per line
json_flatten() {
  [ -f "$1" ] || return 0
  tr '{}[],' '\n\n\n\n\n' < "$1"
}

# json_scalar <file> <key> -> first scalar value for that key, quotes stripped
json_scalar() {
  [ -f "$1" ] || return 0
  json_flatten "$1" \
    | grep "\"$2\"[[:space:]]*:" \
    | head -1 \
    | sed -e "s/.*\"$2\"[[:space:]]*:[[:space:]]*//" \
          -e 's/[[:space:]]*$//' \
          -e 's/^"//' -e 's/"$//'
}

# json_head <file> -> everything before the findings array (i.e. the readiness block)
json_head() {
  [ -f "$1" ] || return 0
  tr ',' '\n' < "$1" | sed -n '/"findings"[[:space:]]*:/q;p'
}

# json_findings <file> -> the findings array only, one key per line.
# readiness.blockers also carries "id" keys, so every finding lookup has to
# start after the findings key or it reads a blocker by mistake.
json_findings() {
  [ -f "$1" ] || return 0
  tr ',' '\n' < "$1" | sed -n '/"findings"[[:space:]]*:/,$p'
}

# json_finding_status <file> <finding id> -> status string, empty when absent
json_finding_status() {
  [ -f "$1" ] || return 0
  json_findings "$1" \
    | sed -n "/\"id\"[[:space:]]*:[[:space:]]*\"$2\"/,\$p" \
    | grep "\"status\"[[:space:]]*:" \
    | head -1 \
    | sed -e 's/.*"status"[[:space:]]*:[[:space:]]*"//' -e 's/".*//'
}

# json_has_finding <file> <finding id>
json_has_finding() {
  [ -f "$1" ] || return 1
  json_findings "$1" | grep -q "\"id\"[[:space:]]*:[[:space:]]*\"$2\""
}

# json_has_blocker <file> <finding id>
json_has_blocker() {
  [ -f "$1" ] || return 1
  json_head "$1" | grep -q "\"$2\""
}

json_maturity() { json_scalar "$1" maturityLevel; }
json_verdict()  { json_scalar "$1" verdict; }

# json_no_bom <file>
json_no_bom() {
  _bytes=$(head -c 3 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')
  [ "$_bytes" != "efbbbf" ]
}

# assert_report <name> -> fails when the scenario produced no report
assert_report() {
  if [ -n "$SC_JSON" ] && [ -f "$SC_JSON" ]; then
    pass "$1"
  else
    fail "$1" "no report written; stderr tail: $(printf '%s' "$SC_ERR" | tail -3 | tr '\n' ' ')"
  fi
}

# assert_blocker <file> <id> <name>
assert_blocker() {
  if json_has_blocker "$1" "$2"; then
    pass "$3"
  else
    fail "$3" "$2 is not in readiness.blockers"
  fi
}

# assert_not_blocker <file> <id> <name>
assert_not_blocker() {
  if [ ! -f "$1" ]; then
    fail "$3" "no report file, cannot verify blockers"
    return 0
  fi
  if json_has_blocker "$1" "$2"; then
    fail "$3" "$2 was flagged as a blocker but should not be"
  else
    pass "$3"
  fi
}

# ---------------------------------------------------------------------------
# Fixture builders
# ---------------------------------------------------------------------------

new_home() {
  _h="$TMPROOT/homes/$1"
  mkdir -p "$_h"
  printf '%s' "$_h"
}

# home_desktop_config <home> <json body>
home_desktop_config() {
  _d="$1/Library/Application Support/Claude"
  mkdir -p "$_d"
  printf '%s' "$2" > "$_d/claude_desktop_config.json"
  printf '{"allowDevTools":true}' > "$_d/developer_settings.json"
}

# home_claude_code <home>
home_claude_code() {
  mkdir -p "$1/.claude/bin"
  {
    printf '#!/bin/sh\n'
    printf 'echo "1.0.88 (Claude Code)"\n'
  } > "$1/.claude/bin/claude"
  chmod +x "$1/.claude/bin/claude"
  printf '{"model":"sonnet"}' > "$1/.claude/settings.json"
  printf '# CLAUDE.md\n' > "$1/.claude/CLAUDE.md"
  printf '{"mcpServers":{"membase":{"command":"npx"}}}' > "$1/.claude.json"
}

# home_skills <home>
home_skills() {
  mkdir -p "$1/.claude/skills/brand" "$1/.claude/skills/humaniser"
  printf '# brand\n' > "$1/.claude/skills/brand/SKILL.md"
  printf '# humaniser\n' > "$1/.claude/skills/humaniser/SKILL.md"
}

GOOD_CONFIG='{
  "mcpServers": {
    "filesystem": { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "/Users/testuser"] },
    "fetch": { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-fetch"] }
  }
}'

EMPTY_MCP_CONFIG='{
  "mcpServers": {}
}'

MALFORMED_CONFIG='{ "mcpServers": { "filesystem": { "command": "npx"  '

# ---------------------------------------------------------------------------
# Probe stubs
# ---------------------------------------------------------------------------
#
# These match the probe vocabulary of installer/assess.sh: small argument
# driven primitives rather than one probe per finding. Anything that shells
# out to a macOS binary gets stubbed. The generic filesystem probes are left
# real on purpose, because the per-scenario $HOME fixture is what drives them.
# Default fixture: a healthy Apple Silicon Mac on macOS 14 with nothing
# Claude-related installed.

base_stubs() {
  cat <<'STUBS'
# --- platform identity -----------------------------------------------------
probe_platform() { printf 'Darwin\n'; return 0; }
probe_arch()     { printf 'arm64\n'; return 0; }

probe_sw_vers() {
  case "$1" in
    productName)    printf 'macOS\n' ;;
    productVersion) printf '14.4\n' ;;
    buildVersion)   printf '23E214\n' ;;
  esac
  return 0
}

probe_sysctl() {
  case "$1" in
    hw.memsize)               printf '17179869184\n' ;;
    machdep.cpu.brand_string) printf 'Apple M2 Pro\n' ;;
    hw.physicalcpu|hw.ncpu)   printf '10\n' ;;
    hw.optional.arm64)        printf '1\n' ;;
    sysctl.proc_translated)   printf '0\n' ;;
  esac
  return 0
}

probe_df_free_kb()   { printf '262144000\n'; return 0; }
probe_hostname()     { printf 'test-mac'; return 0; }
probe_current_user() { printf 'testuser\n'; return 0; }
probe_bash_version() { printf '3.2.57(1)-release'; return 0; }

# --- clock (fixed offsets keep patch state and uptime deterministic) --------
probe_now_epoch()     { /bin/date +%s 2>/dev/null || date +%s; return 0; }
probe_file_mtime_epoch() {
  _stub_n=$(probe_now_epoch)
  printf '%s' "$(( _stub_n - 864000 ))"
  return 0
}
probe_epoch_to_date() { printf '2026-07-01'; return 0; }
probe_boot_epoch() {
  _stub_n=$(probe_now_epoch)
  printf '%s' "$(( _stub_n - 172800 ))"
  return 0
}

# --- privilege (admin group member, not root: the can-elevate case) ---------
probe_uid()                { printf '501'; return 0; }
probe_group_names()        { printf 'staff everyone localaccounts admin\n'; return 0; }
probe_dscl_admin_members() { printf 'root testuser\n'; return 0; }
probe_dseditgroup_admin()  { printf 'yes\n'; return 0; }
probe_ad_domains()         { return 0; }

# --- management (unmanaged personal Mac) -----------------------------------
probe_mdm_enrollment()      { printf 'Enrolled via DEP: No\nMDM enrollment: No\n'; return 0; }
probe_mdm_vendor_names()    { return 0; }
probe_managed_prefs_names() { return 0; }

# --- endpoint security and gatekeeper --------------------------------------
probe_gatekeeper()              { printf 'assessments enabled\n'; return 0; }
probe_security_product_names()  { return 0; }
probe_security_process_names()  { return 0; }

# --- command resolution (nothing installed by default) ---------------------
probe_command_path() {
  case "$1" in
    brew) printf '/opt/homebrew/bin/brew\n' ;;
  esac
  return 0
}

probe_first_line_of() {
  shift
  case "$1" in
    *claude) printf '1.0.88 (Claude Code)\n' ;;
    *node)   printf 'v22.3.0\n' ;;
    *npx)    printf '10.8.2\n' ;;
  esac
  return 0
}

# --- filesystem probes: real, so the HOME fixture drives them, except for
# --- absolute system paths that would otherwise leak the real machine in.
probe_dir_exists() {
  case "$1" in
    /Applications/Claude.app) printf '0'; return 0 ;;
  esac
  if [ -d "$1" ]; then printf '1'; else printf '0'; fi
  return 0
}

probe_path_exists() {
  case "$1" in
    /var/db/.SoftwareUpdateAtLogout) printf '0'; return 0 ;;
  esac
  if [ -e "$1" ]; then printf '1'; else printf '0'; fi
  return 0
}

probe_is_exec() {
  case "$1" in
    /opt/homebrew/bin/claude|/usr/local/bin/claude) printf '0'; return 0 ;;
    /opt/homebrew/bin/brew|/usr/local/bin/brew)     printf '1'; return 0 ;;
  esac
  if [ -x "$1" ]; then printf '1'; else printf '0'; fi
  return 0
}

# BSD stat flags do not exist on Linux, so size comes from wc here.
probe_file_size() {
  _stub_s=$(wc -c < "$1" 2>/dev/null | tr -d ' \n')
  case "$_stub_s" in ''|*[!0-9]*) _stub_s=0 ;; esac
  printf '%s' "$_stub_s"
  return 0
}

# --- running processes and mounts ------------------------------------------
probe_process_names()        { printf 'launchd\nWindowServer\nFinder\n'; return 0; }
probe_claude_process_count() { printf '0'; return 0; }
probe_mount_table()          { printf '/dev/disk3s1s1 on / (apfs, sealed, local, read-only, journaled)\n'; return 0; }
probe_apps_names()           { printf 'Mail\nPreview\nSafari\nTerminal\n'; return 0; }
probe_default_browser()      { printf 'com.apple.safari\n'; return 0; }

# --- plist and JSON parsing -------------------------------------------------
# plutil does not exist off macOS. Report it available and lint with a brace
# balance heuristic, which is enough to separate the good fixtures from the
# malformed one. Extraction returns nothing on purpose so read_mcp_servers
# exercises the pure shell scanner, which is the code path that has to work
# on a Mac where plutil chokes on a JSON5 style config.
probe_plutil_available() { printf '1'; return 0; }

probe_plutil_lint() {
  _stub_o=$(tr -cd '{' < "$1" 2>/dev/null | wc -c | tr -d ' \n')
  _stub_c=$(tr -cd '}' < "$1" 2>/dev/null | wc -c | tr -d ' \n')
  case "$_stub_o" in ''|*[!0-9]*) _stub_o=0 ;; esac
  case "$_stub_c" in ''|*[!0-9]*) _stub_c=0 ;; esac
  if [ "$_stub_o" -gt 0 ] && [ "$_stub_o" -eq "$_stub_c" ]; then printf '1'; else printf '0'; fi
  return 0
}

probe_plutil_lint_error() { printf 'Unexpected character at line 1\n'; return 0; }
probe_plutil_extract_json() { return 0; }
probe_plutil_extract_raw() {
  case "$1" in
    CFBundleShortVersionString) printf '0.14.3\n' ;;
  esac
  return 0
}
STUBS
}

# new_stubs <name> -> writes the base stub file, echoes its path
new_stubs() {
  _s="$TMPROOT/stubs/$1.sh"
  base_stubs > "$_s"
  printf '%s' "$_s"
}

# ---------------------------------------------------------------------------
# Scenario runner
# ---------------------------------------------------------------------------

ENTRYPOINT=""
OUT_FLAG_HONOURED=1
SC_RC=0
SC_OUT=""
SC_ERR=""
SC_JSON=""

# run_scenario <name> <home> <stubfile> [args to assess.sh...]
run_scenario() {
  _name=$1; _home=$2; _stubs=$3
  shift 3
  _outdir="$TMPROOT/out/$_name"
  mkdir -p "$_outdir"
  _driver="$TMPROOT/drivers/$_name.sh"
  _outf="$TMPROOT/logs/$_name.out"
  _errf="$TMPROOT/logs/$_name.err"

  {
    printf '#!/usr/bin/env bash\n'
    printf 'export ASSESS_SOURCE_ONLY=1\n'
    printf 'export ENGINEAI_ASSESS_LIBONLY=1\n'
    printf 'export ASSESS_FAKE_PLATFORM=Darwin\n'
    printf 'export NO_COLOR=1\n'
    printf 'export HOME="%s"\n' "$_home"
    printf '. "%s" || exit 90\n' "$ASSESS_SH"
    printf '. "%s" || exit 91\n' "$_stubs"
    printf 'unset ASSESS_SOURCE_ONLY\n'
    printf 'unset ENGINEAI_ASSESS_LIBONLY\n'
    printf '%s "$@"\n' "$ENTRYPOINT"
  } > "$_driver"

  bash "$_driver" "$@" > "$_outf" 2> "$_errf"
  SC_RC=$?
  SC_OUT=$(cat "$_outf" 2>/dev/null)
  SC_ERR=$(cat "$_errf" 2>/dev/null)

  SC_JSON=$(ls -1t "$_outdir"/*.json 2>/dev/null | head -1)
  if [ -z "$SC_JSON" ]; then
    SC_JSON=$(ls -1t "$_home"/.engineai-installer/assess/*.json 2>/dev/null | head -1)
    if [ -n "$SC_JSON" ]; then
      OUT_FLAG_HONOURED=0
    fi
  fi
}

# sourced_eval <bash code> -> runs code with assess.sh sourced in library mode
SOURCED_N=0
sourced_eval() {
  SOURCED_N=$((SOURCED_N + 1))
  _s="$TMPROOT/drivers/sourced-$SOURCED_N.sh"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'export ASSESS_SOURCE_ONLY=1\n'
    printf 'export ENGINEAI_ASSESS_LIBONLY=1\n'
    printf 'export ASSESS_FAKE_PLATFORM=Darwin\n'
    printf 'export NO_COLOR=1\n'
    printf 'export HOME="%s"\n' "$LIB_HOME"
    printf '. "%s" >/dev/null 2>&1 || exit 90\n' "$ASSESS_SH"
    printf '%s\n' "$1"
  } > "$_s"
  SE_OUT=$(bash "$_s" 2>"$TMPROOT/logs/sourced-$SOURCED_N.err")
  SE_RC=$?
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

printf 'Engine AI assess.sh test harness\n'
printf 'script under test: %s\n' "$ASSESS_SH"

section 'Preflight'

if [ ! -f "$ASSESS_SH" ]; then
  fail 'installer/assess.sh exists' "not found at $ASSESS_SH, nothing to test"
  printf '\nPassed: %d Failed: %d\n' "$TESTS_PASSED" "$TESTS_FAILED"
  exit 1
fi
pass 'installer/assess.sh exists'

if bash -n "$ASSESS_SH" 2>"$TMPROOT/logs/syntax.err"; then
  pass 'assess.sh parses (bash -n)'
else
  fail 'assess.sh parses (bash -n)' "$(head -3 "$TMPROOT/logs/syntax.err" | tr '\n' ' ')"
  printf '\nSyntax errors block every other test.\n'
  printf '\nPassed: %d Failed: %d\n' "$TESTS_PASSED" "$TESTS_FAILED"
  exit 1
fi

# ---------------------------------------------------------------------------
# Static contract
# ---------------------------------------------------------------------------

section 'Static contract'

# No em dashes anywhere: CP1252 consoles mangle them (project rule).
if grep -q $'\xe2\x80\x94' "$ASSESS_SH"; then
  fail 'no em dashes in assess.sh' \
    "line(s): $(grep -n $'\xe2\x80\x94' "$ASSESS_SH" | cut -d: -f1 | tr '\n' ' ')"
else
  pass 'no em dashes in assess.sh'
fi

# bash 3.2.57 compatibility: constructs that only exist in bash 4+.
BAD32=""
CODE_ONLY="$TMPROOT/logs/assess-code-only.sh"
sed 's/#.*$//' "$ASSESS_SH" > "$CODE_ONLY"
grep -q 'declare -A' "$CODE_ONLY" && BAD32="$BAD32 declare-A"
grep -q 'local -A' "$CODE_ONLY" && BAD32="$BAD32 local-A"
grep -qE '(^|[^[:alnum:]_])mapfile([^[:alnum:]_]|$)' "$CODE_ONLY" && BAD32="$BAD32 mapfile"
grep -qE '(^|[^[:alnum:]_])readarray([^[:alnum:]_]|$)' "$CODE_ONLY" && BAD32="$BAD32 readarray"
grep -qE '\$\{[A-Za-z_][A-Za-z0-9_]*,,' "$CODE_ONLY" && BAD32="$BAD32 lowercase-expansion"
grep -qE '\$\{[A-Za-z_][A-Za-z0-9_]*\^\^' "$CODE_ONLY" && BAD32="$BAD32 uppercase-expansion"
grep -qE '(declare|local) -n ' "$CODE_ONLY" && BAD32="$BAD32 nameref"
if [ -z "$BAD32" ]; then
  pass 'no bash 4+ only constructs (bash 3.2.57 compatible)'
else
  fail 'no bash 4+ only constructs (bash 3.2.57 compatible)' "found:$BAD32"
fi

# ASSESS_FAKE_PLATFORM hook.
if grep -q 'ASSESS_FAKE_PLATFORM' "$ASSESS_SH"; then
  pass 'assess.sh references ASSESS_FAKE_PLATFORM'
else
  fail 'assess.sh references ASSESS_FAKE_PLATFORM' \
    'env var never referenced; the suite cannot run off Darwin'
fi

# Sourcing guard.
if grep -q 'ASSESS_SOURCE_ONLY' "$ASSESS_SH" || grep -q 'ENGINEAI_ASSESS_LIBONLY' "$ASSESS_SH"; then
  pass 'assess.sh has a source-only guard'
else
  fail 'assess.sh has a source-only guard' \
    'REQUIRED CHANGE: end the file with [ "${ASSESS_SOURCE_ONLY:-}" = "1" ] || [ "${ENGINEAI_ASSESS_LIBONLY:-}" = "1" ] || main "$@"'
fi

# CLI flags.
if grep -q -- '--json-only' "$ASSESS_SH"; then
  pass 'assess.sh accepts --json-only'
else
  fail 'assess.sh accepts --json-only' 'flag not referenced anywhere in the script'
fi
if grep -q -- '--out' "$ASSESS_SH"; then
  pass 'assess.sh accepts --out'
else
  fail 'assess.sh accepts --out' 'flag not referenced anywhere in the script'
fi

# ---------------------------------------------------------------------------
# Library mode
# ---------------------------------------------------------------------------

section 'Library mode'

{
  printf '#!/usr/bin/env bash\n'
  printf 'export ASSESS_SOURCE_ONLY=1\n'
  printf 'export ENGINEAI_ASSESS_LIBONLY=1\n'
  printf 'export ASSESS_FAKE_PLATFORM=Darwin\n'
  printf 'export NO_COLOR=1\n'
  printf 'export HOME="%s"\n' "$LIB_HOME"
  printf '. "%s"\n' "$ASSESS_SH"
  printf 'printf "SOURCED_OK\\n"\n'
} > "$TMPROOT/drivers/guard.sh"
GUARD_OUT=$(bash "$TMPROOT/drivers/guard.sh" 2>&1)

assert_contains "$GUARD_OUT" 'SOURCED_OK' 'sourcing assess.sh in library mode succeeds'
assert_not_contains "$GUARD_OUT" 'Claude Health Check' 'sourcing does not print the banner (guard honoured)'
if ls "$LIB_HOME"/.engineai-installer/assess/*.json >/dev/null 2>&1; then
  fail 'sourcing does not write a report' 'a report landed in the fixture HOME during a plain source'
  rm -f "$LIB_HOME"/.engineai-installer/assess/*.json
else
  pass 'sourcing does not write a report'
fi

# Authoritative function inventory from the sourced namespace.
FUNCS=$(bash -c '
  ASSESS_SOURCE_ONLY=1; ENGINEAI_ASSESS_LIBONLY=1; ASSESS_FAKE_PLATFORM=Darwin
  HOME="'"$LIB_HOME"'"; NO_COLOR=1
  export ASSESS_SOURCE_ONLY ENGINEAI_ASSESS_LIBONLY ASSESS_FAKE_PLATFORM HOME NO_COLOR
  . "'"$ASSESS_SH"'" >/dev/null 2>&1
  declare -F | sed "s/^declare -f //"' 2>/dev/null)

has_func() { printf '%s\n' "$FUNCS" | grep -qx "$1"; }

# Probe isolation.
PROBES_IN_FILE=$(printf '%s\n' "$FUNCS" | grep '^probe_' | sort -u)
PROBE_COUNT=0
if [ -n "$PROBES_IN_FILE" ]; then
  PROBE_COUNT=$(printf '%s\n' "$PROBES_IN_FILE" | grep -c '^probe_')
fi
if [ "$PROBE_COUNT" -ge 10 ]; then
  pass "platform probes isolated in probe_* functions ($PROBE_COUNT found)"
else
  fail 'platform probes isolated in probe_* functions' \
    "only $PROBE_COUNT probe_* functions defined; the harness cannot fixture what it cannot stub"
fi

# Probes the harness does not know how to stub. Informational, not a failure.
# Generic filesystem, text and output probes are left real on purpose: the
# per-scenario HOME fixture drives them, and stubbing them would test the stub.
LEFT_REAL='probe_file_exists probe_file_head_hex3 probe_file_text probe_is_symlink
probe_list_names probe_list_subdir_names probe_mkdir probe_now_iso probe_now_stamp
probe_readlink probe_write_file'
STUBBED=$(
  { base_stubs | grep -oE '^probe_[A-Za-z0-9_]+'
    printf '%s\n' $LEFT_REAL
  } | sort -u
)
if [ -n "$PROBES_IN_FILE" ]; then
  UNSTUBBED=$(printf '%s\n' "$PROBES_IN_FILE" | while IFS= read -r p; do
    [ -z "$p" ] && continue
    printf '%s\n' "$STUBBED" | grep -qx "$p" || printf '%s\n' "$p"
  done)
  if [ -n "$UNSTUBBED" ]; then
    warn "probe_* functions with no harness stub: $(printf '%s' "$UNSTUBBED" | tr '\n' ' ')"
  else
    pass 'every probe_* function in assess.sh has a harness stub'
  fi
fi

# Entrypoint.
for cand in main assess_main run_assessment invoke_assessment assess_run; do
  if has_func "$cand"; then ENTRYPOINT=$cand; break; fi
done
if [ -n "$ENTRYPOINT" ]; then
  pass "entrypoint function resolved ($ENTRYPOINT)"
else
  fail 'entrypoint function resolved' \
    'none of main / assess_main / run_assessment / invoke_assessment / assess_run is defined'
fi

# JSON escape helper.
ESCAPE_FN=""
for cand in json_escape escape_json json_string_escape json_str; do
  if has_func "$cand"; then ESCAPE_FN=$cand; break; fi
done
if [ -n "$ESCAPE_FN" ]; then
  pass "json escape helper resolved ($ESCAPE_FN)"
else
  warn 'no json_escape / escape_json helper found; escaping is only covered end to end'
fi

# Finding factory.
FINDING_FN=""
for cand in new_finding add_finding emit_finding; do
  if has_func "$cand"; then FINDING_FN=$cand; break; fi
done
if [ -n "$FINDING_FN" ]; then
  pass "finding factory resolved ($FINDING_FN)"
else
  warn 'no new_finding / add_finding helper found'
fi

# json_escape unit tests.
if [ -n "$ESCAPE_FN" ]; then
  sourced_eval "$ESCAPE_FN 'a\"b\\c'"
  assert_equals 'a\"b\\c' "$SE_OUT" 'json escape handles a double quote and a backslash'
  sourced_eval "$ESCAPE_FN '/Users/o\"brien/My \"Docs\"'"
  assert_equals '/Users/o\"brien/My \"Docs\"' "$SE_OUT" 'json escape handles a path with embedded quotes'
fi

if [ -z "$ENTRYPOINT" ]; then
  section 'Summary'
  printf 'Scenario tests skipped: no entrypoint to call.\n'
  printf '\nPassed: %d Failed: %d\n' "$TESTS_PASSED" "$TESTS_FAILED"
  exit 1
fi

# ---------------------------------------------------------------------------
# Scenario 1a: clean machine, healthy hardware
# ---------------------------------------------------------------------------

section 'Scenario: clean machine (nothing installed, healthy hardware)'

H=$(new_home clean)
S=$(new_stubs clean)
run_scenario clean "$H" "$S" --json-only --out "$TMPROOT/out/clean"

assert_exit_code 0 "$SC_RC" 'clean machine scan completes without error'
assert_report 'clean machine scan writes a report'
assert_equals '0' "$(json_maturity "$SC_JSON")" 'clean machine is maturity Level 0 (web only)'
assert_equals 'missing' "$(json_finding_status "$SC_JSON" 'desktop.installed')" 'clean machine reports desktop.installed missing'
assert_equals 'missing' "$(json_finding_status "$SC_JSON" 'code.installed')" 'clean machine reports code.installed missing'
assert_equals 'missing' "$(json_finding_status "$SC_JSON" 'mcp.node')" 'clean machine reports mcp.node missing'
assert_equals 'gap' "$(json_finding_status "$SC_JSON" 'mcp.filesystem')" 'clean machine reports mcp.filesystem gap'
# Spec section 5: readiness measures INSTALL readiness, not Claude maturity.
# A clean but healthy Mac has no hard stops, so it is ready to be installed on.
assert_equals 'ready' "$(json_verdict "$SC_JSON")" 'clean but healthy machine is install-ready (spec 5: readiness is not maturity)'
assert_not_contains "$SC_ERR" 'command not found' 'clean machine scan produces no shell errors'
assert_not_contains "$SC_ERR" 'unbound variable' 'clean machine scan has no unset variable errors'

# ---------------------------------------------------------------------------
# Scenario 1b: clean machine that is genuinely not installable
# ---------------------------------------------------------------------------

section 'Scenario: clean machine, unsupported macOS, no admin (NOT READY)'

H=$(new_home clean-blocked)
S=$(new_stubs clean-blocked)
cat >> "$S" <<'STUBS'
probe_sw_vers() {
  case "$1" in
    productName)    printf 'macOS\n' ;;
    productVersion) printf '12.7\n' ;;
    buildVersion)   printf '21G1974\n' ;;
  esac
  return 0
}
probe_uid()                { printf '501'; return 0; }
probe_group_names()        { printf 'staff everyone\n'; return 0; }
probe_dscl_admin_members() { printf 'root someoneelse\n'; return 0; }
probe_dseditgroup_admin()  { printf 'no\n'; return 0; }
STUBS
run_scenario clean-blocked "$H" "$S" --json-only --out "$TMPROOT/out/clean-blocked"

assert_exit_code 0 "$SC_RC" 'blocked clean machine scan completes without error'
assert_report 'blocked clean machine writes a report'
assert_equals '0' "$(json_maturity "$SC_JSON")" 'blocked clean machine is maturity Level 0'
assert_equals 'not-ready' "$(json_verdict "$SC_JSON")" 'unsupported OS plus no admin gives NOT READY'
assert_blocker "$SC_JSON" 'machine.osSupport' 'machine.osSupport is listed as a blocker'
assert_blocker "$SC_JSON" 'machine.admin' 'machine.admin is listed as a blocker'

# ---------------------------------------------------------------------------
# Scenario 2: fully configured
# ---------------------------------------------------------------------------

section 'Scenario: fully configured (Desktop, MCPs, Code, skills, Node)'

H=$(new_home full)
home_desktop_config "$H" "$GOOD_CONFIG"
home_claude_code "$H"
home_skills "$H"
S=$(new_stubs full)
cat >> "$S" <<'STUBS'
probe_dir_exists() {
  case "$1" in
    /Applications/Claude.app) printf '1'; return 0 ;;
  esac
  if [ -d "$1" ]; then printf '1'; else printf '0'; fi
  return 0
}
probe_command_path() {
  case "$1" in
    brew)   printf '/opt/homebrew/bin/brew\n' ;;
    node)   printf '/usr/local/bin/node\n' ;;
    npx)    printf '/usr/local/bin/npx\n' ;;
    claude) printf '/usr/local/bin/claude\n' ;;
  esac
  return 0
}
probe_claude_process_count() { printf '1'; return 0; }
probe_apps_names()  { printf 'Claude\nMicrosoft Teams\nMicrosoft Word\nNotion\nSafari\nSlack\nZoom\n'; return 0; }
probe_process_names() { printf 'Claude\nFinder\nNotion\nSlack\n'; return 0; }
STUBS
run_scenario full "$H" "$S" --json-only --out "$TMPROOT/out/full"

assert_exit_code 0 "$SC_RC" 'fully configured scan completes without error'
assert_report 'fully configured scan writes a report'
assert_equals '4' "$(json_maturity "$SC_JSON")" 'fully configured machine is maturity Level 4 (orchestrated)'
assert_equals 'ready' "$(json_verdict "$SC_JSON")" 'fully configured machine is READY'
assert_equals 'ok' "$(json_finding_status "$SC_JSON" 'desktop.installed')" 'desktop.installed is ok'
assert_equals 'ok' "$(json_finding_status "$SC_JSON" 'desktop.config')" 'desktop.config is ok'
assert_equals 'ok' "$(json_finding_status "$SC_JSON" 'desktop.mcpServers')" 'desktop.mcpServers is ok'
assert_equals 'ok' "$(json_finding_status "$SC_JSON" 'mcp.node')" 'mcp.node is ok'
assert_equals 'ok' "$(json_finding_status "$SC_JSON" 'mcp.filesystem')" 'mcp.filesystem is ok'
assert_equals 'ok' "$(json_finding_status "$SC_JSON" 'code.installed')" 'code.installed is ok'
assert_equals 'ok' "$(json_finding_status "$SC_JSON" 'code.skills')" 'code.skills is ok'
assert_file_contains "$SC_JSON" 'mcp.server.filesystem' 'a per-server finding is emitted for the filesystem MCP'

# ---------------------------------------------------------------------------
# Scenario 3: partial
# ---------------------------------------------------------------------------

section 'Scenario: partial (Desktop installed, zero MCP servers)'

H=$(new_home partial)
home_desktop_config "$H" "$EMPTY_MCP_CONFIG"
S=$(new_stubs partial)
cat >> "$S" <<'STUBS'
probe_dir_exists() {
  case "$1" in
    /Applications/Claude.app) printf '1'; return 0 ;;
  esac
  if [ -d "$1" ]; then printf '1'; else printf '0'; fi
  return 0
}
probe_command_path() {
  case "$1" in
    brew) printf '/opt/homebrew/bin/brew\n' ;;
    node) printf '/usr/local/bin/node\n' ;;
    npx)  printf '/usr/local/bin/npx\n' ;;
  esac
  return 0
}
STUBS
run_scenario partial "$H" "$S" --json-only --out "$TMPROOT/out/partial"

assert_exit_code 0 "$SC_RC" 'partial scan completes without error'
assert_report 'partial scan writes a report'
assert_equals '1' "$(json_maturity "$SC_JSON")" 'Desktop with zero MCPs is maturity Level 1'
assert_equals 'ok' "$(json_finding_status "$SC_JSON" 'desktop.installed')" 'partial machine reports desktop.installed ok'
assert_equals 'gap' "$(json_finding_status "$SC_JSON" 'desktop.mcpServers')" 'partial machine reports desktop.mcpServers gap'
assert_equals 'gap' "$(json_finding_status "$SC_JSON" 'mcp.filesystem')" 'partial machine reports mcp.filesystem gap'
assert_file_contains "$SC_JSON" 'Install the Engine AI MCP bundle' 'partial machine recommends the MCP bundle'

# ---------------------------------------------------------------------------
# Scenario 4: low resources
# ---------------------------------------------------------------------------

section 'Scenario: low resources (4 GB RAM, 3 GB free disk)'

H=$(new_home lowres)
S=$(new_stubs lowres)
cat >> "$S" <<'STUBS'
probe_sysctl() {
  case "$1" in
    hw.memsize)               printf '4294967296\n' ;;
    machdep.cpu.brand_string) printf 'Intel(R) Core(TM) i5-8210Y CPU @ 1.60GHz\n' ;;
    hw.physicalcpu|hw.ncpu)   printf '2\n' ;;
    hw.optional.arm64)        printf '0\n' ;;
    sysctl.proc_translated)   printf '0\n' ;;
  esac
  return 0
}
probe_arch()       { printf 'x86_64\n'; return 0; }
probe_df_free_kb() { printf '3145728\n'; return 0; }
STUBS
run_scenario lowres "$H" "$S" --json-only --out "$TMPROOT/out/lowres"

assert_exit_code 0 "$SC_RC" 'low resource scan completes without error'
assert_report 'low resource scan writes a report'
assert_equals 'gap' "$(json_finding_status "$SC_JSON" 'machine.ram')" 'low RAM surfaces machine.ram as a gap'
assert_equals 'gap' "$(json_finding_status "$SC_JSON" 'machine.disk')" 'low disk surfaces machine.disk as a gap'
assert_equals 'ready-with-friction' "$(json_verdict "$SC_JSON")" 'low resources give READY WITH FRICTION, not NOT READY'
assert_blocker "$SC_JSON" 'machine.ram' 'machine.ram appears in the blockers list'
assert_blocker "$SC_JSON" 'machine.disk' 'machine.disk appears in the blockers list'
assert_file_contains "$SC_JSON" 'GB RAM' 'RAM evidence uses the GB RAM template'
assert_file_contains "$SC_JSON" 'GB free on the startup disk' 'disk evidence names the startup disk'

# ---------------------------------------------------------------------------
# Scenario 5: admin rights (macOS analogue of the UAC filtered token lesson)
# ---------------------------------------------------------------------------

section 'Scenario: not admin and cannot elevate'

H=$(new_home noadmin)
S=$(new_stubs noadmin)
cat >> "$S" <<'STUBS'
probe_uid()                { printf '501'; return 0; }
probe_group_names()        { printf 'staff everyone _lpoperator\n'; return 0; }
probe_dscl_admin_members() { printf 'root someoneelse\n'; return 0; }
probe_dseditgroup_admin()  { printf 'no\n'; return 0; }
STUBS
run_scenario noadmin "$H" "$S" --json-only --out "$TMPROOT/out/noadmin"

assert_exit_code 0 "$SC_RC" 'non-admin scan completes without error'
assert_report 'non-admin scan writes a report'
assert_equals 'missing' "$(json_finding_status "$SC_JSON" 'machine.admin')" 'a standard user reports machine.admin missing'
assert_equals 'not-ready' "$(json_verdict "$SC_JSON")" 'a standard user is NOT READY'
assert_blocker "$SC_JSON" 'machine.admin' 'machine.admin is a blocker for a standard user'

section 'Scenario: admin group member, not currently root (can elevate)'

H=$(new_home canelevate)
S=$(new_stubs canelevate)
cat >> "$S" <<'STUBS'
probe_uid()                { printf '501'; return 0; }
probe_group_names()        { printf 'staff everyone localaccounts admin _appserveradm\n'; return 0; }
probe_dscl_admin_members() { printf 'root testuser\n'; return 0; }
probe_dseditgroup_admin()  { printf 'yes\n'; return 0; }
STUBS
run_scenario canelevate "$H" "$S" --json-only --out "$TMPROOT/out/canelevate"

assert_exit_code 0 "$SC_RC" 'can-elevate scan completes without error'
assert_report 'can-elevate scan writes a report'
assert_equals 'ok' "$(json_finding_status "$SC_JSON" 'machine.admin')" 'admin group member unelevated is machine.admin ok'
assert_not_blocker "$SC_JSON" 'machine.admin' \
  'admin group member unelevated is NOT flagged as a blocker (UAC filtered token lesson, macOS analogue)'
assert_equals 'ready' "$(json_verdict "$SC_JSON")" 'admin group member unelevated is READY'

# ---------------------------------------------------------------------------
# Scenario 6: MDM enrolment
# ---------------------------------------------------------------------------

section 'Scenario: MDM enrolled'

H=$(new_home mdm)
S=$(new_stubs mdm)
cat >> "$S" <<'STUBS'
probe_mdm_enrollment() {
  printf 'Enrolled via DEP: Yes\nMDM enrollment: Yes (User Approved)\n'
  return 0
}
probe_mdm_vendor_names()    { printf 'JAMF\n'; return 0; }
probe_managed_prefs_names() { printf 'com.apple.SoftwareUpdate.plist\n'; return 0; }
STUBS
run_scenario mdm "$H" "$S" --json-only --out "$TMPROOT/out/mdm"

assert_exit_code 0 "$SC_RC" 'MDM scan completes without error'
assert_report 'MDM scan writes a report'
assert_equals 'missing' "$(json_finding_status "$SC_JSON" 'machine.mdm')" 'an MDM enrolled Mac reports machine.mdm missing'
assert_equals 'not-ready' "$(json_verdict "$SC_JSON")" 'an MDM enrolled Mac is NOT READY'
assert_blocker "$SC_JSON" 'machine.mdm' 'machine.mdm is a blocker when enrolled'

section 'Scenario: unmanaged Mac carrying a personal configuration profile'

H=$(new_home unmanaged)
S=$(new_stubs unmanaged)
cat >> "$S" <<'STUBS'
probe_mdm_enrollment() {
  printf 'Enrolled via DEP: No\nMDM enrollment: No\n'
  return 0
}
probe_mdm_vendor_names() { return 0; }
# A personal Wi-Fi or beta configuration profile is NOT MDM.
probe_managed_prefs_names() { printf 'com.apple.wifi.personal.plist\n'; return 0; }
STUBS
run_scenario unmanaged "$H" "$S" --json-only --out "$TMPROOT/out/unmanaged"

assert_exit_code 0 "$SC_RC" 'unmanaged scan completes without error'
assert_report 'unmanaged scan writes a report'
assert_equals 'ok' "$(json_finding_status "$SC_JSON" 'machine.mdm')" 'an unmanaged Mac reports machine.mdm ok'
assert_not_blocker "$SC_JSON" 'machine.mdm' 'a personal configuration profile is not falsely flagged as MDM'
assert_equals 'ready' "$(json_verdict "$SC_JSON")" 'an unmanaged healthy Mac is READY'

# ---------------------------------------------------------------------------
# Scenario 7: malformed claude_desktop_config.json
# ---------------------------------------------------------------------------

section 'Scenario: malformed claude_desktop_config.json'

H=$(new_home malformed)
home_desktop_config "$H" "$MALFORMED_CONFIG"
S=$(new_stubs malformed)
cat >> "$S" <<'STUBS'
probe_dir_exists() {
  case "$1" in
    /Applications/Claude.app) printf '1'; return 0 ;;
  esac
  if [ -d "$1" ]; then printf '1'; else printf '0'; fi
  return 0
}
probe_command_path() {
  case "$1" in
    brew) printf '/opt/homebrew/bin/brew\n' ;;
    node) printf '/usr/local/bin/node\n' ;;
    npx)  printf '/usr/local/bin/npx\n' ;;
  esac
  return 0
}
STUBS
run_scenario malformed "$H" "$S" --json-only --out "$TMPROOT/out/malformed"

assert_exit_code 0 "$SC_RC" 'malformed config does not crash the scan'
assert_report 'malformed config still produces a report'
assert_equals 'gap' "$(json_finding_status "$SC_JSON" 'desktop.config')" 'malformed config yields desktop.config gap'
assert_file_contains "$SC_JSON" 'Config invalid JSON' 'malformed config evidence says the JSON is invalid'
assert_equals '1' "$(json_maturity "$SC_JSON")" 'malformed config caps maturity at Level 1 (no readable MCP count)'
assert_not_contains "$SC_ERR" 'syntax error' 'malformed config produces no shell syntax noise'

# ---------------------------------------------------------------------------
# Scenario 8: a probe exits nonzero
# ---------------------------------------------------------------------------

section 'Scenario: a probe exits nonzero'

H=$(new_home probefail)
S=$(new_stubs probefail)
cat >> "$S" <<'STUBS'
probe_sw_vers() {
  printf 'sw_vers: command not found\n' >&2
  return 127
}
STUBS
run_scenario probefail "$H" "$S" --json-only --out "$TMPROOT/out/probefail"

assert_exit_code 0 "$SC_RC" 'a failing probe does not abort the run'
assert_report 'a failing probe still produces a report'
assert_file_contains "$SC_JSON" 'machine.osSupport' \
  'a failing probe still surfaces its finding id (as a finding or a fail-closed blocker)'
assert_equals 'not-ready' "$(json_verdict "$SC_JSON")" 'a failing OS probe is fail-closed to NOT READY (spec 5)'
assert_file_contains "$SC_JSON" '"schemaVersion"' 'the report is still structurally complete after a probe failure'
assert_file_contains "$SC_JSON" '"findings"' 'the findings array survives a probe failure'

# ---------------------------------------------------------------------------
# JSON output contract
# ---------------------------------------------------------------------------

section 'JSON output contract'

H=$(new_home jsonshape)
home_desktop_config "$H" "$GOOD_CONFIG"
home_claude_code "$H"
home_skills "$H"
S=$(new_stubs jsonshape)
cat >> "$S" <<'STUBS'
probe_dir_exists() {
  case "$1" in
    /Applications/Claude.app) printf '1'; return 0 ;;
  esac
  if [ -d "$1" ]; then printf '1'; else printf '0'; fi
  return 0
}
probe_command_path() {
  case "$1" in
    brew)   printf '/opt/homebrew/bin/brew\n' ;;
    node)   printf '/usr/local/bin/node\n' ;;
    npx)    printf '/usr/local/bin/npx\n' ;;
    claude) printf '/usr/local/bin/claude\n' ;;
  esac
  return 0
}
# Nasty values: a double quote and a backslash must both survive escaping.
probe_sysctl() {
  case "$1" in
    hw.memsize)               printf '17179869184\n' ;;
    machdep.cpu.brand_string) printf 'Fake "M2" \\ Chip\n' ;;
    hw.physicalcpu|hw.ncpu)   printf '10\n' ;;
    hw.optional.arm64)        printf '1\n' ;;
    sysctl.proc_translated)   printf '0\n' ;;
  esac
  return 0
}
probe_mount_table() {
  printf '//testuser@fileserver/My "Docs" on /Volumes/o"brien (smbfs, nodev, nosuid, mounted by testuser)\n'
  return 0
}
STUBS
run_scenario jsonshape "$H" "$S" --json-only --out "$TMPROOT/out/jsonshape"

assert_exit_code 0 "$SC_RC" 'json-only run completes without error'
assert_report 'json-only run writes a report'

if [ "$OUT_FLAG_HONOURED" = "1" ]; then
  pass '--out redirects the report to the given directory'
else
  fail '--out redirects the report to the given directory' \
    'report landed in $HOME/.engineai-installer/assess instead of the --out directory'
fi

# Every top-level key from spec section 6.
assert_json_has_key "$SC_JSON" schemaVersion 'report has top-level key schemaVersion'
assert_json_has_key "$SC_JSON" assessVersion 'report has top-level key assessVersion'
assert_json_has_key "$SC_JSON" timestamp     'report has top-level key timestamp'
assert_json_has_key "$SC_JSON" machine       'report has top-level key machine'
assert_json_has_key "$SC_JSON" maturityLevel 'report has top-level key maturityLevel'
assert_json_has_key "$SC_JSON" readiness     'report has top-level key readiness'
assert_json_has_key "$SC_JSON" findings      'report has top-level key findings'
assert_json_has_key "$SC_JSON" summary       'report has top-level key summary'

# Nested keys the console and downstream tooling depend on.
assert_json_has_key "$SC_JSON" hostname       'machine block carries hostname'
assert_json_has_key "$SC_JSON" arch           'machine block carries arch'
assert_json_has_key "$SC_JSON" verdict        'readiness block carries verdict'
assert_json_has_key "$SC_JSON" blockers       'readiness block carries blockers'
assert_json_has_key "$SC_JSON" recommendation 'findings carry a recommendation field'
assert_json_has_key "$SC_JSON" evidence       'findings carry an evidence field'
assert_json_has_key "$SC_JSON" category       'findings carry a category field'

assert_equals '1' "$(json_scalar "$SC_JSON" schemaVersion)" 'schemaVersion is 1'
assert_contains "$(json_scalar "$SC_JSON" assessVersion)" '.' 'assessVersion looks like a version string'

# recommendation and data are JSON null when absent, never "" and never {}.
assert_file_matches "$SC_JSON" '"recommendation"[[:space:]]*:[[:space:]]*null' \
  'absent recommendations serialise as JSON null'
assert_file_not_matches "$SC_JSON" '"recommendation"[[:space:]]*:[[:space:]]*""' \
  'absent recommendations are never the empty string'
assert_file_not_matches "$SC_JSON" '"data"[[:space:]]*:[[:space:]]*\{[[:space:]]*\}' \
  'absent data is never an empty object'

# Escaping: a double quote and a backslash must both come back escaped.
assert_file_contains "$SC_JSON" 'Fake \"M2\" \\ Chip' 'a quote and a backslash in probe output are escaped'
assert_file_contains "$SC_JSON" '/Volumes/o\"brien' 'a mount path with an embedded quote is escaped'
assert_file_contains "$SC_JSON" 'My \"Docs\"' 'a share name with embedded quotes is escaped'

# BOM-less UTF-8: Claude Desktop rejects a BOM, and so should our own reader.
if json_no_bom "$SC_JSON"; then
  pass 'report is written BOM-less'
else
  fail 'report is written BOM-less' 'first three bytes are EF BB BF'
fi

# Filename convention: yyyy-MM-dd-HHmmss.json
JSON_BASE=$(basename "$SC_JSON" 2>/dev/null)
if printf '%s' "$JSON_BASE" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}\.json$'; then
  pass 'report filename matches yyyy-MM-dd-HHmmss.json'
else
  fail 'report filename matches yyyy-MM-dd-HHmmss.json' "got: $JSON_BASE"
fi

# Timestamp field: ISO 8601 with a colon in the offset.
if grep -qE '"timestamp"[[:space:]]*:[[:space:]]*"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{2}:[0-9]{2}"' "$SC_JSON" 2>/dev/null; then
  pass 'timestamp is ISO 8601 with a colon in the UTC offset'
else
  fail 'timestamp is ISO 8601 with a colon in the UTC offset' "got: $(json_scalar "$SC_JSON" timestamp)"
fi

# summary counts ok / gap / missing (and deliberately not info).
assert_file_matches "$SC_JSON" '"ok"[[:space:]]*:[[:space:]]*[0-9]+'      'summary counts ok'
assert_file_matches "$SC_JSON" '"gap"[[:space:]]*:[[:space:]]*[0-9]+'     'summary counts gap'
assert_file_matches "$SC_JSON" '"missing"[[:space:]]*:[[:space:]]*[0-9]+' 'summary counts missing'

# --json-only keeps the console clean.
assert_not_contains "$SC_OUT" '== machine-health ==' '--json-only suppresses the category sections'
assert_not_contains "$SC_OUT" 'What we would do' '--json-only suppresses the recommendation block'

# ---------------------------------------------------------------------------
# Console output contract
# ---------------------------------------------------------------------------

section 'Console output contract'

run_scenario console "$H" "$S" --out "$TMPROOT/out/console"

assert_exit_code 0 "$SC_RC" 'console run completes without error'
assert_contains "$SC_OUT" 'Engine AI Claude Health Check' 'console prints the banner'
assert_contains "$SC_OUT" 'scanning:' 'console prints per-check progress lines'
assert_contains "$SC_OUT" '== machine-health ==' 'console prints the machine-health section'
assert_contains "$SC_OUT" '== claude-desktop ==' 'console prints the claude-desktop section'
assert_contains "$SC_OUT" 'Claude maturity:' 'console prints the maturity line'
assert_contains "$SC_OUT" 'Install readiness:' 'console prints the readiness line'
assert_contains "$SC_OUT" 'Report:' 'console prints the report path'
assert_not_contains "$SC_OUT" $'\xe2\x80\x94' 'console output contains no em dashes'

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

printf '\n'
if [ -n "$WARN_LIST" ]; then
  printf 'Warnings:%s\n\n' "$WARN_LIST"
fi
if [ -n "$FAILED_LIST" ]; then
  printf 'Failed tests:%s\n\n' "$FAILED_LIST"
fi

printf 'Passed: %d Failed: %d\n' "$TESTS_PASSED" "$TESTS_FAILED"

if [ "$TESTS_FAILED" -gt 0 ]; then
  exit 1
fi
exit 0
