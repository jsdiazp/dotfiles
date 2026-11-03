#!/usr/bin/env bash
# common.sh — shared foundation for dotfiles shell scripts.
#
# High-level patterns applied:
#   - Single source of truth (colors, logging, OS detection, idempotency)
#     instead of copy-pasted `log()` in every script.
#   - Leveled logging (debug/info/warn/error, default warn) with NO_COLOR,
#     ASCII, and log-level controls for scripts and CI alike.
#   - Fail-fast helpers (`die`, `run_step`, `require_cmd`) as a
#     Template-Method pipeline: `run_step "label" func args...`, with
#     per-step timing, an animated spinner over captured output by default
#     (streaming at debug/info), and an end-of-run summary table.
#     `run_step_live` covers steps that prompt (capture would hide them);
#     `run_step_soft` covers best-effort steps that must never abort a run.
#   - Idempotency primitives (`append_once`, `safe_link`, `backup_once`,
#     `clone_or_update`) so re-runs never duplicate config or destroy data.
#   - Adapter pattern for OS / package managers (`os_family`, `pkg_manager`).
#
# Compatibility: bash >= 3.2 and zsh. No associative arrays, no `read -p`,
# no GNU-only flags in this file.
#
# Usage:
#   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
#   # shellcheck disable=SC1091
#   . "$SCRIPT_DIR/../shared/common.sh"

# Guard against double-sourcing (and against `set -u` when guard is unset).
if [ "${DOTFILES_COMMON_SOURCED:-0}" = "1" ]; then
  # shellcheck disable=SC2317 # `return` wins when sourced; `exit` is the executed-not-sourced fallback.
  return 0 2>/dev/null || exit 0
fi
DOTFILES_COMMON_SOURCED=1

# ---------------------------------------------------------------------------
# Colors (honor NO_COLOR / non-TTY)
# ---------------------------------------------------------------------------
if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
  DOTFILES_RED='\033[0;31m'
  DOTFILES_GREEN='\033[0;32m'
  DOTFILES_YELLOW='\033[0;33m'
  DOTFILES_BLUE='\033[0;34m'
  DOTFILES_MAGENTA='\033[0;35m'
  DOTFILES_BOLD='\033[1m'
  DOTFILES_RESET='\033[0m'
else
  DOTFILES_RED=''
  DOTFILES_GREEN=''
  DOTFILES_YELLOW=''
  DOTFILES_BLUE=''
  DOTFILES_MAGENTA=''
  DOTFILES_BOLD=''
  DOTFILES_RESET=''
fi

# Back-compat aliases used by older scripts.
RED="$DOTFILES_RED"
GREEN="$DOTFILES_GREEN"
YELLOW="$DOTFILES_YELLOW"
BLUE="$DOTFILES_BLUE"
BOLD="$DOTFILES_BOLD"
RESET="$DOTFILES_RESET"

# Status symbols (UTF-8 by default; DOTFILES_ASCII=1 for plain text).
if [ -n "${DOTFILES_ASCII:-}" ]; then
  SYM_OK='[ok]'
  SYM_FAIL='[FAIL]'
  SYM_SKIP='[skip]'
  SYM_STEP='>'
else
  SYM_OK='✔'
  SYM_FAIL='✘'
  SYM_SKIP='○'
  SYM_STEP='▸'
fi

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
# log <message> [before=true] [after=true] — timestamped magenta log line.
# Empty messages print nothing (preserves old behavior callers rely on).
log() {
  local _msg="${1:-}"
  local _before="${2:-true}"
  local _after="${3:-true}"
  local _line=""
  if [ -n "$_msg" ]; then
    _line="${DOTFILES_MAGENTA}[$(date +"%Y-%m-%d %H:%M:%S")] ⚡️ ${_msg}${DOTFILES_RESET}"
    if [ "$_before" = "true" ]; then
      printf '\n'
    fi
    printf '%b\n' "$_line"
    if [ "$_after" = "true" ]; then
      printf '\n'
    fi
  fi
}

# Log levels: debug < info < warn < error (DOTFILES_LOG_LEVEL, default warn).
#   debug/info print only at those levels; log() progress lines plus
#   warn/error always print, so default runs stay informative but quiet.
DOTFILES_LOG_LEVEL="${DOTFILES_LOG_LEVEL:-warn}"

info() {
  case "${DOTFILES_LOG_LEVEL:-warn}" in
    debug | info) printf '%b\n' "${DOTFILES_GREEN}$*${DOTFILES_RESET}" ;;
  esac
}

# debug <message...> — printed only when DOTFILES_LOG_LEVEL=debug.
debug() {
  case "${DOTFILES_LOG_LEVEL:-warn}" in
    debug) printf '%b\n' "${DOTFILES_BLUE}DEBUG: $*${DOTFILES_RESET}" >&2 ;;
  esac
}

warn() {
  printf '%b\n' "${DOTFILES_YELLOW}WARN: $*${DOTFILES_RESET}" >&2
}

error() {
  printf '%b\n' "${DOTFILES_RED}ERROR: $*${DOTFILES_RESET}" >&2
}

# _DOTFILES_STEP_LOGS — newline-separated list of active capture files,
# outermost step first. Kept so a fatal failure can reach the real terminal
# through every step level that is currently capturing (see die()).
: "${_DOTFILES_STEP_LOGS:=}"

# _step_log_push <file> — track one active capture file.
_step_log_push() {
  _DOTFILES_STEP_LOGS="${_DOTFILES_STEP_LOGS}${1}
"
}

# _step_errfd_open — true when fd 4 (the pre-capture stderr) is open, i.e.
# die() is running inside a captured step and can reach the real terminal.
_step_errfd_open() {
  { : >&4; } 2>/dev/null
}

# _step_dump_active_logs <fd> — print every active capture (outermost first)
# and delete the files, then forget them. <fd> is 4 when we are inside a
# capture, else 1 (plain stdout, the historic top-level behavior).
_step_dump_active_logs() {
  local _sd_fd="${1:-1}"
  local _sd_log=""
  [ -n "${_DOTFILES_STEP_LOGS:-}" ] || return 0
  while IFS= read -r _sd_log; do
    [ -n "$_sd_log" ] || continue
    if [ -s "$_sd_log" ]; then
      if [ "$_sd_fd" = "4" ]; then
        printf '\n' >&4
        cat "$_sd_log" >&4
      else
        printf '\n'
        cat "$_sd_log"
      fi
    fi
    rm -f "$_sd_log"
  done <<EOF
${_DOTFILES_STEP_LOGS}
EOF
  _DOTFILES_STEP_LOGS=""
}

# die <message> [code=1] — log to stderr and exit.
# Stops a running spinner first (it must never outlive the shell). Inside a
# captured step the captured output would otherwise be swallowed and the
# message would land in the capture file, so every active capture is dumped
# (outermost first) and the error printed on the REAL terminal (fd 4).
die() {
  local _die_msg="${1:-fatal error}"
  local _die_code="${2:-1}"
  _spinner_stop
  if [ -n "${_DOTFILES_STEP_LOGS:-}" ]; then
    if _step_errfd_open; then
      _step_dump_active_logs 4
      error "$_die_msg" 2>&4
      exit "$_die_code"
    fi
    _step_dump_active_logs 1
  fi
  error "$_die_msg"
  exit "$_die_code"
}

# _log_quiet — true when steps should capture output (warn/error levels).
_log_quiet() {
  case "${DOTFILES_LOG_LEVEL:-warn}" in
    debug | info) return 1 ;;
    *) return 0 ;;
  esac
}

# _spin_enabled — animated spinner needs a TTY and no opt-out.
# Honors DOTFILES_NO_SPINNER=1 (and DOTFILES_ASCII=1 for |/-\ frames).
_spin_enabled() {
  [ -z "${DOTFILES_NO_SPINNER:-}" ] || return 1
  [ -t 1 ] || return 1
  return 0
}

# _spinner_start <label> — background animation on the current line.
# Frames iterate as separate words (no substring ops: multibyte-safe).
# Shares the caller's process group, so Ctrl-C takes it down with the step;
# every caller must still _spinner_stop before printing the outcome.
# The loop also dies with its shell (parent check each frame), so a fatal
# exit can never leave an orphan frame printer behind.
_spinner_start() {
  local _spinner_label="$1"
  local _spinner_parent=$$ # captured before forking; `$$` survives the subshell
  (
    if [ -n "${DOTFILES_ASCII:-}" ]; then
      # shellcheck disable=SC1003 # ASCII frame: the single-quoted backslash is intentional.
      set -- '|' '/' '-' '\'
    else
      set -- '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏'
    fi
    while true; do
      for _c in "$@"; do
        kill -0 "$_spinner_parent" 2>/dev/null || exit 0
        printf '\r%b %s... ' "${DOTFILES_BLUE}${_c}${DOTFILES_RESET}" "$_spinner_label"
        sleep 0.15
      done
    done
  ) &
  # Notification-only global by design: _spinner_stop needs it across calls.
  _spinner_pid=$!
}

# _spinner_stop — kill the animation and clear its line (TTY-only caller).
_spinner_stop() {
  if [ -z "${_spinner_pid:-}" ]; then
    return 0
  fi
  kill "$_spinner_pid" 2>/dev/null || true
  wait "$_spinner_pid" 2>/dev/null || true
  printf '\r\033[K'
  _spinner_pid=""
}

# _step_run <fatal|live|soft> <label> <command> [args...] — the one step core.
# Quiet by default (warn/error): stdout+stderr are captured to a temp file
# behind an animated spinner (TTY) or a static start line (pipes), and a
# failure dumps the capture. Verbose (debug/info) streams output live
# between start/finish lines; `live` mode always streams (prompting steps).
# Records exactly one summary row and returns the command's status — except
# `soft`, which never fails (0/2/other map to OK/SKIP/FAIL). A fatal failure
# leaves its capture on the _DOTFILES_STEP_LOGS stack (and the temp file on
# disk) for die() to dump on the real terminal, so nested steps never bury
# their output in an outer capture file. Nested steps are safe: a step
# function calling run_step again sees a non-TTY stdout, so the inner step
# streams into the outer capture instead of starting a second spinner.
_step_run() {
  local _sr_mode="$1"
  local _sr_label="$2"
  shift 2
  local _sr_stream=0
  local _sr_log=""
  local _sr_spin=0
  local _sr_outer=0
  local _sr_saved_logs="${_DOTFILES_STEP_LOGS:-}"
  local _sr_tmp="" _sr_t0="" _sr_dur="" _sr_code=0

  if [ "$_sr_mode" = "live" ] || ! _log_quiet; then
    _sr_stream=1
  fi
  if [ "$_sr_stream" -eq 0 ]; then
    if _sr_tmp="$(mktemp "${TMPDIR:-/tmp}/dotfiles-step.XXXXXX" 2>/dev/null)"; then
      _sr_log="$_sr_tmp"
    fi
    if _spin_enabled; then
      _sr_spin=1
      _spinner_start "$_sr_label"
    else
      printf '%b\n' "${DOTFILES_BLUE}${SYM_STEP} ${_sr_label}...${DOTFILES_RESET}"
    fi
  else
    printf '%b\n' "${DOTFILES_BLUE}${SYM_STEP} ${_sr_label}...${DOTFILES_RESET}"
  fi
  _sr_t0=$(_now_s)
  # `|| _sr_code=$?` keeps errexit off the step: the exit code is data here.
  if [ -n "$_sr_log" ]; then
    if [ -z "$_sr_saved_logs" ]; then
      _sr_outer=1
    fi
    _step_log_push "$_sr_log"
    # The outermost capture parks the real stderr on fd 4 for its whole
    # subtree, so die() can report from any depth (nested levels inherit it).
    if [ "$_sr_outer" -eq 1 ]; then
      "$@" 4>&2 >"$_sr_log" 2>&1 || _sr_code=$?
    else
      "$@" >"$_sr_log" 2>&1 || _sr_code=$?
    fi
  else
    "$@" || _sr_code=$?
  fi
  _sr_dur="$(_fmt_dur $(($(_now_s) - _sr_t0)))"
  if [ "$_sr_spin" -eq 1 ]; then
    _spinner_stop
  fi
  if [ "$_sr_code" -eq 0 ]; then
    summary_record "$_sr_label" OK "$_sr_dur"
    printf '%b\n' "${DOTFILES_GREEN}${SYM_OK} ${_sr_label} (${_sr_dur})${DOTFILES_RESET}"
    _DOTFILES_STEP_LOGS="$_sr_saved_logs"
    if [ -n "$_sr_log" ]; then
      rm -f "$_sr_log"
    fi
    return 0
  fi
  if [ "$_sr_code" -eq 2 ] && [ "$_sr_mode" = "soft" ]; then
    summary_record "$_sr_label" SKIP
    printf '%b\n' "${DOTFILES_YELLOW}${SYM_SKIP} ${_sr_label} (skipped)${DOTFILES_RESET}"
    _DOTFILES_STEP_LOGS="$_sr_saved_logs"
    if [ -n "$_sr_log" ]; then
      rm -f "$_sr_log"
    fi
    return 0
  fi
  if [ "$_sr_mode" = "soft" ]; then
    if [ -n "$_sr_log" ]; then
      printf '\n'
      cat "$_sr_log"
      rm -f "$_sr_log"
    fi
    _DOTFILES_STEP_LOGS="$_sr_saved_logs"
    summary_record "$_sr_label" FAIL "$_sr_dur"
    printf '%b\n' "${DOTFILES_RED}${SYM_FAIL} ${_sr_label} (failed after ${_sr_dur})${DOTFILES_RESET}"
    return 0
  fi
  # Fatal: keep the capture on the stack and the file on disk; die() dumps
  # every active level on the real terminal and removes the files.
  summary_record "$_sr_label" FAIL "$_sr_dur"
  return "$_sr_code"
}

# run_step <label> <command> [args...] — Template-Method pipeline step.
# Quiet by default (warn/error): output is captured behind an animated
# spinner (TTY) or a static start line (pipes); failures dump the capture.
# Verbose (debug/info) streams output live between start/finish lines.
# Times the run, records OK/FAIL into the summary table, dies on failure.
# Interactive steps (prompts!) must use run_step_live instead: captured
# output would hide their prompts while waiting on invisible input.
run_step() {
  local _step_label="$1"
  shift
  local _step_code=0
  _step_run fatal "$_step_label" "$@" || _step_code=$?
  if [ "$_step_code" -ne 0 ]; then
    die "Step failed [${_step_code}]: ${_step_label}" "$_step_code"
  fi
  return 0
}

# run_step_live <label> <command> [args...] — like run_step but always
# streams output. REQUIRED for steps that prompt (confirm/read): capture
# would hide their prompts while waiting on invisible input.
run_step_live() {
  local _step_label="$1"
  shift
  local _step_code=0
  _step_run live "$_step_label" "$@" || _step_code=$?
  if [ "$_step_code" -ne 0 ]; then
    die "Step failed [${_step_code}]: ${_step_label}" "$_step_code"
  fi
  return 0
}

# run_step_soft <label> <command> [args...] — best-effort step: NEVER dies
# and always returns 0. Exit 0 records OK, exit 2 records SKIP (yellow
# "skipped" line), anything else records FAIL and dumps the capture.
# Replaces per-script copies (update.sh's `timed`) so one failing ecosystem
# never aborts a whole run; failure totals come from SUMMARY_FAILED.
# The command itself must NOT call a fatal run_step or die(): die exits the
# whole script by design, so soft only protects against the command's exit
# code, never against a fatal failure raised inside it.
run_step_soft() {
  _step_run soft "$@" || true
  return 0
}

# ---------------------------------------------------------------------------
# Run summary tables
# ---------------------------------------------------------------------------
# Rows accumulate in DOTFILES_SUMMARY as `label|STATUS|detail` lines, so
# reporting stays portable (no arrays: bash is 0-based, zsh is 1-based).
: "${DOTFILES_SUMMARY:=}"

# _now_s — portable epoch seconds (macOS + GNU date both support %s).
_now_s() {
  date +%s
}

# _fmt_dur <seconds> — "45s", "75s" -> "1m15s".
_fmt_dur() {
  local _fd_s="$1"
  if [ "$_fd_s" -ge 60 ]; then
    printf '%dm%ds' "$((_fd_s / 60))" "$((_fd_s % 60))"
  else
    printf '%ds' "$_fd_s"
  fi
}

# summary_record <label> <OK|FAIL|SKIP> [detail=-] — append one result row.
summary_record() {
  local _r_label _r_status="${2:-FAIL}" _r_detail="${3:--}"
  _r_label="$(printf '%s' "${1:-?}" | tr '|' '/')"
  case "$_r_status" in
    OK | FAIL | SKIP) : ;;
    *) _r_status="FAIL" ;;
  esac
  DOTFILES_SUMMARY="${DOTFILES_SUMMARY}${_r_label}|${_r_status}|${_r_detail}
"
}

# summary_reset — clear recorded rows (e.g. between menu-driven runs).
summary_reset() {
  DOTFILES_SUMMARY=""
}

# _pad_to_width <string> <width> — print string + trailing spaces.
# Uses ${#} (character-based in bash and zsh), so UTF-8 symbols align.
_pad_to_width() {
  local _pad_n
  printf '%s' "$1"
  _pad_n=$(($2 - ${#1}))
  while [ "$_pad_n" -gt 0 ]; do
    printf ' '
    _pad_n=$((_pad_n - 1))
  done
}

# _status_cell <OK|FAIL|SKIP> — colored, width-padded status (needs $_ws).
# $_ws is a local of print_summary, visible here through dynamic scoping.
_status_cell() {
  local _sc="" _sp=""
  case "$1" in
    OK)
      _sc="$DOTFILES_GREEN"
      _sp="${SYM_OK} OK"
      ;;
    FAIL)
      _sc="$DOTFILES_RED"
      _sp="${SYM_FAIL} FAIL"
      ;;
    *)
      _sc="$DOTFILES_YELLOW"
      _sp="${SYM_SKIP} SKIP"
      ;;
  esac
  printf '%b' "$_sc"
  _pad_to_width "$_sp" "$_ws"
  printf '%b' "$DOTFILES_RESET"
}

# print_summary [title=Summary] — aligned results table with counts.
# Sets SUMMARY_OK / SUMMARY_FAILED / SUMMARY_SKIPPED globals so callers can
# branch on results (single source of truth: no parallel counters to drift).
# Statuses are colorized; padding is character-based (${#} in bash/zsh),
# so UTF-8 symbols stay aligned without awk.
print_summary() {
  local _sum_title="${1:-Summary}"
  local _wn=4 _ws=0 _wt=4 _t=0
  local _c_ok=0 _c_fail=0 _c_skip=0
  local _wr_n="" _wr_s="" _wr_t=""
  local _sep_len=0 _sep="" _i=0
  if [ -z "${DOTFILES_SUMMARY:-}" ]; then
    info "No steps recorded."
    return 0
  fi
  _ws=$((4 + ${#SYM_OK}))
  _t=$((5 + ${#SYM_FAIL}))
  [ "$_t" -gt "$_ws" ] && _ws="$_t"
  _t=$((5 + ${#SYM_SKIP}))
  [ "$_t" -gt "$_ws" ] && _ws="$_t"
  while IFS='|' read -r _wr_n _wr_s _wr_t; do
    [ -n "$_wr_n" ] || continue
    [ "${#_wr_n}" -gt "$_wn" ] && _wn="${#_wr_n}"
    [ "${#_wr_t}" -gt "$_wt" ] && _wt="${#_wr_t}"
  done <<<"$DOTFILES_SUMMARY"

  printf '\n%b\n' "${BOLD}${GREEN}${_sum_title}${RESET}"
  printf '  '
  _pad_to_width "STEP" "$_wn"
  printf '  '
  _pad_to_width "STATUS" "$_ws"
  printf '  %s\n' "TIME"
  _sep_len=$((2 + _wn + 2 + _ws + 2 + _wt))
  while [ "$_i" -lt "$_sep_len" ]; do
    _sep="${_sep}-"
    _i=$((_i + 1))
  done
  printf '%s\n' "$_sep"
  while IFS='|' read -r _wr_n _wr_s _wr_t; do
    [ -n "$_wr_n" ] || continue
    case "$_wr_s" in
      OK) _c_ok=$((_c_ok + 1)) ;;
      FAIL) _c_fail=$((_c_fail + 1)) ;;
      *)
        _c_skip=$((_c_skip + 1))
        _wr_s="SKIP"
        ;;
    esac
    printf '  '
    _pad_to_width "$_wr_n" "$_wn"
    printf '  '
    _status_cell "$_wr_s"
    printf '  %s\n' "${_wr_t:--}"
  done <<<"$DOTFILES_SUMMARY"
  printf '%s\n' "$_sep"
  printf '  %d ok, %d failed, %d skipped\n' "$_c_ok" "$_c_fail" "$_c_skip"
  SUMMARY_OK="$_c_ok"
  SUMMARY_FAILED="$_c_fail"
  SUMMARY_SKIPPED="$_c_skip"
}

# ---------------------------------------------------------------------------
# Command / OS adapters (Strategy pattern)
# ---------------------------------------------------------------------------
have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

require_cmd() {
  if ! have_cmd "$1"; then
    die "Required command not found: $1"
  fi
}

# os_family — prints one of: darwin | linux | wsl | unknown (never fails).
os_family() {
  local _kernel=""
  _kernel="$(uname -s 2>/dev/null || echo unknown)"
  case "$_kernel" in
    Darwin*) printf 'darwin\n' ;;
    Linux*)
      if uname -r 2>/dev/null | grep -qi microsoft; then
        printf 'wsl\n'
      else
        printf 'linux\n'
      fi
      ;;
    *) printf 'unknown\n' ;;
  esac
}

# pkg_manager — prints one of: apt | dnf | yum | brew | none.
pkg_manager() {
  if have_cmd apt-get || have_cmd apt; then
    printf 'apt\n'
  elif have_cmd dnf; then
    printf 'dnf\n'
  elif have_cmd yum; then
    printf 'yum\n'
  elif have_cmd brew; then
    printf 'brew\n'
  else
    printf 'none\n'
  fi
}

# sudo_if_needed — prints "sudo" when euid != 0 and sudo exists, else "".
# legacy: prefer as_root (no unquoted `$_sudo cmd` / SC2086 at call sites).
sudo_if_needed() {
  if [ "$(id -u)" -eq 0 ]; then
    printf '\n'
  elif have_cmd sudo; then
    printf 'sudo\n'
  else
    printf '\n'
  fi
}

# as_root <command> [args...] — run a command as root: through sudo when
# euid != 0 and sudo exists, directly otherwise. Lets callers write
# `run_step "Updating apt" as_root apt-get update` instead of unquoted
# `$_sudo apt-get update` (no arrays needed on bash 3.2 under `set -u`).
as_root() {
  if [ "$(id -u)" -ne 0 ] && have_cmd sudo; then
    sudo "$@"
  else
    "$@"
  fi
}

# sudo_warm — ask for the sudo password once, up front, before spinners
# hide prompts. Silent no-op when already root, no sudo, not on a TTY, or
# already warmed in this process. No background keep-alive loop: returns
# sudo's non-zero status when `sudo -v` fails, so the caller decides.
sudo_warm() {
  [ -z "${_DOTFILES_SUDO_WARMED:-}" ] || return 0
  [ "$(id -u)" -ne 0 ] || return 0
  have_cmd sudo || return 0
  [ -t 0 ] && [ -t 1 ] || return 0
  sudo -v || return $?
  _DOTFILES_SUDO_WARMED=1
  return 0
}

# confirm <prompt> [default=n] — returns 0 on yes. Reads from stdin.
# Accepts y/yes (any case). Portable: no `read -p` (unsupported in zsh).
# DOTFILES_ASSUME_YES=1 answers yes automatically (unattended runs, --auto
# scripts) without touching stdin.
confirm() {
  local _prompt="${1:-Are you sure?}"
  local _default="${2:-n}"
  local _answer=""
  if [ "${DOTFILES_ASSUME_YES:-}" = "1" ]; then
    printf '%b\n' "${DOTFILES_GREEN}[auto-yes] ${_prompt}${DOTFILES_RESET}"
    return 0
  fi
  printf '%s [%s]: ' "$_prompt" "$_default"
  IFS= read -r _answer || true
  if [ -z "$_answer" ]; then
    _answer="$_default"
  fi
  case "$_answer" in
    [Yy] | [Yy][Ee][Ss]) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Idempotency primitives
# ---------------------------------------------------------------------------
# GNU sed takes `-i`, BSD/macOS sed takes `-i ''` (empty backup suffix).
# Detected once at source time because BSD sed rejects `--version`.
if sed --version >/dev/null 2>&1; then
  _DOTFILES_SED_INPLACE_GNU=1
else
  _DOTFILES_SED_INPLACE_GNU=0
fi

# sed_inplace <sed-expr> <file> — portable in-place edit of one file with
# one expression (`sed_inplace 's/a/b/' file`), hiding the -i difference.
sed_inplace() {
  if [ "$_DOTFILES_SED_INPLACE_GNU" = "1" ]; then
    sed -i "$1" "$2"
  else
    sed -i '' "$1" "$2"
  fi
}

ensure_dir() {
  mkdir -p "$1"
}

# backup_once <file> — copies `<file>` to `<file>.bak.<timestamp>`.
# NOTE: despite the name it runs on EVERY call (a fresh timestamped copy
# each time), not "first run only". Returns non-zero when the copy fails.
backup_once() {
  local _target="$1"
  local _backup=""
  if [ -e "$_target" ] || [ -L "$_target" ]; then
    _backup="${_target}.bak.$(date +%Y%m%d%H%M%S)"
    if ! cp -a "$_target" "$_backup"; then
      error "Backup failed: $_target -> $_backup"
      return 1
    fi
    info "Backup: $_target -> $_backup"
  fi
  return 0
}

# append_once <file> <marker> <content...> — appends a marked block once.
# The block is wrapped in `# >>> dotfiles:<marker> >>>` guards so re-runs
# are no-ops. Replaces raw `echo "..." >> ~/.zshrc` (which duplicated
# fzf/starship/zoxide blocks on every run).
append_once() {
  local _file="$1"
  local _marker="$2"
  local _begin=""
  local _end=""
  shift 2
  _begin="# >>> dotfiles:${_marker} >>>"
  _end="# <<< dotfiles:${_marker} <<<"
  ensure_dir "$(dirname "$_file")"
  [ -e "$_file" ] || : >"$_file"
  if grep -qF "$_begin" "$_file" 2>/dev/null; then
    return 0
  fi
  {
    printf '\n%s\n' "$_begin"
    printf '%s\n' "$*"
    printf '%s\n' "$_end"
  } >>"$_file"
}

# safe_link <source> <dest> — idempotent symlink (mkdir -p + ln -sfn).
# Never `rm -rf`s the destination tree; only replaces file/symlink at dest,
# and only after backup_once succeeded (a failed backup leaves dest intact,
# which matters because callers often run with `|| true` and errexit off).
safe_link() {
  local _src="$1"
  local _dst="$2"
  if [ ! -e "$_src" ] && [ ! -L "$_src" ]; then
    die "safe_link source does not exist: $_src"
  fi
  ensure_dir "$(dirname "$_dst")"
  if [ -L "$_dst" ] && [ "$(readlink "$_dst")" = "$_src" ]; then
    return 0
  fi
  if [ -e "$_dst" ] || [ -L "$_dst" ]; then
    if ! backup_once "$_dst"; then
      error "safe_link: refusing to replace $_dst (backup failed)"
      return 1
    fi
    rm -rf "$_dst"
  fi
  ln -sfn "$_src" "$_dst"
}

# clone_or_update <repo-url> <dest-dir> — idempotent git clone/pull.
clone_or_update() {
  local _repo="$1"
  local _dest="$2"
  require_cmd git
  if [ -d "${_dest}/.git" ]; then
    git -C "$_dest" pull --ff-only
  elif [ -e "$_dest" ] || [ -L "$_dest" ]; then
    if ! backup_once "$_dest"; then
      error "clone_or_update: refusing to replace $_dest (backup failed)"
      return 1
    fi
    rm -rf "$_dest"
    git clone "$_repo" "$_dest"
  else
    ensure_dir "$(dirname "$_dest")"
    git clone "$_repo" "$_dest"
  fi
}

# repo_root_from <script-dir> — assumes layout <root>/scripts/... .
repo_root_from() {
  local _here="$1"
  local _root=""
  case "$_here" in
    */scripts/shared | */scripts/unix | */scripts/windows | */scripts/servers)
      if _root="$(cd "$_here/../.." 2>/dev/null && pwd)"; then
        printf '%s\n' "$_root"
      else
        printf '%s\n' "${_here%/scripts/*}"
      fi
      ;;
    *) (cd "$_here/.." 2>/dev/null && pwd) ;;
  esac
}
