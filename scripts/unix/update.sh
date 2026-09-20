#!/usr/bin/env bash
# update.sh — update OS packages and language/tooling ecosystems.
#
# Patterns:
#   - Registry: every updater is a `update_*` function guarded by `have_cmd`;
#     main() iterates an explicit list instead of a hand-written sequence.
#   - Each updater is skippable and non-fatal: one ecosystem failing never
#     aborts the whole run (collects failures and reports at the end).
#   - Outcomes land in a summary table: `timed` maps exit 0/2/other to
#     OK/SKIP/FAIL with elapsed times; `run_updater` records sub-steps.
#   - No sourcing of ~/.zshrc (slow, side-effectful in automation).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../shared/common.sh"

# run_updater <label> <command...> — best-effort step: logs, skips when the
# command is missing, records OK/FAIL into the summary table.
# Never aborts: failure counting belongs to the `timed` parent (every
# run_updater call site is wrapped by one), so each failure counts once.
run_updater() {
  _label="$1"
  _cmd="$2"
  shift 2
  if ! have_cmd "$_cmd"; then
    info "Skipping ${_label} (${_cmd} not installed)."
    summary_record "$_label" SKIP
    return 0
  fi
  log "$_label"
  _ru_t0=$(_now_s)
  if "$_cmd" "$@"; then
    summary_record "$_label" OK "$(_fmt_dur $(($(_now_s) - _ru_t0)))"
    unset _label _cmd _ru_t0
    return 0
  else
    _ru_code=$?
    warn "${_label} failed with code ${_ru_code}; continuing."
    summary_record "$_label" FAIL "$(_fmt_dur $(($(_now_s) - _ru_t0)))"
    unset _label _cmd _ru_t0 _ru_code
    return 1
  fi
}

# timed <label> <func> [args...] — run a best-effort updater, recording
# OK (exit 0), SKIP (exit 2), or FAIL (any other exit) with elapsed time.
# Never fails itself, so one ecosystem never aborts the whole run.
# Failure totals come from the summary table (SUMMARY_FAILED), not a counter.
timed() {
  _tm_label="$1"
  shift
  _tm_t0=$(_now_s)
  _tm_code=0
  "$@" || _tm_code=$?
  _tm_dt=$(($(_now_s) - _tm_t0))
  case "$_tm_code" in
    0) summary_record "$_tm_label" OK "$(_fmt_dur "$_tm_dt")" ;;
    2) summary_record "$_tm_label" SKIP ;;
    *) summary_record "$_tm_label" FAIL "$(_fmt_dur "$_tm_dt")" ;;
  esac
  unset _tm_label _tm_t0 _tm_code _tm_dt
  return 0
}

# --- OS updaters ------------------------------------------------------------

# Function to update macOS software
update_macos() {
  have_cmd softwareupdate || return 2
  run_updater "Updating macOS" softwareupdate -i -a
}

# Function to update Linux packages
update_linux() {
  have_cmd apt-get || return 2
  _rc=0
  _sudo="$(sudo_if_needed)"
  # NOTE: `apt-get update` takes no -y; full-upgrade/dist-upgrade are the
  # same operation — run once.
  run_updater "Updating Linux packages" $_sudo apt-get update || _rc=1
  run_updater "Upgrading Linux packages" $_sudo apt-get full-upgrade -y || _rc=1
  run_updater "Removing unused Linux packages" $_sudo apt-get autoremove -y || _rc=1
  run_updater "Cleaning Linux package cache" $_sudo apt-get autoclean -y || _rc=1
  unset _sudo
  return "$_rc"
}

# WSL only: update Windows packages via WinGet interop.
update_winget_wsl() {
  case "$(os_family)" in
    wsl) : ;;
    *) return 2 ;;
  esac
  if have_cmd winget.exe; then
    run_updater "Updating WinGet packages (WSL)" winget.exe upgrade --all --silent
  elif have_cmd Winget.exe; then
    run_updater "Updating WinGet packages (WSL)" Winget.exe upgrade --all --silent
  else
    return 2
  fi
}

# Function to refresh Snap packages
update_snap() {
  have_cmd snap || return 2
  _sudo=""
  if [ "$(id -u)" -ne 0 ] && have_cmd sudo; then
    _sudo="sudo"
  fi
  # shellcheck disable=SC2086
  _rc=0
  run_updater "Refreshing Snap packages" $_sudo snap refresh || _rc=$?
  unset _sudo
  return "$_rc"
}

# Function to update Flatpak packages
update_flatpak() {
  have_cmd flatpak || return 2
  run_updater "Updating Flatpak packages" flatpak update -y
}

# --- Ecosystem updaters -----------------------------------------------------

# Function to update NVM and install latest Node.js LTS version
update_nvm() {
  # nvm is a shell function, not a binary; source it when present.
  if ! command -v nvm >/dev/null 2>&1; then
    if [ -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]; then
      # shellcheck disable=SC1091
      . "${NVM_DIR:-$HOME/.nvm}/nvm.sh"
    else
      info "Skipping NVM update (nvm not installed)."
      return 2
    fi
  fi
  log "Updating Node.js LTS"
  _rc=0
  nvm install --lts --latest-npm || { warn "nvm install --lts failed; continuing."; _rc=1; }
  nvm use --lts || true
  return "$_rc"
}

# Function to update RubyGem packages
update_rubygem() {
  have_cmd gem || return 2
  log "Updating RubyGem packages"
  _rc=0
  gem update --system || { warn "gem update --system failed; continuing."; _rc=1; }
  gem update || { warn "gem update failed; continuing."; _rc=1; }
  gem cleanup || true
  return "$_rc"
}

# Function to clean CocoPods cache
clean_cocopods_cache() {
  have_cmd pod || return 2
  run_updater "Cleaning CocoaPods cache" pod cache clean --all
}

# Function to update and clean Homebrew packages
update_homebrew() {
  have_cmd brew || return 2
  log "Updating Homebrew packages"
  _rc=0
  brew cleanup || true
  brew update || { warn "brew update failed; continuing."; _rc=1; }
  brew upgrade || { warn "brew upgrade failed; continuing."; _rc=1; }
  brew upgrade --cask || true
  brew autoremove 2>/dev/null || true
  brew cleanup || true
  brew doctor || true
  return "$_rc"
}

# Function to update npm packages globally
update_npm() {
  have_cmd npm || return 2
  log "Updating npm packages globally"
  npm update -g || { warn "npm update -g failed; continuing."; return 1; }
}

# Function to clean Yarn cache
clean_yarn_cache() {
  have_cmd yarn || return 2
  run_updater "Cleaning Yarn cache" yarn cache clean
}

# Function to update Composer packages globally
update_composer() {
  have_cmd composer || return 2
  log "Updating Composer packages"
  _rc=0
  composer self-update || { warn "composer self-update failed; continuing."; _rc=1; }
  composer global update || { warn "composer global update failed; continuing."; _rc=1; }
  composer global dump-autoload || true
  return "$_rc"
}

# Function to update Oh My Zsh (fixed `--unattendand` typo).
update_ohmyzsh() {
  have_cmd omz || return 2
  run_updater "Updating Oh My Zsh" omz update --unattended
}

# Main function to execute all updates
main() {
  log "Starting System Updates" false false

  case "$(os_family)" in
    darwin) timed "macOS" update_macos ;;
    linux | wsl)
      timed "Linux packages" update_linux
      timed "WinGet (WSL)" update_winget_wsl
      timed "Snap" update_snap
      timed "Flatpak" update_flatpak
      ;;
    *) warn "Unknown OS family; skipping OS-level updates." ;;
  esac

  timed "Node.js (nvm)" update_nvm
  timed "RubyGems" update_rubygem
  timed "CocoaPods cache" clean_cocopods_cache
  timed "Homebrew" update_homebrew
  timed "npm" update_npm
  timed "Yarn cache" clean_yarn_cache
  timed "Composer" update_composer
  timed "Oh My Zsh" update_ohmyzsh

  print_summary "Update summary"

  if [ "${SUMMARY_FAILED:-0}" -gt 0 ]; then
    warn "System updates completed with ${SUMMARY_FAILED} failure(s)."
    return 1
  fi
  log "System Updates Completed"
}

main "$@"
