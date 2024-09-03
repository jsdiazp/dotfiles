#!/usr/bin/env zsh

# Source .zshrc if it exists
[[ -e ~/.zshrc ]] && source ~/.zshrc

# Function to log messages with timestamps
log() {
  local message=$1
  local add_newline_before=${2:-true}
  local add_newline_after=${3:-true}
  local formatted_message=""

  if [[ -n $message ]]; then
    formatted_message="\033[0;35m[$(date +"%Y-%m-%d %H:%M:%S")] ⚡️ $message\033[0m"
    [[ $add_newline_before == true ]] && formatted_message="\n$formatted_message"
    [[ $add_newline_after == true ]] && formatted_message="$formatted_message\n"
    echo -e "$formatted_message"
  fi
}

# Function to update macOS software
update_macos() {
  log "Updating macOS"
  if command -v softwareupdate >/dev/null; then
    softwareupdate -i -a
  fi
}

# Function to update Linux packages
update_linux() {
  log "Updating Linux Packages"
  if command -v apt >/dev/null; then
    sudo apt update -y
    sudo apt full-upgrade -y
    sudo apt dist-upgrade -y
    sudo apt autoremove -y
    sudo apt autoclean -y
  fi
}

# Function to update WinGet packages (for WSL)
update_winget() {
  log "Updating WinGet Packages (WSL)"
  if command -v Winget.exe >/dev/null; then
    Winget.exe upgrade --all
  fi
}

# Function to refresh Snap packages
update_snap() {
  log "Refreshing Snap Packages"
  if command -v snap >/dev/null; then
    sudo snap refresh
  fi
}

# Function to update Flatpak packages
update_flatpak() {
  log "Updating Flatpak Packages"
  if command -v flatpak >/dev/null; then
    flatpak update
  fi
}

# Function to update NVM and install latest Node.js LTS version
update_nvm() {
  log "Updating NVM and Installing Latest Node.js LTS"
  if command -v nvm >/dev/null; then
    nvm upgrade
    nvm install --lts --latest-npm
    nvm use --lts
  fi
}

# Function to update RubyGem packages
update_rubygem() {
  log "Updating RubyGem Packages"
  if command -v gem >/dev/null; then
    gem cleanup
    gem update --system
    gem update
    gem cleanup
  fi
}

# Function to clean CocoPods cache
clean_cocopods_cache() {
  log "Cleaning CocoPods Cache"
  if command -v pod >/dev/null; then
    pod cache clean --all
  fi
}

# Function to update and clean Homebrew packages
update_homebrew() {
  log "Updating Homebrew Packages"
  if command -v brew >/dev/null; then
    brew cleanup
    brew update --auto-update
    brew update
    brew upgrade
    brew autoremove
    brew cleanup
    brew doctor
  fi
}

# Function to update npm packages globally
update_npm() {
  log "Updating npm Packages Globally"
  if command -v npm >/dev/null; then
    npm cache clean --force
    npm upgrade -g
    npm cache clean --force
  fi
}

# Function to clean Yarn cache
clean_yarn_cache() {
  log "Cleaning Yarn Cache"
  if command -v yarn >/dev/null; then
    yarn cache clean
  fi
}

# Function to update Composer packages globally
update_composer() {
  log "Updating Composer Packages"
  if command -v composer >/dev/null; then
    composer self-update
    composer global update
    composer global dump-autoload
  fi
}

# Function to update Oh My Zsh
update_ohmyzsh() {
  log "Updating Oh My Zsh"
  if command -v omz >/dev/null; then
    omz update --unattendand
  fi
}

# Main function to execute all updates
main() {
  log "Starting System Updates" false

  case "$(uname -s)" in
  Darwin*)
    update_macos
    ;;
  Linux*)
    update_linux
    update_winget
    update_snap
    update_flatpak
    ;;
  esac

  update_nvm
  update_rubygem
  clean_cocopods_cache
  update_homebrew
  update_npm
  clean_yarn_cache
  update_composer
  update_ohmyzsh

  log "System Updates Completed"
}

# Execute the main function
main
