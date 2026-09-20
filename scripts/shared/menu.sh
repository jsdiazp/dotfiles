#!/usr/bin/env bash
# menu.sh — single shared interactive menu (sourced, not executed).
#
# Fixes applied over the diverged copies in `setup.sh` and the old `menu.sh`:
#   - One 1-based UX everywhere (old setup.sh was 0-based, menu.sh 1-based).
#   - No brace-expansion loops (`{1..$n}` never expanded) — portable counter.
#   - `echo -e`/`printf %b` so colors actually render.
#   - Strict single-value validation (`^[0-9]+$`, `^[BbQq]$`); the old
#     `^([0-9]|b)+$` accepted "bb", "1b", "00" and crashed numeric tests.
#   - `b` (back) and `q` (quit) handled before any arithmetic.
#   - No `read -p` (unsupported in zsh); `choice` scoping documented.
#   - EOF (Ctrl-D / closed stdin) returns 3 instead of looping forever.
#
# Optional upgrades (all backward compatible, all overridable per call):
#   - MENU_DEFAULT="N" — bare Enter selects option N (shown in the prompt).
#   - MENU_PATH="Main > UNIX" — breadcrumb line rendered above the title.
#   - MENU_SINGLE_KEY=1 — on a TTY with <= 9 options, one keypress selects
#     (no Enter needed); pasted/multi-char input still works.
#   - MENU_USE_FZF=auto|always|never + MENU_FZF_THRESHOLD=4 — fuzzy picker
#     via fzf when it helps (many options); numbered fallback otherwise.
#
# Compatibility: bash >= 3.2 and zsh.
#
# API:
#   display_menu "<title>" <option>...   # loops until valid/back/quit/EOF
#     on selection: MENU_CHOICE="1".."N" (1-based), `choice` mirrors it,
#                   returns 0.
#     on back:      MENU_CHOICE="b", `choice` mirrors it, returns 1.
#     on quit:      prints farewell and exits 0 (never returns).
#     on EOF:       returns 3 (caller should unwind to a safe point).
#
# Callers should `case "$MENU_CHOICE" in 1) ... ;; 2) ... ;; esac`
# and treat return 1 as "go back" and return 3 as "input gone, unwind",
# instead of indexing arrays directly
# (bash arrays are 0-based, zsh arrays are 1-based).

# Source common.sh for colors when available; keep standalone-safe.
if [ -z "${DOTFILES_COMMON_SOURCED:-}" ]; then
  _menu_dir="$(cd "$(dirname "$0")" && pwd)"
  if [ -f "$_menu_dir/common.sh" ]; then
    # shellcheck disable=SC1091
    . "$_menu_dir/common.sh"
  else
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    RESET='\033[0m'
  fi
  unset _menu_dir
fi

# have_cmd fallback when common.sh was not sourced.
if ! command -v have_cmd >/dev/null 2>&1; then
  have_cmd() {
    command -v "$1" >/dev/null 2>&1
  }
fi

# MENU_CHOICE / choice are intentionally global: shell functions cannot
# return strings, only exit codes. Documented contract, not hidden coupling.
MENU_CHOICE=""
choice=""

# Per-call overrides (callers may set these before display_menu).
MENU_DEFAULT="${MENU_DEFAULT:-}"
MENU_PATH="${MENU_PATH:-}"
MENU_SINGLE_KEY="${MENU_SINGLE_KEY:-1}"
MENU_USE_FZF="${MENU_USE_FZF:-auto}"
MENU_FZF_THRESHOLD="${MENU_FZF_THRESHOLD:-4}"

_handle_menu_exit() {
  printf '%b\n' "${BLUE}Happy coding!${RESET}"
  exit 0
}

# _menu_default_valid <count> — true when MENU_DEFAULT names a real option.
_menu_default_valid() {
  case "${MENU_DEFAULT:-}" in
    *[!0-9]* | "") return 1 ;;
  esac
  _def_num=$((10#$MENU_DEFAULT))
  [ "$_def_num" -ge 1 ] && [ "$_def_num" -le "$1" ]
}

display_options() {
  _i=1
  for _opt in "$@"; do
    if _menu_default_valid "$#" && [ "$_i" -eq "$((10#$MENU_DEFAULT))" ]; then
      printf '%b\n' "${YELLOW}${_i}) ${_opt}${GREEN}  (default)${RESET}"
    else
      printf '%b\n' "${YELLOW}${_i}) ${_opt}${RESET}"
    fi
    _i=$((_i + 1))
  done
  unset _i _opt
}

display_additional_options() {
  printf '\n%b\n' "${GREEN}Other options:${RESET}"
  printf '%b\n' "${YELLOW}b) Back to main menu${RESET}"
  printf '%b\n' "${YELLOW}q) Quit${RESET}"
  printf '\n'
}

# _menu_is_valid <raw> <count> — sets MENU_CHOICE/choice on success.
_menu_is_valid() {
  _raw="$1"
  _count="$2"
  case "$_raw" in
    [Qq])
      _handle_menu_exit
      ;;
    [Bb])
      MENU_CHOICE="b"
      choice="b"
      return 0
      ;;
    *)
      case "$_raw" in
        *[!0-9]* | "")
          printf '%b\n\n' "${RED}Wrong option. Please try again.${RESET}"
          return 1
          ;;
      esac
      # Strip leading zeros safely; `10#` prefix avoids octal inputs like 08.
      # NOTE: no quotes inside $(( )) — `10#"2"` is a syntax error.
      _num=$((10#$_raw))
      if [ "$_num" -ge 1 ] && [ "$_num" -le "$_count" ]; then
        MENU_CHOICE="$_num"
        choice="$_num"
        return 0
      fi
      printf '%b\n\n' "${RED}Wrong option. Please try again.${RESET}"
      return 1
      ;;
  esac
  unset _raw _count _num
}

# _menu_can_single_key <count> — single-keypress needs a TTY and <= 9 options
# (otherwise multi-digit input would be ambiguous).
_menu_can_single_key() {
  [ "${MENU_SINGLE_KEY:-1}" = "1" ] && [ "$1" -le 9 ] && [ -t 0 ]
}

# _menu_read_line — read one line of menu input into _menu_line.
# Returns 0 with _menu_line set, or 3 on EOF (caller must unwind, not retry:
# stdin is gone, so re-rendering would loop forever).
_menu_read_line() {
  _menu_line=""
  if _menu_can_single_key "$_count"; then
    if [ -n "${ZSH_VERSION:-}" ]; then
      IFS= read -r -k 1 _menu_ch 2>/dev/null || return 3
    else
      IFS= read -r -s -n 1 _menu_ch 2>/dev/null || return 3
    fi
    case "$_menu_ch" in
      "" | $'\n')
        _menu_line="" # Bare Enter — default/empty handling below.
        ;;
      *)
        printf '%s' "$_menu_ch"
        _menu_rest=""
        # Drain anything already typed or pasted after the first char, so
        # "12" pasted at once still arrives as one line.
        if IFS= read -r -t 0 _menu_rest 2>/dev/null; then
          IFS= read -r _menu_rest 2>/dev/null || _menu_rest=""
          _menu_line="${_menu_ch}${_menu_rest}"
        else
          _menu_line="$_menu_ch"
        fi
        printf '\n'
        ;;
    esac
    unset _menu_ch _menu_rest
    return 0
  fi
  IFS= read -r _menu_line 2>/dev/null || return 3
  return 0
}

# _menu_should_fzf <count> — use the fuzzy picker only when it helps.
_menu_should_fzf() {
  case "${MENU_USE_FZF:-auto}" in
    never) return 1 ;;
    always) : ;;
    *)
      [ "$1" -gt "${MENU_FZF_THRESHOLD:-4}" ] || return 1
      ;;
  esac
  [ -z "${DOTFILES_NO_FZF:-}" ] || return 1
  have_cmd fzf || return 1
  [ -t 0 ] && [ -t 1 ]
}

# _menu_pick_fzf <title> <option>... — fuzzy-pick one option.
# Sets MENU_CHOICE/choice (1-based). Returns 0 on pick, 1 on abort (Esc etc).
_menu_pick_fzf() {
  _fzf_title="$1"
  shift
  _fzf_i=1
  _fzf_list=""
  for _fzf_opt in "$@"; do
    _fzf_list="${_fzf_list}${_fzf_i}	${_fzf_opt}
"
    _fzf_i=$((_fzf_i + 1))
  done
  _fzf_rc=0
  _fzf_sel="$(printf '%s' "$_fzf_list" | fzf --delimiter='	' --with-nth=2.. \
    --accept-nth=1 --reverse --height=40% --prompt="${_fzf_title}> " 2>/dev/null)" || _fzf_rc=$?
  if [ "$_fzf_rc" -ne 0 ] || [ -z "$_fzf_sel" ]; then
    MENU_CHOICE="b"
    choice="b"
    return 1
  fi
  # Keep only the first tab field (real fzf already outputs just
  # --accept-nth=1; this also tolerates shims/full-line output).
  _fzf_sel="${_fzf_sel%%$'\t'*}"
  _fzf_sel="$(printf '%s' "$_fzf_sel" | tr -d '[:space:]')"
  if _menu_is_valid "$_fzf_sel" "$#" 2>/dev/null; then
    return 0
  fi
  MENU_CHOICE="b"
  choice="b"
  return 1
}

# _menu_prompt <count> — "[1/2/b/q]: " with an Enter=default hint when set.
_menu_prompt() {
  _prompt="[1"
  _n=2
  while [ "$_n" -le "$1" ]; do
    _prompt="${_prompt}/${_n}"
    _n=$((_n + 1))
  done
  _prompt="${_prompt}/b/q]"
  if _menu_default_valid "$1"; then
    _prompt="${_prompt} (Enter=${MENU_DEFAULT})"
  fi
  printf '%s: ' "$_prompt"
  unset _n _prompt
}

display_menu() {
  _title="$1"
  shift
  _count=$#
  if [ "$_count" -eq 0 ]; then
    printf '%b\n' "${RED}display_menu: no options provided${RESET}" >&2
    return 2
  fi

  # Fuzzy fast path: no numbered render, Esc aborts back to the caller.
  if _menu_should_fzf "$_count"; then
    if _menu_pick_fzf "$_title" "$@"; then
      return 0
    fi
    return 1
  fi

  while true; do
    if [ -n "${MENU_PATH:-}" ]; then
      printf '%b\n' "${BLUE}${MENU_PATH}${RESET}"
    fi
    printf '%b\n\n' "${BOLD}${GREEN}${_title}${RESET}"

    display_options "$@"
    display_additional_options

    _menu_prompt "$_count"

    if ! _menu_read_line; then
      printf '\n'
      return 3
    fi

    # Trim surrounding whitespace (users often paste " 2 ").
    _input="$(printf '%s' "$_menu_line" | tr -d '[:space:]')"
    printf '\n'

    if [ -z "$_input" ]; then
      if _menu_default_valid "$_count"; then
        MENU_CHOICE="$((10#$MENU_DEFAULT))"
        choice="$MENU_CHOICE"
        return 0
      fi
      printf '%b\n\n' "${YELLOW}Type a number, b, or q.${RESET}"
      continue
    fi

    if _menu_is_valid "$_input" "$_count"; then
      if [ "$MENU_CHOICE" = "b" ]; then
        return 1
      fi
      return 0
    fi
    # Invalid input: loop and re-render instead of pushing retry logic
    # into every caller.
  done
}
