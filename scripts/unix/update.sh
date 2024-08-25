#!/bin/zsh

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
  if command -v softwareupdate >/dev/null; then
    softwareupdate -i -a
  fi
}

# Function to update Linux packages
update_linux() {
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
  if command -v Winget.exe >/dev/null; then
    Winget.exe upgrade --all
  fi
}

# Function to refresh Snap packages
update_snap() {
  if command -v snap >/dev/null; then
    sudo snap refresh
  fi
}

# Function to update Flatpak packages
update_flatpak() {
  if command -v flatpak >/dev/null; then
    flatpak update
  fi
}

# Function to update NVM and install latest Node.js LTS version
update_nvm() {
  if command -v nvm >/dev/null; then
    nvm upgrade
    nvm install --lts --latest-npm
    nvm use --lts
  fi
}

# Function to update RubyGem packages
update_rubygem() {
  if command -v gem >/dev/null; then
    gem cleanup
    gem update
    gem cleanup
  fi
}

# Function to clean CocoPods cache
clean_cocopods_cache() {
  if command -v pod >/dev/null; then
    pod cache clean --all
  fi
}

# Function to update and clean Homebrew packages
update_homebrew() {
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
  if command -v npm >/dev/null; then
    npm cache clean --force
    npm upgrade -g
    npm cache clean --force
  fi
}

# Function to clean Yarn cache
clean_yarn_cache() {
  if command -v yarn >/dev/null; then
    yarn cache clean
  fi
}

# Function to update Composer packages globally
update_composer() {
  if command -v composer >/dev/null; then
    composer self-update
    composer global update
    composer global dump-autoload
  fi
}

# Function to update Oh My Zsh
update_ohmyzsh() {
  if command -v omz >/dev/null; then
    omz update --unattendand
  fi
}

# Main function to execute all updates
main() {
  log "Starting System Updates" false

  case "$(uname -s)" in
  Darwin*)
    log "Updating macOS"
    update_macos
    ;;
  Linux*)
    log "Updating Linux Packages"
    update_linux
    log "Updating WinGet Packages (WSL)"
    update_winget
    log "Refreshing Snap Packages"
    update_snap
    log "Updating Flatpak Packages"
    update_flatpak
    ;;
  esac

  log "Updating NVM and Installing Latest Node.js LTS"
  update_nvm
  log "Updating RubyGem Packages"
  update_rubygem
  log "Cleaning CocoPods Cache"
  clean_cocopods_cache
  log "Updating Homebrew Packages"
  update_homebrew
  log "Updating npm Packages Globally"
  update_npm
  log "Cleaning Yarn Cache"
  clean_yarn_cache
  log "Updating Composer Packages"
  update_composer
  log "Updating Oh My Zsh"
  update_ohmyzsh

  log "System Updates Completed"
}

# Execute the main function
main
