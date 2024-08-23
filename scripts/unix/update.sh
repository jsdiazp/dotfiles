#!/bin/zsh
[[ -e ~/.zshrc ]] && source ~/.zshrc

# Functions

title() {
  value=""
  if [[ -n $1 ]]; then
    value="\033[0;35m⚡️$1\033[0m"
  fi
  if [[ -n $1 && ${2:-true} == true ]]; then
    value="\n$value"
  fi
  if [[ -n $1 && ${3:-true} == true ]]; then
    value="$value\n"
  fi
  [[ -n $value ]] && echo $value
}

# System

case "$(uname -s)" in
Darwin*)
  ## softwareupdate
  if command -v softwareupdate >/dev/null; then
    title "macOS" false
    softwareupdate -i -a
  fi
  ;;

Linux*)
  ## apt
  if command -v apt >/dev/null; then
    title "apt" false
    sudo apt update -y
    sudo apt full-upgrade -y
    sudo apt dist-upgrade -y
    sudo apt autoremove -y
    sudo apt autoclean -y
  fi

  ## WinGet (WSL)
  if command -v Winget.exe >/dev/null; then
    title "WinGet" false
    Winget.exe upgrade --all
  fi

  ## Snapcraft
  if command -v snap >/dev/null; then
    title "Snapcraft"
    sudo snap refresh
  fi

  ## Flatpak
  if command -v flatpak >/dev/null; then
    title "Flatpak"
    flatpak update
  fi
  ;;
esac

# Version managers

## NVM
if command -v nvm >/dev/null; then
  title "NVM"
  nvm upgrade
  nvm install --lts --latest-npm
  nvm use --lts
fi

# Package managers

## RubyGem
if command -v gem >/dev/null; then
  title "RubyGem"
  gem cleanup
  gem update
  gem cleanup
fi

## CocoPods
if command -v pod >/dev/null; then
  title "CocoPods" true false
  pod cache clean --all
fi

## Homebrew
if command -v brew >/dev/null; then
  title "Homebrew"
  brew cleanup
  brew update --auto-update
  brew update
  brew upgrade
  brew autoremove
  brew cleanup
  brew doctor
fi

## npm
if command -v npm >/dev/null; then
  title "npm"
  npm cache clean --force
  npm upgrade -g
  npm cache clean --force
fi

## Yarn
if command -v yarn >/dev/null; then
  title "Yarn"
  yarn cache clean
fi

## Composer
if command -v composer >/dev/null; then
  title "Composer"
  composer self-update
  composer global update
  composer global dump-autoload
fi

# Shell

## Oh My Zsh
if command -v omz >/dev/null; then
  title "Oh My Zsh"
  omz update --unattendand
fi
