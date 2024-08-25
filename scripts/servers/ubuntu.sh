#!/bin/bash

# Function to log messages with a timestamp
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

# Function to update packages
update_packages() {
  local operations=(
    "update"
    "full-upgrade"
    "dist-upgrade"
    "autoremove"
    "autoclean"
  )
  for operation in "${operations[@]}"; do
    sudo apt "$operation" -y
  done
}

# Function to install required packages
install_required_packages() {
  local required_packages=(
    "git"
    "locales"
    "zsh"
  )
  sudo apt install -y "${required_packages[@]}" || {
    log "Failed to install required packages" false true
    exit 1
  }
}

# Function to remove unneeded packages
remove_unneeded_packages() {
  local packages=(
    "bat"
    "btop"
    "duf"
    "fd-find"
    "fzf"
    "lsd"
    "neovim"
    "ripgrep"
    "vim"
    "zoxide"
  )
  sudo apt remove -y "${packages[@]}"
}

# Function to set up unattended upgrades
setup_unattended_upgrades() {
  sudo apt install -y unattended-upgrades
  sed -i 's/\/\/Unattended-Upgrade::Automatic-Reboot "false";/Unattended-Upgrade::Automatic-Reboot "true";/' /etc/apt/apt.conf.d/50unattended-upgrades
  sudo systemctl restart unattended-upgrades.service
}

# Function to clean up Linuxbrew
clean_brew() {
  local brew_folder="/home/linuxbrew"
  if [[ -d $brew_folder ]]; then
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh)" -y -f
    rm -rf "$brew_folder"
  fi
}

setup_brew() {
  local brew_folder=/home/linuxbrew
  local brew_eval="eval \"\$($brew_folder/.linuxbrew/bin/brew shellenv)\""

  clean_brew

  # Install required packages
  local required_packages=(
    "build-essential"
    "procps"
    "curl"
    "file"
    "git"
  )
  sudo apt install -y "${required_packages[@]}"

  # Configure Ruby language on arm64
  if [ "$(uname -m)" = "aarch64" ]; then
    home=/home/ubuntu
    rbenv_eval="eval \"\$($home/.rbenv/bin/rbenv init - zsh)\""
    su -c 'curl -fsSL https://github.com/rbenv/rbenv-installer/raw/HEAD/bin/rbenv-installer | bash' ubuntu
    {
      echo '# rbenv'
      echo "$rbenv_eval"
    } >>$home/.zshrc
    su -c "$rbenv_eval \
      rbenv install 3.1.4 \
      rbenv global 3.1." ubuntu
    brew_eval="$rbenv_eval && $brew_eval"
  fi

  # Enable linuxbrew
  mkdir $brew_folder
  git clone https://github.com/Homebrew/brew $brew_folder/.linuxbrew
  chown -R ubuntu:ubuntu $brew_folder/.linuxbrew

  su -c "$brew_eval && brew update" ubuntu
}

# Function to clean up Nix installation
clean_nix() {
  sudo systemctl stop nix-daemon.service
  sudo systemctl disable nix-daemon.socket nix-daemon.service
  sudo systemctl daemon-reload

  sudo rm -rf /etc/nix /etc/profile.d/nix.sh /etc/tmpfiles.d/nix-daemon.conf /nix

  for i in $(seq 1 32); do
    sudo userdel nixbld$i
  done
  sudo groupdel nixbld

  for file in /etc/zsh/zshrc.backup-before-nix /etc/zshrc.backup-before-nix /etc/bash.bashrc.backup-before-nix /etc/bashrc.backup-before-nix; do
    [[ -e $file ]] && mv $file "${file%.backup-before-nix}"
  done
}

# Function to clean up Nix for a specific user
clean_nix_by_user() {
  local user=$1
  local home=$(eval echo ~$user)

  for dir in "$home/.nix-channels" "$home/.nix-defexpr" "$home/.nix-profile"; do
    [[ -d $dir ]] && rm -rf "$dir"
  done
}

# Function to set up Nix
setup_nix() {
  clean_brew
  clean_nix
  ! command -v nix-env >/dev/null && sh <(curl -L https://nixos.org/nix/install) --daemon --yes
}

# Function to install a Zsh plugin from a GitHub repository
install_zsh_plugin() {
  local repo=$1
  git clone "https://github.com/$repo" "${zsh_custom:-~/.oh-my-zsh/custom}/plugins/$(basename "$repo")"
}

# Function to add code to .zshrc
add_zshrc_code() {
  local comment=$1
  local code=$2
  echo -e "\n# $comment\n$code" >>"$home/.zshrc"
}

# Function to activate Zsh plugins in .zshrc
activate_zsh_plugins() {
  local zsh_plugins=$1
  sed -i "s/plugins=(git)/plugins=($zsh_plugins)/" "$home/.zshrc"
}

install_oh_my_zsh() {
  git clone https://github.com/robbyrussell/oh-my-zsh.git "$home/.oh-my-zsh"
  cp ~/.oh-my-zsh/templates/zshrc.zsh-template "$home/.zshrc"
}

setup_shell_by_user() {
  local user=$1
  local command_prefix="source /etc/zshrc; [[ -e \$HOME/.zshrc ]] && source \$HOME/.zshrc;"

  home=$(eval echo ~$user)
  zsh_custom=$home/.oh-my-zsh/custom

  for file in "$home/.oh-my-zsh" "$home/.zshrc" "$home/.zprofile" "$home/.nvm"; do
    [[ -e $file ]] && rm -rf $file
  done
  command -v thefuck >/dev/null && sudo -H -u $user pip3 uninstall thefuck
  su - "$user" -c "rm \"\$(command -v 'starship')\""

  local nix_packages=(
    # bat (https://github.com/sharkdp/bat)
    "nixpkgs.bat"
    # btop++ (https://github.com/aristocratos/btop)
    "nixpkgs.btop"
    # duf (https://github.com/muesli/duf)
    "nixpkgs.duf"
    # fd (https://github.com/sharkdp/fd)
    "nixpkgs.fd"
    # fastfetch (https://github.com/fastfetch-cli/fastfetch)
    "nixpkgs.fastfetch"
    # fzf (https://github.com/fastfetch-cli/fastfetch)
    "nixpkgs.fzf"
    # lazydocker (https://github.com/jesseduffield/lazydocker)
    "nixpkgs.lazydocker"
    # lazygit (https://github.com/jesseduffield/lazygit)
    "nixpkgs.lazygit"
    # lsd (https://github.com/lsd-rs/lsd)
    "nixpkgs.lsd"
    # ripgrep (https://github.com/BurntSushi/ripgrep)
    "nixpkgs.ripgrep"
    # sd (https://github.com/chmln/sd)
    "nixpkgs.sd"
    # starship (https://github.com/starship/starship)
    "nixpkgs.starship"
    # thefuck (https://github.com/nvbn/thefuck)
    "nixpkgs.thefuck"
    # vim (https://github.com/vim/vim)
    "nixpkgs.vim"
    # zoxide (https://github.com/ajeetdsouza/zoxide)
    "nixpkgs.zoxide"
  )
  su - $user -c "$command_prefix \
    nix-env -iA ${nix_packages[*]}"

  install_oh_my_zsh

  install_zsh_plugin "zsh-users/zsh-autosuggestions"
  add_zshrc_code "ZSH Autosuggestions" "ZSH_AUTOSUGGEST_STRATEGY=(history completion)"

  install_zsh_plugin "zsh-users/zsh-syntax-highlighting"
  add_zshrc_code "ZSH Syntax Highlighting" "ZSH_HIGHLIGHT_HIGHLIGHTERS=(main brackets pattern cursor)"

  install_zsh_plugin "lukechilds/zsh-nvm"

  local zsh_plugins=(
    "git"
    "zsh-autosuggestions"
    "zsh-nvm"
    "zsh-syntax-highlighting"
  )
  activate_zsh_plugins "${zsh_plugins[*]}"

  sed -i 's/# export LANG=en_US.UTF-8/export LANG=en_US.UTF-8/' "$home/.zshrc"
  add_zshrc_code "Locale" "export LC_ALL=en_US.UTF-8"
  add_zshrc_code "Nix Locale" "export LOCALE_ARCHIVE=/usr/lib/locale/locale-archive"

  [[ ! -e $home/.config ]] && su - "$user" -c "mkdir $home/.config"
  for folder in "$home/.config/btop" "$home/.config/vim"; do
    [[ -d "$folder" ]] && rm -rf "$folder"
  done

  # btop++
  ln -sf "$PWD/btop" "$home/.config/btop"

  # fzf
  add_zshrc_code "fzf" "source <(fzf --zsh)"

  # lazydocker
  [ ! -e "$home/.config/lazydocker" ] && su - "$user" -c "mkdir $home/.config/lazydocker"
  echo 'commandTemplates:
  dockerCompose: docker compose' | tee -a "$home/.config/lazydocker/config.yml"

  # lsd
  add_zshrc_code "lsd" "alias l=\"lsd -la\""

  # node
  su - "$user" -c "$command_prefix \
    nvm install --lts --latest-npm \
    && nvm use --lts"

  # Starship
  add_zshrc_code "Starship" "eval \"\$(starship init zsh)\""
  su - "$user" -c "$command_prefix \
    starship preset gruvbox-rainbow -o $home/.config/starship.toml"

  # The Fuck
  add_zshrc_code "The Fuck" "eval \"\$(thefuck --alias)\""

  # zoxide
  add_zshrc_code "Zoxide" "eval \"\$(zoxide init zsh)\""

  # Default Vim settings
  mkdir -p "$home/.config/vim"
  ln -sf "$PWD/vim/plugins" "$home/.config/vim"
  ln -sf "$PWD/vim/.vimrc" "$home/.vimrc"

  # Setting permissions
  if [[ $user != "root" ]]; then
    chown -R "$user":"$user" "$home/"{.config,.oh-my-zsh,.vimrc,.zshrc}
  fi

  # Setting default shell
  chsh -s /bin/zsh "$user"
}

main() {
  local users=("ubuntu" "root")

  log "Updating packages"
  update_packages

  log "Installing required packages"
  install_required_packages

  log "Removing unneeded packages"
  remove_unneeded_packages

  log "Setting up unattended upgrades"
  setup_unattended_upgrades

  log "Cleaning up nix"
  for user in "${users[@]}"; do
    clean_nix_by_user "$user"
  done

  log "Setting up nix"
  setup_nix

  log "Setting up users environment"
  for user in "${users[@]}"; do
    setup_shell_by_user "$user"
  done
}

main "$@"
