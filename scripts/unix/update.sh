#!/usr/bin/env bash
# update.sh — update OS packages and language/tooling ecosystems.
#
# Patterns:
#   - Registry of updaters: every `update_*` / `clean_*` function checks its
#     own tool with `have_cmd` and returns 0 (ok), 2 (skip) or 1 (failed).
#   - One line per ecosystem in main(): `run_step_soft "<Label>" <updater>`.
#     run_step_soft captures output (spinner on TTYs, streamed at info/debug),
#     records exactly ONE summary row, and never aborts the run — so one
#     failing ecosystem cannot stop the others.
#   - Multi-command updaters keep going after a sub-failure and return
#     non-zero at the end; failure totals come from the summary table.
#   - No sourcing of ~/.zshrc (slow, side-effectful in automation).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../shared/common.sh"

# --- OS updaters ------------------------------------------------------------

# Function to update macOS software
update_macos() {
  have_cmd softwareupdate || return 2
  as_root softwareupdate -i -a
}

# Function to upgrade Mac App Store apps via mas (https://github.com/mas-cli/mas)
# Needs `brew install mas` plus an Apple Account sign-in for owned apps;
# mas requests root privileges itself when an upgrade needs them.
update_mas() {
  have_cmd mas || return 2
  mas upgrade
}

# Function to update Linux packages
update_linux() {
  local rc=0
  have_cmd apt-get || return 2
  # NOTE: `apt-get update` takes no -y; full-upgrade/dist-upgrade are the
  # same operation — run once.
  as_root apt-get update || {
    warn "apt-get update failed; continuing."
    rc=1
  }
  as_root apt-get full-upgrade -y || {
    warn "apt-get full-upgrade failed; continuing."
    rc=1
  }
  as_root apt-get autoremove -y || {
    warn "apt-get autoremove failed; continuing."
    rc=1
  }
  as_root apt-get autoclean -y || {
    warn "apt-get autoclean failed; continuing."
    rc=1
  }
  return "$rc"
}

# WSL only: update Windows packages via WinGet interop.
update_winget_wsl() {
  case "$(os_family)" in
    wsl) : ;;
    *) return 2 ;;
  esac
  if have_cmd winget.exe; then
    winget.exe upgrade --all --silent
  elif have_cmd Winget.exe; then
    Winget.exe upgrade --all --silent
  else
    return 2
  fi
}

# Function to refresh Snap packages
update_snap() {
  have_cmd snap || return 2
  as_root snap refresh
}

# Function to update Flatpak packages
update_flatpak() {
  have_cmd flatpak || return 2
  flatpak update -y
}

# --- Ecosystem updaters -----------------------------------------------------

# Function to update NVM and install latest Node.js LTS version
update_nvm() {
  local rc=0
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
  nvm install --lts --latest-npm || {
    warn "nvm install --lts failed; continuing."
    rc=1
  }
  nvm use --lts || true
  return "$rc"
}

# Function to update RubyGem packages
update_rubygem() {
  local rc=0
  have_cmd gem || return 2
  gem update --system || {
    warn "gem update --system failed; continuing."
    rc=1
  }
  gem update || {
    warn "gem update failed; continuing."
    rc=1
  }
  gem cleanup || true
  return "$rc"
}

# Function to clean CocoPods cache
clean_cocopods_cache() {
  have_cmd pod || return 2
  pod cache clean --all
}

# Function to update and clean Homebrew packages
update_homebrew() {
  local rc=0
  have_cmd brew || return 2
  # `brew upgrade` already upgrades casks, so no separate `--cask` pass.
  brew update || {
    warn "brew update failed; continuing."
    rc=1
  }
  brew upgrade || {
    warn "brew upgrade failed; continuing."
    rc=1
  }
  # Housekeeping is best-effort: a failed autoremove/cleanup must not fail the run.
  brew autoremove || warn "brew autoremove failed; continuing."
  brew cleanup || warn "brew cleanup failed; continuing."
  # `brew doctor` is noisy and only useful while debugging.
  case "${DOTFILES_LOG_LEVEL:-warn}" in
    debug | info) brew doctor || true ;;
  esac
  return "$rc"
}

# Function to update npm packages globally
update_npm() {
  have_cmd npm || return 2
  npm update -g
}

# Function to clean Yarn cache
clean_yarn_cache() {
  have_cmd yarn || return 2
  yarn cache clean
}

# Function to update Composer packages globally
update_composer() {
  local rc=0
  have_cmd composer || return 2
  composer self-update || {
    warn "composer self-update failed; continuing."
    rc=1
  }
  composer global update || {
    warn "composer global update failed; continuing."
    rc=1
  }
  composer global dump-autoload || true
  return "$rc"
}

# Function to update Oh My Zsh via upgrade.sh directly (`omz update` is for
# interactive shells; `omz update --unattended` was removed upstream and now
# errors — see lib/cli.zsh — so scripts must call upgrade.sh per the FAQ).
update_ohmyzsh() {
  local omz_dir omz_upgrade
  omz_dir="${ZSH:-$HOME/.oh-my-zsh}"
  omz_upgrade="$omz_dir/tools/upgrade.sh"
  if [ ! -f "$omz_upgrade" ]; then
    info "Skipping Oh My Zsh update (not installed at $omz_dir)."
    return 2
  fi
  have_cmd zsh || return 2
  have_cmd git || return 2
  env "ZSH=$omz_dir" zsh -f "$omz_upgrade"
}

# Main function to execute all updates
main() {
  local family
  log "Starting System Updates" false false

  family="$(os_family)"
  case "$family" in
    darwin | linux | wsl)
      # Warm sudo once, up front: prompts must not appear behind a spinner.
      sudo_warm || warn "sudo unavailable; privileged steps may fail."
      ;;
  esac

  case "$family" in
    darwin)
      run_step_soft "macOS" update_macos
      run_step_soft "Mac App Store" update_mas
      ;;
    linux | wsl)
      run_step_soft "Linux packages" update_linux
      run_step_soft "WinGet (WSL)" update_winget_wsl
      run_step_soft "Snap" update_snap
      run_step_soft "Flatpak" update_flatpak
      ;;
    *) warn "Unknown OS family; skipping OS-level updates." ;;
  esac

  run_step_soft "Node.js (nvm)" update_nvm
  run_step_soft "RubyGems" update_rubygem
  run_step_soft "CocoaPods cache" clean_cocopods_cache
  run_step_soft "Homebrew" update_homebrew
  run_step_soft "npm" update_npm
  run_step_soft "Yarn cache" clean_yarn_cache
  run_step_soft "Composer" update_composer
  run_step_soft "Oh My Zsh" update_ohmyzsh

  print_summary "Update summary"

  if [ "${SUMMARY_FAILED:-0}" -gt 0 ]; then
    warn "System updates completed with ${SUMMARY_FAILED} failure(s)."
    return 1
  fi
  log "System Updates Completed"
}

main "$@"
