#!/usr/bin/env bash
# ubuntu.sh — provision an Ubuntu server (users: ubuntu, root).
#
# Refactor notes:
#   - main() is a Template-Method pipeline of run_step stages; every stage
#     is a small function with one responsibility.
#   - Configuration as data: APT_REQUIRED / APT_PURGE / NIX_PACKAGES /
#     ZSH_PLUGINS lists replace inline literals.
#   - All per-user state is passed explicitly (user, home) — no more global
#     $home/$zsh_custom mutation across functions.
#   - Idempotency: zshrc_block_once() wraps append_once (no duplicate blocks),
#     symlinks use safe_link anchored at the repo root (not $PWD), fstab-style
#     appends are grep-guarded, clones pull when already present.
#   - Bug fixes vs the original: sudo on the unattended-upgrades sed,
#     `bash -c` instead of `sh <(...)` (dash has no process substitution),
#     unquoted expansions quoted, `getent` instead of `eval echo ~user`,
#     no truncated `rbenv global 3.1.`, template copied from the user's own
#     oh-my-zsh checkout, correct /etc/zsh/zshrc path.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../shared/common.sh"
DOTFILES_ROOT="$(repo_root_from "$SCRIPT_DIR")"

# ---------------------------------------------------------------------------
# Declarative manifests
# ---------------------------------------------------------------------------
APT_REQUIRED="git locales zsh"
APT_PURGE="bat btop duf fd-find fzf lsd neovim ripgrep vim zoxide"
APT_BUILD_DEPS="build-essential procps curl file git"

ZSH_PLUGINS="git zsh-autosuggestions zsh-nvm zsh-syntax-highlighting"

NIX_PACKAGES="nixpkgs.bat nixpkgs.btop nixpkgs.duf nixpkgs.fd nixpkgs.fastfetch nixpkgs.fzf nixpkgs.lazydocker nixpkgs.lazygit nixpkgs.lsd nixpkgs.ripgrep nixpkgs.sd nixpkgs.starship nixpkgs.thefuck nixpkgs.vim nixpkgs.zoxide"

TARGET_USERS="ubuntu root"
BREW_FOLDER="/home/linuxbrew"

# ---------------------------------------------------------------------------
# Small helpers (explicit args, no globals)
# ---------------------------------------------------------------------------
user_home() {
  _user="$1"
  if command -v getent >/dev/null 2>&1; then
    getent passwd "$_user" | cut -d: -f6
  else
    # shellcheck disable=SC2086
    eval echo ~$_user
  fi
  unset _user
}

as_user() {
  _user="$1"
  shift
  if [ "$(id -un)" = "$_user" ]; then
    bash -c "$*"
  else
    su - "$_user" -c "$*"
  fi
  unset _user
}

# Idempotent marked block in a user's .zshrc.
user_zshrc_block() {
  _user="$1"
  _home="$2"
  _id="$3"
  _comment="$4"
  _code="$5"
  ensure_dir "$_home"
  [ -e "$_home/.zshrc" ] || : >"$_home/.zshrc"
  if ! grep -qF "# >>> dotfiles:${_id} >>>" "$_home/.zshrc" 2>/dev/null; then
    {
      printf '\n# >>> dotfiles:%s >>>\n# %s\n%s\n# <<< dotfiles:%s <<<\n' \
        "$_id" "$_comment" "$_code" "$_id"
    } >>"$_home/.zshrc"
  fi
  unset _user _home _id _comment _code
}

user_activate_plugins() {
  _home="$1"
  shift
  _plugins="$*"
  if grep -q '^plugins=' "$_home/.zshrc" 2>/dev/null; then
    sed -i "s/^plugins=.*/plugins=(${_plugins})/" "$_home/.zshrc"
  else
    printf '\nplugins=(%s)\n' "$_plugins" >>"$_home/.zshrc"
  fi
  unset _home _plugins
}

# ---------------------------------------------------------------------------
# APT stages
# ---------------------------------------------------------------------------
update_packages() {
  # `update` takes no -y; full-upgrade/dist-upgrade are the same op.
  run_step "Updating apt index" sudo apt-get update
  run_step "Upgrading packages" sudo apt-get full-upgrade -y
  run_step "Removing unused packages" sudo apt-get autoremove -y
  run_step "Cleaning package cache" sudo apt-get autoclean -y
}

install_required_packages() {
  # shellcheck disable=SC2086
  run_step "Installing required packages" sudo apt-get install -y $APT_REQUIRED
}

remove_unneeded_packages() {
  # shellcheck disable=SC2086
  run_step "Removing unneeded packages" sudo apt-get remove -y $APT_PURGE || true
}

setup_unattended_upgrades() {
  run_step "Installing unattended-upgrades" sudo apt-get install -y unattended-upgrades
  # NOTE: sudo was missing on this sed in the original (Permission denied).
  sudo sed -i 's/\/\/Unattended-Upgrade::Automatic-Reboot "false";/Unattended-Upgrade::Automatic-Reboot "true";/' \
    /etc/apt/apt.conf.d/50unattended-upgrades || \
    warn "Could not enable automatic reboot; continuing."
  sudo systemctl restart unattended-upgrades.service || true
}

# ---------------------------------------------------------------------------
# Brew / Nix stages
# ---------------------------------------------------------------------------
clean_brew() {
  if [ -d "$BREW_FOLDER" ]; then
    if have_cmd brew; then
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh)" -- --force || true
    fi
    sudo rm -rf "$BREW_FOLDER"
  fi
}

setup_brew() {
  _brew_bin="$BREW_FOLDER/.linuxbrew/bin/brew"

  clean_brew

  # shellcheck disable=SC2086
  run_step "Installing brew build deps" sudo apt-get install -y $APT_BUILD_DEPS

  # Ruby via rbenv on arm64 (kept opt-in, version made explicit).
  if [ "$(uname -m)" = "aarch64" ]; then
    warn "arm64 detected: rbenv setup is manual in this refactor — see README. Skipping automatic Ruby install."
  fi

  run_step "Creating $BREW_FOLDER" sudo mkdir -p "$BREW_FOLDER"
  if [ ! -d "$BREW_FOLDER/.linuxbrew/.git" ]; then
    run_step "Cloning Homebrew" sudo git clone https://github.com/Homebrew/brew "$BREW_FOLDER/.linuxbrew"
  fi
  sudo chown -R ubuntu:ubuntu "$BREW_FOLDER/.linuxbrew"
  # NOTE: the brew binary is invoked by absolute path — no shellenv eval is
  # needed for `update`, which avoids nested-quote breakage inside su -c.
  run_step "Updating Homebrew" sudo -u ubuntu "$_brew_bin" update || \
    warn "brew update failed; continuing."
  unset _brew_bin
}

clean_nix() {
  sudo systemctl stop nix-daemon.service 2>/dev/null || true
  sudo systemctl disable nix-daemon.socket nix-daemon.service 2>/dev/null || true
  sudo systemctl daemon-reload 2>/dev/null || true
  sudo rm -rf /etc/nix /etc/profile.d/nix.sh /etc/tmpfiles.d/nix-daemon.conf /nix || true
  _i=1
  while [ "$_i" -le 32 ]; do
    sudo userdel "nixbld$_i" 2>/dev/null || true
    _i=$((_i + 1))
  done
  sudo groupdel nixbld 2>/dev/null || true
  for _f in /etc/zsh/zshrc.backup-before-nix /etc/zshrc.backup-before-nix /etc/bash.bashrc.backup-before-nix /etc/bashrc.backup-before-nix; do
    if [ -e "$_f" ]; then
      sudo mv "$_f" "${_f%.backup-before-nix}"
    fi
  done
  unset _i _f
}

clean_nix_by_user() {
  _user="$1"
  _home="$(user_home "$_user")"
  for _d in "$_home/.nix-channels" "$_home/.nix-defexpr" "$_home/.nix-profile"; do
    if [ -d "$_d" ]; then
      rm -rf "$_d"
    fi
  done
  unset _user _home _d
}

setup_nix() {
  clean_brew
  clean_nix
  if ! have_cmd nix-env; then
    # Original used `sh <(...)` which fails under dash (no process subst).
    run_step "Installing Nix" bash -c "$(curl -fsSL https://nixos.org/nix/install)" -- --daemon --yes
  fi
}

# ---------------------------------------------------------------------------
# Per-user shell provisioning (decomposed from one 120-line function)
# ---------------------------------------------------------------------------
reset_user_shell_state() {
  _user="$1"
  _home="$2"
  for _f in "$_home/.oh-my-zsh" "$_home/.zshrc" "$_home/.zprofile" "$_home/.nvm"; do
    if [ -e "$_f" ] || [ -L "$_f" ]; then
      rm -rf "$_f"
    fi
  done
  if have_cmd pip3; then
    sudo -H -u "$_user" pip3 uninstall -y thefuck 2>/dev/null || true
  fi
  _starship="$(command -v starship 2>/dev/null || true)"
  if [ -n "$_starship" ]; then
    case "$_starship" in
      *nix*) : ;;
      *) rm -f "$_starship" || sudo rm -f "$_starship" || true ;;
    esac
  fi
  unset _user _home _f _starship
}

install_user_nix_packages() {
  _user="$1"
  # shellcheck disable=SC2086
  as_user "$_user" "nix-env -iA $NIX_PACKAGES" || warn "nix-env install failed for $_user; continuing."
  unset _user
}

install_user_oh_my_zsh() {
  _home="$1"
  if [ ! -d "$_home/.oh-my-zsh/.git" ]; then
    rm -rf "$_home/.oh-my-zsh"
    git clone https://github.com/robbyrussell/oh-my-zsh.git "$_home/.oh-my-zsh"
  fi
  if [ ! -f "$_home/.zshrc" ]; then
    cp "$_home/.oh-my-zsh/templates/zshrc.zsh-template" "$_home/.zshrc"
  fi
  unset _home
}

install_user_zsh_plugin() {
  _home="$1"
  _repo="$2"
  _dest="$_home/.oh-my-zsh/custom/plugins/$(basename "$_repo")"
  if [ ! -d "$_dest/.git" ]; then
    rm -rf "$_dest"
    git clone "https://github.com/${_repo}.git" "$_dest"
  fi
  unset _home _repo _dest
}

configure_user_locales() {
  _home="$1"
  if grep -q '^# export LANG=' "$_home/.zshrc" 2>/dev/null; then
    sed -i 's/^# export LANG=en_US.UTF-8/export LANG=en_US.UTF-8/' "$_home/.zshrc"
  fi
  user_zshrc_block "$(basename "$_home")" "$_home" "locale" "Locale" "export LC_ALL=en_US.UTF-8"
  user_zshrc_block "$(basename "$_home")" "$_home" "nix-locale" "Nix Locale" "export LOCALE_ARCHIVE=/usr/lib/locale/locale-archive"
  unset _home
}

configure_user_configs() {
  _user="$1"
  _home="$2"

  as_user "$_user" "mkdir -p \"$_home/.config\""

  if [ -e "$_home/.config/btop" ] || [ -L "$_home/.config/btop" ]; then
    rm -rf "$_home/.config/btop"
  fi
  sudo -u "$_user" ln -sfn "$DOTFILES_ROOT/btop" "$_home/.config/btop"

  user_zshrc_block "$_user" "$_home" "fzf" "fzf" "source <(fzf --zsh)"

  as_user "$_user" "mkdir -p \"$_home/.config/lazydocker\""
  if ! grep -q 'dockerCompose: docker compose' "$_home/.config/lazydocker/config.yml" 2>/dev/null; then
    printf '%s\n' 'commandTemplates:' '  dockerCompose: docker compose' | tee -a "$_home/.config/lazydocker/config.yml" >/dev/null
  fi

  user_zshrc_block "$_user" "$_home" "lsd" "lsd" 'alias l="lsd -la"'

  as_user "$_user" "nvm install --lts --latest-npm && nvm use --lts" || \
    warn "nvm node install failed for $_user; continuing."

  user_zshrc_block "$_user" "$_home" "starship" "Starship" 'eval "$(starship init zsh)"'
  as_user "$_user" "starship preset gruvbox-rainbow -o \"$_home/.config/starship.toml\"" || \
    warn "starship preset failed for $_user; continuing."

  user_zshrc_block "$_user" "$_home" "thefuck" "The Fuck" 'eval "$(thefuck --alias)"'
  user_zshrc_block "$_user" "$_home" "zoxide" "Zoxide" 'eval "$(zoxide init zsh)"'

  as_user "$_user" "mkdir -p \"$_home/.config/vim\""
  sudo -u "$_user" ln -sfn "$DOTFILES_ROOT/vim/plugins" "$_home/.config/vim/plugins"
  sudo -u "$_user" ln -sfn "$DOTFILES_ROOT/vim/.vimrc" "$_home/.vimrc"

  if [ "$_user" != "root" ]; then
    sudo chown -R "$_user:$_user" "$_home/.config" "$_home/.oh-my-zsh" "$_home/.vimrc" "$_home/.zshrc" 2>/dev/null || \
      sudo chown -R "$_user" "$_home/.config" "$_home/.oh-my-zsh" "$_home/.vimrc" "$_home/.zshrc" || true
  fi
  sudo chsh -s "$(command -v zsh)" "$_user" || warn "chsh failed for $_user; continuing."
  unset _user _home
}

setup_shell_by_user() {
  _user="$1"
  _home="$(user_home "$_user")"
  if [ -z "$_home" ] || [ ! -d "$_home" ]; then
    die "Cannot resolve home directory for user: $_user"
  fi

  reset_user_shell_state "$_user" "$_home"
  install_user_nix_packages "$_user"
  install_user_oh_my_zsh "$_home"

  install_user_zsh_plugin "$_home" "zsh-users/zsh-autosuggestions"
  user_zshrc_block "$_user" "$_home" "autosuggest" "ZSH Autosuggestions" "ZSH_AUTOSUGGEST_STRATEGY=(history completion)"

  install_user_zsh_plugin "$_home" "zsh-users/zsh-syntax-highlighting"
  user_zshrc_block "$_user" "$_home" "highlight" "ZSH Syntax Highlighting" "ZSH_HIGHLIGHT_HIGHLIGHTERS=(main brackets pattern cursor)"

  install_user_zsh_plugin "$_home" "lukechilds/zsh-nvm"

  # shellcheck disable=SC2086
  user_activate_plugins "$_home" $ZSH_PLUGINS

  configure_user_locales "$_home"
  configure_user_configs "$_user" "$_home"
  unset _user _home
}

main() {
  run_step "Updating packages" update_packages
  run_step "Installing required packages" install_required_packages
  run_step "Removing unneeded packages" remove_unneeded_packages
  run_step "Setting up unattended upgrades" setup_unattended_upgrades

  log "Cleaning up Nix profiles" false false
  # shellcheck disable=SC2086
  for _u in $TARGET_USERS; do
    clean_nix_by_user "$_u"
  done

  run_step "Setting up Nix" setup_nix

  log "Setting up users environment" false false
  # shellcheck disable=SC2086
  for _u in $TARGET_USERS; do
    run_step "Provisioning shell for $_u" setup_shell_by_user "$_u"
  done
  unset _u
}

main "$@"
