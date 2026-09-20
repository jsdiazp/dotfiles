#!/usr/bin/env bash
# common.sh — shared foundation for dotfiles shell scripts.
#
# High-level patterns applied:
#   - Single source of truth (colors, logging, OS detection, idempotency)
#     instead of copy-pasted `log()` in every script.
#   - Leveled logging (debug/info/warn/error) with NO_COLOR, ASCII, and
#     log-level controls for scripts and CI alike.
#   - Fail-fast helpers (`die`, `run_step`, `require_cmd`) as a
#     Template-Method pipeline: `run_step "label" func args...`, with
#     per-step timing and an end-of-run summary table.
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
  _msg="${1:-}"
  _before="${2:-true}"
  _after="${3:-true}"
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
  unset _msg _before _after _line
}

info() {
  printf '%b\n' "${DOTFILES_GREEN}$*${DOTFILES_RESET}"
}

# debug <message...> — printed only when DOTFILES_LOG_LEVEL=debug.
# Levels: debug < info < warn < error. info/warn/error always print.
DOTFILES_LOG_LEVEL="${DOTFILES_LOG_LEVEL:-info}"

debug() {
  case "${DOTFILES_LOG_LEVEL:-info}" in
    debug) printf '%b\n' "${DOTFILES_BLUE}DEBUG: $*${DOTFILES_RESET}" >&2 ;;
  esac
}

warn() {
  printf '%b\n' "${DOTFILES_YELLOW}WARN: $*${DOTFILES_RESET}" >&2
}

error() {
  printf '%b\n' "${DOTFILES_RED}ERROR: $*${DOTFILES_RESET}" >&2
}

# die <message> [code=1] — log to stderr and exit.
die() {
  _die_msg="${1:-fatal error}"
  _die_code="${2:-1}"
  error "$_die_msg"
  exit "$_die_code"
}

# run_step <label> <command> [args...] — Template-Method pipeline step.
# Logs start, times the run, records OK/FAIL into the summary table, and
# dies with context on failure. Replaces the
# repeated `foo || { log "Failed..."; exit 1; }` blocks.
run_step() {
  _step_label="$1"
  shift
  printf '%b\n' "${DOTFILES_BLUE}${SYM_STEP} ${_step_label}...${DOTFILES_RESET}"
  _step_t0=$(_now_s)
  if "$@"; then
    _step_dt=$(($(_now_s) - _step_t0))
    summary_record "$_step_label" OK "$(_fmt_dur "$_step_dt")"
    printf '%b\n' "${DOTFILES_GREEN}${SYM_OK} ${_step_label} ($(_fmt_dur "$_step_dt"))${DOTFILES_RESET}"
    unset _step_label _step_t0 _step_dt
    return 0
  else
    _step_code=$?
    _step_dt=$(($(_now_s) - _step_t0))
    summary_record "$_step_label" FAIL "$(_fmt_dur "$_step_dt")"
    die "Step failed [${_step_code}]: ${_step_label}" "$_step_code"
  fi
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
  _fd_s="$1"
  if [ "$_fd_s" -ge 60 ]; then
    printf '%dm%ds' "$((_fd_s / 60))" "$((_fd_s % 60))"
  else
    printf '%ds' "$_fd_s"
  fi
  unset _fd_s
}

# summary_record <label> <OK|FAIL|SKIP> [detail=-] — append one result row.
summary_record() {
  _r_label="$(printf '%s' "${1:-?}" | tr '|' '/')"
  _r_status="$2"
  _r_detail="${3:--}"
  case "$_r_status" in
    OK | FAIL | SKIP) : ;;
    *) _r_status="FAIL" ;;
  esac
  DOTFILES_SUMMARY="${DOTFILES_SUMMARY}${_r_label}|${_r_status}|${_r_detail}
"
  unset _r_label _r_status _r_detail
}

# summary_reset — clear recorded rows (e.g. between menu-driven runs).
summary_reset() {
  DOTFILES_SUMMARY=""
}

# _pad_to_width <string> <width> — print string + trailing spaces.
# Uses ${#} (character-based in bash and zsh), so UTF-8 symbols align.
_pad_to_width() {
  printf '%s' "$1"
  _pad_n=$(($2 - ${#1}))
  while [ "$_pad_n" -gt 0 ]; do
    printf ' '
    _pad_n=$((_pad_n - 1))
  done
  unset _pad_n
}

# _status_cell <OK|FAIL|SKIP> — colored, width-padded status (needs $_ws).
_status_cell() {
  case "$1" in
    OK) _sc="$DOTFILES_GREEN"; _sp="${SYM_OK} OK" ;;
    FAIL) _sc="$DOTFILES_RED"; _sp="${SYM_FAIL} FAIL" ;;
    *) _sc="$DOTFILES_YELLOW"; _sp="${SYM_SKIP} SKIP" ;;
  esac
  printf '%b' "$_sc"
  _pad_to_width "$_sp" "$_ws"
  printf '%b' "$DOTFILES_RESET"
  unset _sc _sp
}

# print_summary [title=Summary] — aligned results table with counts.
# Sets SUMMARY_OK / SUMMARY_FAILED / SUMMARY_SKIPPED globals so callers can
# branch on results (single source of truth: no parallel counters to drift).
# Statuses are colorized; padding is character-based (${#} in bash/zsh),
# so UTF-8 symbols stay aligned without awk.
print_summary() {
  _sum_title="${1:-Summary}"
  if [ -z "${DOTFILES_SUMMARY:-}" ]; then
    info "No steps recorded."
    unset _sum_title
    return 0
  fi
  _wn=4
  _ws=$((4 + ${#SYM_OK}))
  _t=$((5 + ${#SYM_FAIL}))
  [ "$_t" -gt "$_ws" ] && _ws="$_t"
  _t=$((5 + ${#SYM_SKIP}))
  [ "$_t" -gt "$_ws" ] && _ws="$_t"
  _wt=4
  _c_ok=0
  _c_fail=0
  _c_skip=0
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
  _sep=""
  _i=0
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
      *) _c_skip=$((_c_skip + 1)); _wr_s="SKIP" ;;
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
  unset _sum_title _wn _ws _wt _t _wr_n _wr_s _wr_t
  unset _c_ok _c_fail _c_skip _sep_len _sep _i
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
  unset _kernel
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
sudo_if_needed() {
  if [ "$(id -u)" -eq 0 ]; then
    printf '\n'
  elif have_cmd sudo; then
    printf 'sudo\n'
  else
    printf '\n'
  fi
}

# confirm <prompt> [default=n] — returns 0 on yes. Reads from stdin.
# Accepts y/yes (any case). Portable: no `read -p` (unsupported in zsh).
confirm() {
  _prompt="${1:-Are you sure?}"
  _default="${2:-n}"
  printf '%s [%s]: ' "$_prompt" "$_default"
  _answer=""
  IFS= read -r _answer || true
  if [ -z "$_answer" ]; then
    _answer="$_default"
  fi
  case "$_answer" in
    [Yy]|[Yy][Ee][Ss]) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Idempotency primitives
# ---------------------------------------------------------------------------
ensure_dir() {
  mkdir -p "$1"
}

# backup_once <file> — keeps `<file>.bak.<timestamp>` on first run only.
backup_once() {
  _target="$1"
  if [ -e "$_target" ] || [ -L "$_target" ]; then
    _backup="${_target}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$_target" "$_backup"
    info "Backup: $_target -> $_backup"
  fi
  unset _target _backup
}

# append_once <file> <marker> <content...> — appends a marked block once.
# The block is wrapped in `# >>> dotfiles:<marker> >>>` guards so re-runs
# are no-ops. Replaces raw `echo "..." >> ~/.zshrc` (which duplicated
# fzf/starship/zoxide blocks on every run).
append_once() {
  _file="$1"
  _marker="$2"
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
  unset _file _marker _begin _end
}

# safe_link <source> <dest> — idempotent symlink (mkdir -p + ln -sfn).
# Never `rm -rf`s the destination tree; only replaces file/symlink at dest.
safe_link() {
  _src="$1"
  _dst="$2"
  if [ ! -e "$_src" ] && [ ! -L "$_src" ]; then
    die "safe_link source does not exist: $_src"
  fi
  ensure_dir "$(dirname "$_dst")"
  if [ -L "$_dst" ] && [ "$(readlink "$_dst")" = "$_src" ]; then
    return 0
  fi
  if [ -e "$_dst" ] || [ -L "$_dst" ]; then
    backup_once "$_dst"
    rm -rf "$_dst"
  fi
  ln -sfn "$_src" "$_dst"
  unset _src _dst
}

# clone_or_update <repo-url> <dest-dir> — idempotent git clone/pull.
clone_or_update() {
  _repo="$1"
  _dest="$2"
  require_cmd git
  if [ -d "${_dest}/.git" ]; then
    git -C "$_dest" pull --ff-only
  elif [ -e "$_dest" ] || [ -L "$_dest" ]; then
    backup_once "$_dest"
    rm -rf "$_dest"
    git clone "$_repo" "$_dest"
  else
    ensure_dir "$(dirname "$_dest")"
    git clone "$_repo" "$_dest"
  fi
  unset _repo _dest
}

# portable_script_dir — best-effort `dirname $0` resolver without `readlink -f`
# (which does not exist on macOS). Callers prefer this over `$PWD`.
portable_script_dir() {
  _src="$0"
  # Resolve one level of symlink chain with plain `readlink` when available.
  while [ -L "$_src" ] && have_cmd readlink; do
    _link="$(readlink "$_src")"
    case "$_link" in
      /*) _src="$_link" ;;
      *) _src="$(dirname "$_src")/$_link" ;;
    esac
  done
  (cd "$(dirname "$_src")" && pwd)
  unset _src _link
}

# repo_root_from <script-dir> — assumes layout <root>/scripts/... .
repo_root_from() {
  _here="$1"
  case "$_here" in
    */scripts/shared|*/scripts/unix|*/scripts/windows|*/scripts/servers)
      if _root="$(cd "$_here/../.." 2>/dev/null && pwd)"; then
        printf '%s\n' "$_root"
      else
        printf '%s\n' "${_here%/scripts/*}"
      fi
      unset _root
      ;;
    *) (cd "$_here/.." 2>/dev/null && pwd) ;;
  esac
  unset _here
}
