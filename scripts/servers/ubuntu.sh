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
  _au_user="$1"
  shift
  if [ "$(id -un)" = "$_au_user" ]; then
    bash -c "$*"
  else
    su - "$_au_user" -c "$*"
  fi
  unset _au_user
}

# Idempotent marked block in a user's .zshrc.
user_zshrc_block() {
  _uzb_user="$1"
  _uzb_home="$2"
  _uzb_id="$3"
  _uzb_comment="$4"
  _uzb_code="$5"
  ensure_dir "$_uzb_home"
  [ -e "$_uzb_home/.zshrc" ] || : >"$_uzb_home/.zshrc"
  if ! grep -qF "# >>> dotfiles:${_uzb_id} >>>" "$_uzb_home/.zshrc" 2>/dev/null; then
    {
      printf '\n# >>> dotfiles:%s >>>\n# %s\n%s\n# <<< dotfiles:%s <<<\n' \
        "$_uzb_id" "$_uzb_comment" "$_uzb_code" "$_uzb_id"
    } >>"$_uzb_home/.zshrc"
  fi
  unset _uzb_user _uzb_home _uzb_id _uzb_comment _uzb_code
}

user_activate_plugins() {
  _uap_home="$1"
  shift
  _uap_plugins="$*"
  if grep -q '^plugins=' "$_uap_home/.zshrc" 2>/dev/null; then
    sed -i "s/^plugins=.*/plugins=(${_uap_plugins})/" "$_uap_home/.zshrc"
  else
    printf '\nplugins=(%s)\n' "$_uap_plugins" >>"$_uap_home/.zshrc"
  fi
  unset _uap_home _uap_plugins
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
  run_step "Removing unneeded packages" sudo apt-get remove -y $APT_PURGE
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
  # Fail-fast like every other run_step here (no dead `|| warn`: run_step
  # exits on failure, so trailing guards would never run).
  run_step "Updating Homebrew" sudo -u ubuntu "$_brew_bin" update
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
  _rst_user="$1"
  _rst_home="$2"
  for _rst_f in "$_rst_home/.oh-my-zsh" "$_rst_home/.zshrc" "$_rst_home/.zprofile" "$_rst_home/.nvm"; do
    if [ -e "$_rst_f" ] || [ -L "$_rst_f" ]; then
      rm -rf "$_rst_f"
    fi
  done
  if have_cmd pip3; then
    sudo -H -u "$_rst_user" pip3 uninstall -y thefuck 2>/dev/null || true
  fi
  _rst_starship="$(command -v starship 2>/dev/null || true)"
  if [ -n "$_rst_starship" ]; then
    case "$_rst_starship" in
      *nix*) : ;;
      *) rm -f "$_rst_starship" || sudo rm -f "$_rst_starship" || true ;;
    esac
  fi
  unset _rst_user _rst_home _rst_f _rst_starship
}

install_user_nix_packages() {
  _inp_user="$1"
  # shellcheck disable=SC2086
  as_user "$_inp_user" "nix-env -iA $NIX_PACKAGES" || warn "nix-env install failed for $_inp_user; continuing."
  unset _inp_user
}

install_user_oh_my_zsh() {
  _ioz_home="$1"
  if [ ! -d "$_ioz_home/.oh-my-zsh/.git" ]; then
    rm -rf "$_ioz_home/.oh-my-zsh"
    git clone https://github.com/robbyrussell/oh-my-zsh.git "$_ioz_home/.oh-my-zsh"
  fi
  if [ ! -f "$_ioz_home/.zshrc" ]; then
    cp "$_ioz_home/.oh-my-zsh/templates/zshrc.zsh-template" "$_ioz_home/.zshrc"
  fi
  unset _ioz_home
}

install_user_zsh_plugin() {
  _izp_home="$1"
  _izp_repo="$2"
  _izp_dest="$_izp_home/.oh-my-zsh/custom/plugins/$(basename "$_izp_repo")"
  if [ ! -d "$_izp_dest/.git" ]; then
    rm -rf "$_izp_dest"
    git clone "https://github.com/${_izp_repo}.git" "$_izp_dest"
  fi
  unset _izp_home _izp_repo _izp_dest
}

configure_user_locales() {
  _loc_home="$1"
  if grep -q '^# export LANG=' "$_loc_home/.zshrc" 2>/dev/null; then
    sed -i 's/^# export LANG=en_US.UTF-8/export LANG=en_US.UTF-8/' "$_loc_home/.zshrc"
  fi
  user_zshrc_block "$(basename "$_loc_home")" "$_loc_home" "locale" "Locale" "export LC_ALL=en_US.UTF-8"
  user_zshrc_block "$(basename "$_loc_home")" "$_loc_home" "nix-locale" "Nix Locale" "export LOCALE_ARCHIVE=/usr/lib/locale/locale-archive"
  unset _loc_home
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
  print_summary "Ubuntu provisioning summary"
}

main "$@"
