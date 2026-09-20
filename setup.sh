#!/usr/bin/env bash
#
# setup.sh — composition root for dotfiles provisioning.
#
# Patterns:
#   - Composition root: this file owns menu flow only; every task lives in
#     scripts/unix/* or scripts/servers/* and is dispatched by table.
#   - Configuration as data: menu labels and script paths are declared once
#     (unix_labels/unix_script_for, server_labels/server_script_for).
#   - Shared behavior (colors, logging, menu) is sourced from
#     scripts/shared/* — no duplicated menu code.
#
# Portable: bash >= 3.2 and zsh. macOS `readlink -f` is NOT used.

set -euo pipefail

# Portable script dir (no GNU `readlink -f`, which is missing on macOS).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck disable=SC1091
. "$SCRIPT_DIR/scripts/shared/common.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/scripts/shared/menu.sh"

# ---------------------------------------------------------------------------
# Declarative task registry (label -> script path via case dispatch)
# ---------------------------------------------------------------------------
unix_script_for() {
  case "$1" in
    1) printf '%s\n' "$SCRIPT_DIR/scripts/unix/docker.sh" ;;
    2) printf '%s\n' "$SCRIPT_DIR/scripts/unix/shell.sh" ;;
    3) printf '%s\n' "$SCRIPT_DIR/scripts/unix/swap.sh" ;;
    4) printf '%s\n' "$SCRIPT_DIR/scripts/unix/update.sh" ;;
    *) return 1 ;;
  esac
}

server_script_for() {
  case "$1" in
    1) printf '%s\n' "$SCRIPT_DIR/scripts/servers/ubuntu.sh" ;;
    *) return 1 ;;
  esac
}

# Execute the chosen script if it exists.
execute_script() {
  _script="$1"
  _interpreter="${2:-bash}"
  if [ ! -f "$_script" ]; then
    error "Script not found: $_script"
    return 1
  fi
  if ! command -v "$_interpreter" >/dev/null 2>&1; then
    error "Interpreter not found: $_interpreter (needed for $_script)"
    return 1
  fi
  "$_interpreter" "$_script"
  printf '\n%b\n\n' "${BLUE}Script executed successfully.${RESET}"
  unset _script _interpreter
}

# Preferred interpreter for task scripts: zsh when present (scripts target
# zsh), otherwise bash. Centralizes the old hardcoded `zsh` argument.
task_interpreter() {
  if command -v zsh >/dev/null 2>&1; then
    printf 'zsh\n'
  else
    printf 'bash\n'
  fi
}

unix_menu() {
  if display_menu "What do you want to do in your UNIX-based OS?" \
    "Setup Docker" "Setup shell" "Setup swap" "Update OS"; then
    _script="$(unix_script_for "$MENU_CHOICE")"
    execute_script "$_script" "$(task_interpreter)" || true
  fi
  # Back (return 1) or invalid input simply returns to main menu.
  return 0
}

server_menu() {
  if display_menu "What server OS do you want to set up?" "Ubuntu"; then
    _script="$(server_script_for "$MENU_CHOICE")"
    execute_script "$_script" "$(task_interpreter)" || true
  fi
  return 0
}

main_menu() {
  if display_menu "What do you want to do?" \
    "Setup UNIX-based OS" "Setup server"; then
    case "$MENU_CHOICE" in
      1) unix_menu ;;
      2) server_menu ;;
    esac
  fi
  return 0
}

main() {
  while true; do
    main_menu
  done
}

main "$@"
