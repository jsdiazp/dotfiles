#!/usr/bin/env bash
# update.sh — update OS packages and language/tooling ecosystems.
#
# Patterns:
#   - Registry: every updater is a `update_*` function guarded by `have_cmd`;
#     main() iterates an explicit list instead of a hand-written sequence.
#   - Each updater is skippable and non-fatal: one ecosystem failing never
#     aborts the whole run (collects failures and reports at the end).
#   - No sourcing of ~/.zshrc (slow, side-effectful in automation).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../shared/common.sh"

_UPDATE_FAILURES=0

# run_updater <label> <command...> — best-effort step: logs, skips when the
# command is missing, records (not aborts on) failure.
run_updater() {
  _label="$1"
  _cmd="$2"
  shift 2
  if ! have_cmd "$_cmd"; then
    info "Skipping ${_label} (${_cmd} not installed)."
    return 0
  fi
  log "$_label"
  if "$_cmd" "$@"; then
    return 0
  else
    _code=$?
    warn "${_label} failed with code ${_code}; continuing."
    _UPDATE_FAILURES=$((_UPDATE_FAILURES + 1))
    return 0
  fi
}

# --- OS updaters ------------------------------------------------------------

# Function to update macOS software
update_macos() {
  have_cmd softwareupdate || return 0
  run_updater "Updating macOS" softwareupdate -i -a
}

# Function to update Linux packages
update_linux() {
  have_cmd apt-get || return 0
  _sudo="$(sudo_if_needed)"
  # NOTE: `apt-get update` takes no -y; full-upgrade/dist-upgrade are the
  # same operation — run once.
  run_updater "Updating Linux packages" $_sudo apt-get update || true
  run_updater "Upgrading Linux packages" $_sudo apt-get full-upgrade -y || true
  run_updater "Removing unused Linux packages" $_sudo apt-get autoremove -y || true
  run_updater "Cleaning Linux package cache" $_sudo apt-get autoclean -y || true
  unset _sudo
}

# WSL only: update Windows packages via WinGet interop.
update_winget_wsl() {
  case "$(os_family)" in
    wsl) : ;;
    *) return 0 ;;
  esac
  if have_cmd winget.exe; then
    run_updater "Updating WinGet packages (WSL)" winget.exe upgrade --all --silent
  elif have_cmd Winget.exe; then
    run_updater "Updating WinGet packages (WSL)" Winget.exe upgrade --all --silent
  fi
}

# Function to refresh Snap packages
update_snap() {
  have_cmd snap || return 0
  _sudo=""
  if [ "$(id -u)" -ne 0 ] && have_cmd sudo; then
    _sudo="sudo"
  fi
  # shellcheck disable=SC2086
  run_updater "Refreshing Snap packages" $_sudo snap refresh
  unset _sudo
}

# Function to update Flatpak packages
update_flatpak() {
  have_cmd flatpak || return 0
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
      return 0
    fi
  fi
  log "Updating Node.js LTS"
  nvm install --lts --latest-npm || warn "nvm install --lts failed; continuing."
  nvm use --lts || true
}

# Function to update RubyGem packages
update_rubygem() {
  have_cmd gem || return 0
  log "Updating RubyGem packages"
  gem update --system || warn "gem update --system failed; continuing."
  gem update || warn "gem update failed; continuing."
  gem cleanup || true
}

# Function to clean CocoPods cache
clean_cocopods_cache() {
  have_cmd pod || return 0
  run_updater "Cleaning CocoaPods cache" pod cache clean --all
}

# Function to update and clean Homebrew packages
update_homebrew() {
  have_cmd brew || return 0
  log "Updating Homebrew packages"
  brew cleanup || true
  brew update || warn "brew update failed; continuing."
  brew upgrade || warn "brew upgrade failed; continuing."
  brew upgrade --cask || true
  brew autoremove 2>/dev/null || true
  brew cleanup || true
  brew doctor || true
}

# Function to update npm packages globally
update_npm() {
  have_cmd npm || return 0
  log "Updating npm packages globally"
  npm update -g || warn "npm update -g failed; continuing."
}

# Function to clean Yarn cache
clean_yarn_cache() {
  have_cmd yarn || return 0
  run_updater "Cleaning Yarn cache" yarn cache clean
}

# Function to update Composer packages globally
update_composer() {
  have_cmd composer || return 0
  log "Updating Composer packages"
  composer self-update || warn "composer self-update failed; continuing."
  composer global update || warn "composer global update failed; continuing."
  composer global dump-autoload || true
}

# Function to update Oh My Zsh (fixed `--unattendand` typo).
update_ohmyzsh() {
  have_cmd omz || return 0
  run_updater "Updating Oh My Zsh" omz update --unattended
}

# Main function to execute all updates
main() {
  log "Starting System Updates" false false

  case "$(os_family)" in
    darwin) update_macos ;;
    linux | wsl)
      update_linux
      update_winget_wsl
      update_snap
      update_flatpak
      ;;
    *) warn "Unknown OS family; skipping OS-level updates." ;;
  esac

  update_nvm
  update_rubygem
  clean_cocopods_cache
  update_homebrew
  update_npm
  clean_yarn_cache
  update_composer
  update_ohmyzsh

  if [ "$_UPDATE_FAILURES" -gt 0 ]; then
    warn "System updates completed with ${_UPDATE_FAILURES} failure(s)."
    return 1
  fi
  log "System Updates Completed"
}

main "$@"
