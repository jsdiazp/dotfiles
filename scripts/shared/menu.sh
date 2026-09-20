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
#
# Compatibility: bash >= 3.2 and zsh.
#
# API:
#   display_menu "<title>" <option>...   # loops until valid/back/quit
#     on selection: MENU_CHOICE="1".."N" (1-based), `choice` mirrors it,
#                   returns 0.
#     on back:      MENU_CHOICE="b", `choice` mirrors it, returns 1.
#     on quit:      prints farewell and exits 0 (never returns).
#
# Callers should `case "$MENU_CHOICE" in 1) ... ;; 2) ... ;; esac`
# and treat return 1 as "go back", instead of indexing arrays directly
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

# MENU_CHOICE / choice are intentionally global: shell functions cannot
# return strings, only exit codes. Documented contract, not hidden coupling.
MENU_CHOICE=""
choice=""

_handle_menu_exit() {
  printf '%b\n' "${BLUE}Happy coding!${RESET}"
  exit 0
}

display_options() {
  _i=1
  for _opt in "$@"; do
    printf '%b\n' "${YELLOW}${_i}) ${_opt}${RESET}"
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

display_menu() {
  _title="$1"
  shift
  _count=$#
  if [ "$_count" -eq 0 ]; then
    printf '%b\n' "${RED}display_menu: no options provided${RESET}" >&2
    return 2
  fi

  while true; do
    printf '%b\n\n' "${BOLD}${GREEN}${_title}${RESET}"
    display_options "$@"
    display_additional_options

    # Build "[1/2/b/q]: " prompt without zsh-specific expansions.
    _prompt="[1"
    _n=2
    while [ "$_n" -le "$_count" ]; do
      _prompt="${_prompt}/${_n}"
      _n=$((_n + 1))
    done
    _prompt="${_prompt}/b/q]: "
    printf '%s' "$_prompt"
    unset _n

    _input=""
    IFS= read -r _input || _input=""
    # Trim surrounding whitespace (users often paste " 2 ").
    _input="$(printf '%s' "$_input" | tr -d '[:space:]')"
    printf '\n'

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
