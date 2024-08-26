#!/usr/bin/env zsh
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
    log "Unsupported package manager. Please install ZSH manually." false
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
  local dir="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/$(basename "$repo")"

  if [[ -d "$dir" ]]; then
    log "Plugin directory $dir already exists. Removing and reinstalling $repo." false
    rm -rf "$dir"
  fi

  git clone "https://github.com/$repo" "$dir"
}

# Activate the specified ZSH plugins in .zshrc
activate_zsh_plugins() {
  local zsh_plugins=("$@")
  case "$OS" in
  Darwin*) sed -i '' -e "s/plugins=(git)/plugins=(${zsh_plugins[*]})/" ~/.zshrc ;;
  Linux*) sed -i "s/plugins=(git)/plugins=(${zsh_plugins[*]})/" ~/.zshrc ;;
  esac
}

# Set up ZSH and install plugins
setup_zsh() {
  local zsh_plugins=()

  if [[ "$OS" == Linux* ]]; then
    install_zsh
  fi

  ## Oh My Zsh (https://ohmyz.sh/)
  ## Enhances the functionality of zsh
  install_oh_my_zsh || {
    log "Failed to install Oh My Zsh." false
    exit 1
  }

  ## ZSH Autosuggestions (https://github.com/zsh-users/zsh-autosuggestion)
  ## Suggests commands as you type based on history and completions
  install_zsh_plugin zsh-users/zsh-autosuggestions || {
    log "Failed to install zsh-autosuggestions." false
    exit 1
  }
  configure_tool "ZSH Autosuggestions" "ZSH_AUTOSUGGEST_STRATEGY=(history completion)"

  ## ZSH Syntax Highlighting (https://github.com/zsh-users/zsh-syntax-highlighting)
  ## Highlights commands as you type for better readabilit
  install_zsh_plugin zsh-users/zsh-syntax-highlighting || {
    log "Failed to install zsh-syntax-highlighting." false
    exit 1
  }
  configure_tool "ZSH Syntax Highlighting" "ZSH_HIGHLIGHT_HIGHLIGHTERS=(main brackets pattern cursor)"

  ## zsh-nvm (https://github.com/lukechilds/zsh-nvm)
  ## Node.js version manager
  install_zsh_plugin lukechilds/zsh-nvm || {
    log "Failed to install zsh-nvm." false
    exit 1
  }

  zsh_plugins=(
    git
    zsh-autosuggestions
    zsh-syntax-highlighting
    zsh-nvm
  )
  activate_zsh_plugins "${zsh_plugins[@]}"

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
  [[ -e $HOMEBREW_PREFIX ]] && /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh)"

  ## Requirements (https://docs.brew.sh/Homebrew-on-Linux#requirements)

  if [[ $OS == Linux* ]]; then
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
  fi

  ## Installation
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  ## Configuration
  case "$OS" in
  Darwin*)
    case "$ARCH" in
    arm64 | aarch64) breweval="\$(/opt/homebrew/bin/brew shellenv)" ;;
    x86_64) breweval="\$(/usr/local/bin/brew shellenv)" ;;
    esac
    ;;
  Linux*) breweval="\$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)" ;;
  esac
  configure_tool "Homebrew" "eval \"$breweval\""

  ## Post-configuration
  source ~/.zshrc
}

# Configure additional tools
configure_tool() {
  echo -e "\n# $1\n$2" >>~/.zshrc
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

  ## lazydocker (https://github.com/jesseduffield/lazydocker)
  # A lazier way to manage everything docker
  tools+=(lazydocker)

  ## lazygit (https://github.com/jesseduffield/lazygit)
  ## Simple terminal UI for git commands
  tools+=(lazygit)

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
  configure_tool "The Fuck" 'eval "$(thefuck --alias)"'

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
  ln -sf "$PWD/alacritty" ~/.config/alacritty
  curl -LO --output-dir ~/.config/alacritty https://github.com/catppuccin/alacritty/raw/main/catppuccin-mocha.toml
  [[ "$OS" != Darwin* ]] && sed -i 's/decorations = "Transparent"/decorations = "None"/' ~/.config/alacritty/alacritty.toml

  ## Configure btop++
  [[ -d ~/.config/btop ]] && rm -rf ~/.config/btop
  ln -sf "$PWD/btop" ~/.config/btop

  ## Configure Starship
  eval "$(starship init zsh)"
  starship preset gruvbox-rainbow -o ~/.config/starship.toml

  ## Configure tmux
  [[ -d ~/.config/tmux ]] && rm -rf ~/.config/tmux
  ln -sf "$PWD/tmux" ~/.config/tmux

  ## Configure Vim
  [[ -d ~/.config/vim ]] && rm -rf ~/.config/vim
  [[ -f ~/.vimrc ]] && rm -rf ~/.vimrc
  mkdir -p ~/.config/vim
  ln -sf "$PWD/vim/.vimrc" ~/.vimrc
  ln -sf "$PWD/vim/plugins" ~/.config/vim/plugins
}

# Main script execution
main() {
  detect_os
  log "️Setting up ZSH" false
  setup_zsh || {
    log "Failed to set up ZSH." false
    exit 1
  }
  log "️Installing node.js"
  install_node || {
    log "Failed to install Node.js." false
    exit 1
  }
  log "️Installing Homebrew"
  install_homebrew || {
    log "Failed to install Homebrew." false
    exit 1
  }
  log "️Installing tools"
  install_tools || {
    log "Failed to install tools." false
    exit 1
  }
  log "️Configuring dotfiles"
  configure_dotfiles || {
    log "Failed to configure dotfiles." false
    exit 1
  }
  log "️Activating ZSH Shell"
  activate_zsh || {
    log "Failed to activate ZSH as the default shell." false
    exit 1
  }
  log "️System setup completed!"
}

main
