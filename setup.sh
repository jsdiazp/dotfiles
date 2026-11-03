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
# Portable: bash >= 3.2. macOS `readlink -f` is NOT used.

# Usage: setup.sh [--unix docker|shell|swap|update|N] [--server ubuntu|N]
#                [-v|--verbose] [--debug] [-q|--quiet] [-y|--yes]
#                [--list] [-h|--help]
# Without a task flag, the interactive menu is shown. display_menu codes:
# 0 = selected, 1 = back, 3 = EOF (input gone) — 3 unwinds to a farewell.

set -euo pipefail

# Portable script dir (no GNU `readlink -f`, which is missing on macOS).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Captured once so every function sees the same script name.
SCRIPT_NAME="$(basename "$0")"

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

# Resolve a CLI task argument (number or case-insensitive name) to a
# 1-based menu number. Prints the number; returns 1 when unknown.
unix_task_number() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    1 | docker) printf '1\n' ;;
    2 | shell) printf '2\n' ;;
    3 | swap) printf '3\n' ;;
    4 | update) printf '4\n' ;;
    *) return 1 ;;
  esac
}

server_task_number() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    1 | ubuntu) printf '1\n' ;;
    *) return 1 ;;
  esac
}

print_usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options]

Options:
  --unix <task>    Run a UNIX task directly: docker, shell, swap, update (or 1-4)
  --server <task>  Run a server task directly: ubuntu (or 1)
  -v, --verbose    Detailed output (info level), inherited by task scripts
  --debug          Debug output, inherited by task scripts
  -q, --quiet      Errors only
  -y, --yes        Assume "yes" for every prompt (unattended); exported to
                   task scripts as DOTFILES_ASSUME_YES=1
  --list           List available tasks and exit
  -h, --help       Show this help and exit

Without a task option, the interactive menu is shown.
Verbosity and --yes flags may come before or after the task option.
EOF
}

print_tasks() {
  printf 'UNIX tasks:\n'
  printf '  1) docker\n  2) shell\n  3) swap\n  4) update\n'
  printf 'Server tasks:\n'
  printf '  1) ubuntu\n'
}

# Execute the chosen script if it exists. Returns the script's own status and
# is the single place that announces success: a failed task never prints the
# success banner, it reports one `error` line instead.
execute_script() {
  local _script="$1"
  local _interpreter="${2:-bash}"
  local _code=0
  if [ ! -f "$_script" ]; then
    error "Script not found: $_script"
    return 1
  fi
  if ! command -v "$_interpreter" >/dev/null 2>&1; then
    error "Interpreter not found: $_interpreter (needed for $_script)"
    return 1
  fi
  # `|| _code=$?` keeps errexit off the child: its status is data here.
  "$_interpreter" "$_script" || _code=$?
  if [ "$_code" -ne 0 ]; then
    error "Script failed (exit $_code): $_script"
    return "$_code"
  fi
  printf '\n%b\n\n' "${BLUE}Script executed successfully.${RESET}"
  return 0
}

# Interpreter for task scripts: always bash. Every task script carries a
# `#!/usr/bin/env bash` shebang and relies on bash word-splitting of unquoted
# expansions, which zsh does not do ($T with T="a b c" is one word in zsh).
# Single seam used by unix_menu, server_menu and dispatch_cli.
task_interpreter() {
  printf 'bash\n'
}

unix_menu() {
  local _rc=0
  local _script=""
  MENU_PATH="Main > UNIX-based OS"
  display_menu "What do you want to do in your UNIX-based OS?" \
    "Setup Docker" "Setup shell" "Setup swap" "Update OS" || _rc=$?
  MENU_PATH=""
  case "$_rc" in
    0)
      _script="$(unix_script_for "$MENU_CHOICE")"
      # execute_script already reported the failure; stay in the menu.
      execute_script "$_script" "$(task_interpreter)" || true
      MENU_KEEP_SCREEN=1 # keep the task's summary: don't clear for the next menu
      return 0
      ;;
    3) return 3 ;; # EOF — unwind, do not loop.
    *) return 0 ;; # Back — return to main menu.
  esac
}

server_menu() {
  local _rc=0
  local _script=""
  MENU_PATH="Main > Server"
  display_menu "What server OS do you want to set up?" "Ubuntu" || _rc=$?
  MENU_PATH=""
  case "$_rc" in
    0)
      _script="$(server_script_for "$MENU_CHOICE")"
      # execute_script already reported the failure; stay in the menu.
      execute_script "$_script" "$(task_interpreter)" || true
      MENU_KEEP_SCREEN=1 # keep the task's summary: don't clear for the next menu
      return 0
      ;;
    3) return 3 ;; # EOF — unwind, do not loop.
    *) return 0 ;; # Back — return to main menu.
  esac
}

main_menu() {
  local _rc=0
  display_menu "What do you want to do?" \
    "Setup UNIX-based OS" "Setup server" || _rc=$?
  case "$_rc" in
    0)
      case "$MENU_CHOICE" in
        1) unix_menu ;;
        2) server_menu ;;
      esac
      ;;
    3) return 3 ;; # EOF — unwind to main.
    *) return 0 ;; # Back at top level — just re-render.
  esac
}

# resolve_verbosity — first pass over CLI args; CLI flags win over the
# environment. The results are EXPORTED so task subprocesses spawned by
# execute_script inherit them (export is what crosses the process boundary).
resolve_verbosity() {
  local _arg=""
  for _arg in "$@"; do
    case "$_arg" in
      -v | --verbose) DOTFILES_LOG_LEVEL="info" ;;
      --debug) DOTFILES_LOG_LEVEL="debug" ;;
      -q | --quiet) DOTFILES_LOG_LEVEL="error" ;;
      -y | --yes) DOTFILES_ASSUME_YES="1" ;;
    esac
  done
  export DOTFILES_LOG_LEVEL="${DOTFILES_LOG_LEVEL:-warn}"
  if [ "${DOTFILES_ASSUME_YES:-}" = "1" ]; then
    export DOTFILES_ASSUME_YES
  fi
}

# Dispatch CLI flags. Returns 0 when the caller should continue to the
# interactive menu, otherwise exits the script directly.
dispatch_cli() {
  local _cmd=""
  local _cmd_arg=""
  local _num=""
  local _want_help=0
  local _want_list=0
  if [ "$#" -eq 0 ]; then
    return 0
  fi
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h | --help)
        _want_help=1
        shift
        ;;
      --list)
        _want_list=1
        shift
        ;;
      # Verbosity and --yes are consumed by resolve_verbosity's first pass;
      # they are accepted here so they may appear before or after the task.
      -v | --verbose | --debug | -q | --quiet | -y | --yes)
        shift
        ;;
      --unix | --server)
        [ "$#" -ge 2 ] || die "Missing value for $1. See --help."
        [ -z "$_cmd" ] || die "Only one of --unix / --server may be given."
        _cmd="$1"
        _cmd_arg="$2"
        shift 2
        ;;
      *)
        die "Unknown option: $1. See --help."
        ;;
    esac
  done
  # Informational flags win, but only once the whole line parsed: a trailing
  # unknown option must still fail instead of exiting 0 mid-parse
  # (`--list --bogus`).
  if [ "$_want_help" -eq 1 ]; then
    print_usage
    exit 0
  fi
  if [ "$_want_list" -eq 1 ]; then
    print_tasks
    exit 0
  fi
  if [ -z "$_cmd" ]; then
    return 0 # Flags only (e.g. bare --verbose) — show the interactive menu.
  fi
  case "$_cmd" in
    --unix)
      _num="$(unix_task_number "$_cmd_arg")" || die "Unknown UNIX task: $_cmd_arg. See --list."
      execute_script "$(unix_script_for "$_num")" "$(task_interpreter)"
      exit "$?"
      ;;
    --server)
      _num="$(server_task_number "$_cmd_arg")" || die "Unknown server task: $_cmd_arg. See --list."
      execute_script "$(server_script_for "$_num")" "$(task_interpreter)"
      exit "$?"
      ;;
  esac
}

main() {
  local _rc=0
  resolve_verbosity "$@"
  dispatch_cli "$@"
  while true; do
    _rc=0
    main_menu || _rc=$?
    if [ "$_rc" -eq 3 ]; then
      printf '%b\n' "${BLUE}Happy coding!${RESET}"
      exit 0
    fi
  done
}

main "$@"
