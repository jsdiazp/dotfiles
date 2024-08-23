#!/bin/bash
# Shell
# Interface to interact with the operating system

# ZSH

## Installation

### Debian or Ubuntu
if [[ "$(uname -s)" == Linux* ]] && command -v apt >/dev/null; then
  sudo apt update
  sudo apt install -y zsh
fi

### Fedora, CentOS, or Red Hat
if [[ "$(uname -s)" == Linux* ]] && command -v yum >/dev/null; then
  sudo yum update
  sudo yum install -y zsh
fi

# Oh My Zsh (https://ohmyz.sh/)
# Enhances the functionality of zsh

## Pre-configuration
[[ -e ~/.oh-my-zsh ]] && rm -rf ~/.oh-my-zsh
[[ -e ~/.zshrc ]] && rm ~/.zshrc
[[ -e ~/.zprofile ]] && rm -rf ~/.zprofile

## Installation
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended

## ZSH Autosuggestions (https://github.com/zsh-users/zsh-autosuggestion)
## Suggests commands as you type based on history and completions

### Installation
git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions

### Configuration
{
  echo '\n# ZSH Autosuggestions'
  echo 'ZSH_AUTOSUGGEST_STRATEGY=(history completion)\n'
} >>~/.zshrc

## ZSH Syntax Highlighting (https://github.com/zsh-users/zsh-syntax-highlighting)
## Command highlighting

### Installation
git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting

### Configuration
{
  echo '# ZSH Syntax Highlighting'
  echo 'ZSH_HIGHLIGHT_HIGHLIGHTERS=(main brackets pattern cursor)\n'
} >>~/.zshrc

## Activation of ZSH plugins
case "$(uname -s)" in
Darwin*)
  sed -i'' -e 's/plugins=(git)/plugins=(git zsh-autosuggestions zsh-syntax-highlighting zsh-nvm)/' ~/.zshrc
  ;;
Linux*)
  sed -i 's/plugins=(git)/plugins=(git zsh-autosuggestions zsh-syntax-highlighting zsh-nvm)/' ~/.zshrc
  ;;
esac

# zsh-nvm (https://github.com/lukechilds/zsh-nvm)
# Node.js version manager

## Installation
git clone https://github.com/lukechilds/zsh-nvm ~/.oh-my-zsh/custom/plugins/zsh-nvm

## Activation
source ~/.zshrc
nvm install --lts --latest-npm
nvm use --lts

# Homebrew (https://brew.sh)
# Package manager

## Pre-configuration
[[ -e $HOMEBREW_PREFIX ]] && /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh)" -y

## Requirements (https://docs.brew.sh/Homebrew-on-Linux#requirements)

### Debian or Ubuntu
if [[ "$(uname -s)" == Linux* ]] && command -v apt >/dev/null; then
  sudo apt install -y build-essential procps curl file git
fi

### Fedora, CentOS, or Red Hat
if [[ "$(uname -s)" == Linux* ]] && command -v yum >/dev/null; then
  sudo yum groupinstall -y 'Development Tools'
  sudo yum install -y procps-ng curl file git
fi

## Installation
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" -y

## Configuration
echo '# Hombebrew' >>~/.zshrc
case "$(uname -s)" in
Darwin*)
  case "$(uname -m)" in
  arm64 | aarch64)
    breweval="\$(/opt/homebrew/bin/brew shellenv)"
    ;;
  x86_64)
    breweval="\$(/usr/local/bin/brew shellenv)"
    ;;
  esac
  ;;
Linux*)
  breweval="\$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
  ;;
esac
echo "eval \"$breweval\"\n" >>~/.zshrc

## Post-configuration
source ~/.zshrc

# Alacritty (https://github.com/alacritty/alacritty)

## Theme
mkdir -p ~/.config/alacritty
curl -LO --output-dir ~/.config/alacritty https://github.com/catppuccin/alacritty/raw/main/catppuccin-mocha.toml

# Bat (https://github.com/sharkdp/bat)
# Displays the content of a file highlighted and formatted
brew install bat

# btop++ (https://github.com/aristocratos/btop)
# Resource monitor

# Installation
brew instal btop

# Bun (https://github.com/oven-sh/bun)
# JavaScript runtime

## Installation
brew tap oven-sh/bun
brew install bun

# fd (https://github.com/sharkdp/fd)
# Simple, fast, and user-friendly alternative to "find"

## Installation
brew install fd

# fzf (https://github.com/junegunn/fzf)
# Improves the functionality of <C-r> and <C-t>

## Installation
brew install fzf

## Configuration
{
  echo '# fzf'
  echo 'source <(fzf --zsh)\n'
} >>~/.zshrc
$HOMEBREW_PREFIX/opt/fzf/install --all

# lsd (https://github.com/lsd-rs/lsd)
# Next-generation 'ls' command
brew install lsd

# fastfetch (https://github.com/fastfetch-cli/fastfetch)
# Displays system information
brew install fastfetch

# ripgrep (https://github.com/BurntSushi/ripgrep)
# Recursively searches directories for a regex pattern respecting gitignore
brew install ripgrep

# Starship (https://starship.rs)
# Improves the terminal prompt (input interface)

## Installation
brew install starship

## Configuration
{
  echo '# Starship'
  echo 'eval "$(starship init zsh)"\n'
} >>~/.zshrc

## Pre-adjustments
eval "$(starship init zsh)"
[[ ! -e ~/.config ]] && mkdir ~/.config
starship preset gruvbox-rainbow -o ~/.config/starship.toml

# The Fuck (https://github.com/nvbn/thefuck)
# Suggests corrections for the previous command

## Installation
brew install thefuck

## Configuration
{
  echo '# The Fuck'
  echo 'eval $(thefuck --alias)\n'
} >>~/.zshrc

# tmux (https://github.com/tmux/tmux)
# Terminal multiplexer

# Pre-configuration
[[ -e ~/.tmux ]] && rm -rf ~/.tmux

## Installation
brew install tmux

## Configuration
{
  echo '# tmux'
  echo 'alias tm="tmux attach || tmux"\n'
} >>~/.zshrc

## tpm
git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm

# zoxide (https://github.com/ajeetdsouza/zoxide)
# Smarter cd command, inspired by z and autojump

## Installation
brew install zoxide

## Configuration
{
  echo '# zoxide'
  echo 'eval "$(zoxide init zsh)"\n'
} >>~/.zshrc

# dotfiles

## Alacritty
ln -sf alacritty ~/.config/alacritty
[[ "$(uname -s)" != Darwin* ]] && sed -i 's/decorations = "Transparent"/decorations = "None"/' ~/.config/alacritty/alacritty.toml

## tmux
ln -sf tmux ~/.config/tmux

## Vim
mkdir -p ~/.config/vim
ln -sf vim/.vimrc ~/.vimrc
ln -sf vim/plugins ~/.config/vim/plugins

# Activate zsh shell
chsh -s /bin/zsh
source ~/.zshrc
