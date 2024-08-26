#!/bin/zsh
# Shell
# Interface to interact with the operating system

# Log messages with timestamps
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

# Detect the operating system and architecture
detect_os() {
  OS="$(uname -s)"
  ARCH="$(uname -m)"
}

# Install ZSH based on the package manager
install_zsh() {
  if command -v apt >/dev/null; then
    sudo apt update
    sudo apt install -y zsh
  elif command -v yum >/dev/null; then
    sudo yum update
    sudo yum install -y zsh
  else
    echo "Unsupported package manager. Please install ZSH manually."
    exit 1
  fi
}

# Install Oh My Zsh
install_oh_my_zsh() {
  [[ -d ~/.oh-my-zsh ]] && rm -rf ~/.oh-my-zsh
  [[ -f ~/.zshrc ]] && rm ~/.zshrc
  [[ -f ~/.zprofile ]] && rm -rf ~/.zprofile
  sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
}

# Install ZSH Plugin
install_zsh_plugin() {
  local repo="$1"
  local dir="${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/$(basename "$repo")"
  if [[ ! -d "$dir" ]]; then
    git clone "https://github.com/$repo" "$dir"
  fi
}

# Configure a ZSH plugin by appending settings to .zshrc
configure_zsh_plugin() {
  echo -e "\n# $1\n$2\n" >>~/.zshrc
}

# Activate the specified ZSH plugins in .zshrc
activate_zsh_plugins() {
  local plugins=("$@")
  case "$OS" in
  macOS) sed -i '' -e "s/plugins=(git)/plugins=(${plugins[*]})/" ~/.zshrc ;;
  Linux) sed -i "s/plugins=(git)/plugins=(${plugins[*]})/" ~/.zshrc ;;
  esac
}

# Set up ZSH and install plugins
setup_zsh() {
  local plugins=()

  install_zsh

  ## Oh My Zsh (https://ohmyz.sh/)
  ## Enhances the functionality of zsh
  install_oh_my_zsh

  ## ZSH Autosuggestions (https://github.com/zsh-users/zsh-autosuggestion)
  ## Suggests commands as you type based on history and completions
  install_zsh_plugin zsh-users/zsh-autosuggestions
  configure_zsh_plugin "ZSH Autosuggestions" "ZSH_AUTOSUGGEST_STRATEGY=(history completion)"

  ## ZSH Syntax Highlighting (https://github.com/zsh-users/zsh-syntax-highlighting)
  ## Highlights commands as you type for better readabilit
  install_zsh_plugin zsh-users/zsh-syntax-highlighting
  configure_zsh_plugin "ZSH Syntax Highlighting" "ZSH_HIGHLIGHT_HIGHLIGHTERS=(main brackets pattern cursor)"

  ## zsh-nvm (https://github.com/lukechilds/zsh-nvm)
  ## Node.js version manager
  install_zsh_plugin lukechilds/zsh-nvm

  plugins=(
    git
    zsh-autosuggestions
    zsh-syntax-highlighting
    zsh-nvm
  )
  activate_zsh_plugins "${plugins[@]}"

  source ~/.zshrc
}

# Activate ZSH as the default shell
activate_zsh() {
  chsh -s /bin/zsh
  source ~/.zshrc
}

# Install node.js (https://github.com/nodejs/node)
# JavaScript runtime
install_node() {
  nvm install --lts --latest-npm
  nvm use --lts
}

# Install Homebrew (https://brew.sh)
# Package manager
install_homebrew() {
  local breweval=""
  local packages=()

  ## Uninstall any existing Homebrew
  [[ -e $HOMEBREW_PREFIX ]] && /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh)" -y

  ## Requirements (https://docs.brew.sh/Homebrew-on-Linux#requirements)

  ### Debian or Ubuntu
  if command -v apt >/dev/null; then
    packages=(
      build-essential
      curl
      file
      git
      procps
    )
    sudo apt install -y "${packages[@]}"
  fi

  ### Fedora, CentOS, or Red Hat
  if command -v yum >/dev/null; then
    packages=(
      curl
      file
      git
      procps-ng
    )
    sudo yum groupinstall -y 'Development Tools'
    sudo yum install -y "${packages[@]}"
  fi

  ## Installation
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" -y

  ## Configuration
  echo '# Hombebrew' >>~/.zshrc
  case "$OS" in
  Darwin*)
    case "$ARCH" in
    arm64 | aarch64) breweval="\$(/opt/homebrew/bin/brew shellenv)" ;;
    x86_64) breweval="\$(/usr/local/bin/brew shellenv)" ;;
    esac
    ;;
  Linux*) breweval="\$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)" ;;
  esac
  echo "eval \"$breweval\"\n" >>~/.zshrc

  ## Post-configuration
  source ~/.zshrc
}

# Configure additional tools
configure_tool() {
  echo -e "\n# $1\n$2\n" >>~/.zshrc
}

# Install additional tools
install_tools() {
  local tools=()

  ## Bat (https://github.com/sharkdp/bat)
  ## Displays the content of a file highlighted and formatted
  tools+=(bat)

  ## btop++ (https://github.com/aristocratos/btop)
  ## Resource monitor
  tools+=(btop)

  ## Bun (https://github.com/oven-sh/bun)
  ## JavaScript runtime
  brew tap oven-sh/bun
  tools+=(bun)

  ## fastfetch (https://github.com/fastfetch-cli/fastfetch)
  ## Displays system information
  tools+=(fastfetch)

  ## fd (https://github.com/sharkdp/fd)
  ## Simple, fast, and user-friendly alternative to "find"
  tools+=(fd)

  ## fzf (https://github.com/junegunn/fzf)
  ## Improves the functionality of <C-r> and <C-t>
  tools+=(fzf)
  configure_tool "fzf" "source <(fzf --zsh)"

  ## lsd (https://github.com/lsd-rs/lsd)
  ## Next-generation 'ls' command
  tools+=(lsd)

  ## ripgrep (https://github.com/BurntSushi/ripgrep)
  ## Recursively searches directories for a regex pattern respecting gitignore
  tools+=(ripgrep)

  ## Starship (https://starship.rs)
  ## Improves the terminal prompt (input interface)
  tools+=(starship)
  configure_tool "starship" 'eval "$(starship init zsh)"'

  ## The Fuck (https://github.com/nvbn/thefuck)
  ## Suggests corrections for the previous command
  tools+=(thefuck)
  configure_tool "The Fuck" 'eval $(thefuck --alias)'

  ## tmux (https://github.com/tmux/tmux)
  ## Terminal multiplexer
  tools+=(tmux)
  configure_tool "tmux" 'alias tm="tmux attach || tmux"'

  ## tpm (https://github.com/tmux-plugins/tpm)
  ## tmux Plugin Manager
  git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm

  ## Vim (https://github.com/vim/vim)
  ## Text editor
  tools+=(vim)

  ## zoxide (https://github.com/ajeetdsouza/zoxide)
  ## Smarter cd command, inspired by z and autojump
  tools+=(zoxide)
  configure_tool "zoxide" 'eval "$(zoxide init zsh)"'

  brew install "${tools[@]}"
}

# Configure dotfiles and related tools
configure_dotfiles() {
  [[ ! -d ~/.config ]] && mkdir ~/.config

  ## Configure Alacritty
  [[ -d ~/.config/alacritty ]] && rm -rf ~/.config/alacritty
  ln -sf alacritty ~/.config/alacritty
  curl -LO --output-dir ~/.config/alacritty https://github.com/catppuccin/alacritty/raw/main/catppuccin-mocha.toml
  [[ "$OS" != Darwin* ]] && sed -i 's/decorations = "Transparent"/decorations = "None"/' ~/.config/alacritty/alacritty.toml

  ## Configure btop++
  ln -sf btop ~/.config/btop

  ## Configure Starship
  eval "$(starship init zsh)"
  starship preset gruvbox-rainbow -o ~/.config/starship.toml

  ## Configure tmux
  [[ -d ~/.config/tmux ]] && rm -rf ~/.config/tmux
  ln -sf tmux ~/.config/tmux

  ## Configure Vim
  [[ -d ~/.config/vim ]] && rm -rf ~/.config/vim
  [[ -f ~/.vimrc ]] && rm -rf ~/.vimrc
  mkdir -p ~/.config/vim
  ln -sf vim/.vimrc ~/.vimrc
  ln -sf vim/plugins ~/.config/vim/plugins
}

# Main script execution
main() {
  detect_os
  log "️Setting up ZSH" false
  setup_zsh
  log "️Installing node.js"
  install_node
  log "️Installing Homebrew"
  install_homebrew
  log "️Installing tools"
  install_tools
  log "️Configuring dotfiles"
  configure_dotfiles
  log "️Activating ZSH Shell"
  activate_zsh
  log "️System setup completed!"
}

main
