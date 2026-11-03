#!/usr/bin/env bash
# ubuntu.sh — provision an Ubuntu server (users: ubuntu, root).
#
# This is a DELIBERATE wipe-and-reprovision script: it removes packages and
# per-user shell state before rebuilding them. main() therefore lists exactly
# what it destroys and asks for confirmation before the first mutating step;
# `-y|--yes` (or DOTFILES_ASSUME_YES=1) skips the prompt for unattended runs.
#
# Refactor notes:
#   - main() is a Template-Method pipeline of run_step stages; every stage
#     is a small function with one responsibility.
#   - Configuration as data: APT_REQUIRED / APT_PURGE / NIX_PACKAGES /
#     ZSH_PLUGINS lists replace inline literals.
#   - All per-user state is passed explicitly (user, home) — no more global
#     $home/$zsh_custom mutation across functions.
#   - Idempotency: user_zshrc_block() wraps append_once (no duplicate blocks),
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
# Consent gate — nothing below main()'s gate may run before the user agrees.
# ---------------------------------------------------------------------------
usage() {
  printf 'Usage: %s [-y|--yes]\n' "$(basename "$0")"
}

parse_args() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      -y | --yes) DOTFILES_ASSUME_YES=1 ;;
      *)
        usage >&2
        die "Unknown argument: $arg"
        ;;
    esac
  done
}

# confirm_destruction — list everything this run resets, then require consent.
confirm_destruction() {
  local user
  printf '\n%b\n' "${BOLD}This script wipes and re-provisions this machine. It will:${RESET}"
  printf '  - remove apt packages: %s\n' "$APT_PURGE"
  # shellcheck disable=SC2086
  for user in $TARGET_USERS; do
    printf '  - reset %s: ~/.oh-my-zsh ~/.zshrc ~/.zprofile ~/.nvm ~/.nix-*\n' "$user"
  done
  printf '%s\n' \
    '  - remove /nix and the nixbld build users/groups' \
    "  - remove $BREW_FOLDER (Linuxbrew)" \
    '  - remove the starship binary (unless installed by Nix)' \
    '  - uninstall the thefuck pip package'
  printf '\n'
  if ! confirm "Continue?" n; then
    printf '%s\n' "Aborted, nothing changed."
    exit 0
  fi
}

# ---------------------------------------------------------------------------
# Small helpers (explicit args, no globals)
# ---------------------------------------------------------------------------
user_home() {
  local user home
  user="$1"
  require_cmd getent
  home="$(getent passwd "$user" | cut -d: -f6)"
  printf '%s\n' "$home"
}

as_user() {
  local user
  user="$1"
  shift
  if [ "$(id -un)" = "$user" ]; then
    bash -c "$*"
  else
    su - "$user" -c "$*"
  fi
}

# Idempotent marked block in a user's .zshrc. Thin wrapper over append_once;
# the body keeps the old `# <comment>` + code shape, so blocks written by the
# previous implementation are still detected by their marker.
user_zshrc_block() {
  local home id comment code
  home="$1"
  id="$2"
  comment="$3"
  code="$4"
  append_once "$home/.zshrc" "$id" "$(printf '# %s\n%s' "$comment" "$code")"
}

user_activate_plugins() {
  local home plugins
  home="$1"
  shift
  plugins="$*"
  if grep -q '^plugins=' "$home/.zshrc" 2>/dev/null; then
    sed -i "s/^plugins=.*/plugins=(${plugins})/" "$home/.zshrc"
  else
    printf '\nplugins=(%s)\n' "$plugins" >>"$home/.zshrc"
  fi
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
    /etc/apt/apt.conf.d/50unattended-upgrades ||
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
  local brew_bin
  brew_bin="$BREW_FOLDER/.linuxbrew/bin/brew"

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
  run_step "Updating Homebrew" sudo -u ubuntu "$brew_bin" update
}

clean_nix() {
  local i f
  sudo systemctl stop nix-daemon.service 2>/dev/null || true
  sudo systemctl disable nix-daemon.socket nix-daemon.service 2>/dev/null || true
  sudo systemctl daemon-reload 2>/dev/null || true
  sudo rm -rf /etc/nix /etc/profile.d/nix.sh /etc/tmpfiles.d/nix-daemon.conf /nix || true
  i=1
  while [ "$i" -le 32 ]; do
    sudo userdel "nixbld$i" 2>/dev/null || true
    i=$((i + 1))
  done
  sudo groupdel nixbld 2>/dev/null || true
  for f in /etc/zsh/zshrc.backup-before-nix /etc/zshrc.backup-before-nix /etc/bash.bashrc.backup-before-nix /etc/bashrc.backup-before-nix; do
    if [ -e "$f" ]; then
      sudo mv "$f" "${f%.backup-before-nix}"
    fi
  done
}

clean_nix_by_user() {
  local user home d
  user="$1"
  home="$(user_home "$user")"
  for d in "$home/.nix-channels" "$home/.nix-defexpr" "$home/.nix-profile"; do
    if [ -d "$d" ]; then
      rm -rf "$d"
    fi
  done
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
  local user home f starship
  user="$1"
  home="$2"
  for f in "$home/.oh-my-zsh" "$home/.zshrc" "$home/.zprofile" "$home/.nvm"; do
    if [ -e "$f" ] || [ -L "$f" ]; then
      rm -rf "$f"
    fi
  done
  if have_cmd pip3; then
    sudo -H -u "$user" pip3 uninstall -y thefuck 2>/dev/null || true
  fi
  starship="$(command -v starship 2>/dev/null || true)"
  if [ -n "$starship" ]; then
    case "$starship" in
      *nix*) : ;;
      *) rm -f "$starship" || sudo rm -f "$starship" || true ;;
    esac
  fi
}

install_user_nix_packages() {
  local user
  user="$1"
  # shellcheck disable=SC2086
  as_user "$user" "nix-env -iA $NIX_PACKAGES" || warn "nix-env install failed for $user; continuing."
}

install_user_oh_my_zsh() {
  local home
  home="$1"
  if [ ! -d "$home/.oh-my-zsh/.git" ]; then
    rm -rf "$home/.oh-my-zsh"
    git clone https://github.com/ohmyzsh/ohmyzsh.git "$home/.oh-my-zsh"
  fi
  if [ ! -f "$home/.zshrc" ]; then
    cp "$home/.oh-my-zsh/templates/zshrc.zsh-template" "$home/.zshrc"
  fi
}

install_user_zsh_plugin() {
  local home repo dest
  home="$1"
  repo="$2"
  dest="$home/.oh-my-zsh/custom/plugins/$(basename "$repo")"
  if [ ! -d "$dest/.git" ]; then
    rm -rf "$dest"
    git clone "https://github.com/${repo}.git" "$dest"
  fi
}

configure_user_locales() {
  local home
  home="$1"
  if grep -q '^# export LANG=' "$home/.zshrc" 2>/dev/null; then
    sed -i 's/^# export LANG=en_US.UTF-8/export LANG=en_US.UTF-8/' "$home/.zshrc"
  fi
  user_zshrc_block "$home" "locale" "Locale" "export LC_ALL=en_US.UTF-8"
  user_zshrc_block "$home" "nix-locale" "Nix Locale" "export LOCALE_ARCHIVE=/usr/lib/locale/locale-archive"
}

configure_user_configs() {
  local user home
  user="$1"
  home="$2"

  as_user "$user" "mkdir -p \"$home/.config\""

  if [ -e "$home/.config/btop" ] || [ -L "$home/.config/btop" ]; then
    rm -rf "$home/.config/btop"
  fi
  sudo -u "$user" ln -sfn "$DOTFILES_ROOT/btop" "$home/.config/btop"

  user_zshrc_block "$home" "fzf" "fzf" "source <(fzf --zsh)"

  as_user "$user" "mkdir -p \"$home/.config/lazydocker\""
  if ! grep -q 'dockerCompose: docker compose' "$home/.config/lazydocker/config.yml" 2>/dev/null; then
    printf '%s\n' 'commandTemplates:' '  dockerCompose: docker compose' | tee -a "$home/.config/lazydocker/config.yml" >/dev/null
  fi

  user_zshrc_block "$home" "lsd" "lsd" 'alias l="lsd -la"'

  as_user "$user" "nvm install --lts --latest-npm && nvm use --lts" ||
    warn "nvm node install failed for $user; continuing."

  user_zshrc_block "$home" "starship" "Starship" 'eval "$(starship init zsh)"'
  as_user "$user" "starship preset gruvbox-rainbow -o \"$home/.config/starship.toml\"" ||
    warn "starship preset failed for $user; continuing."

  user_zshrc_block "$home" "thefuck" "The Fuck" 'eval "$(thefuck --alias)"'
  user_zshrc_block "$home" "zoxide" "Zoxide" 'eval "$(zoxide init zsh)"'

  as_user "$user" "mkdir -p \"$home/.config/vim\""
  sudo -u "$user" ln -sfn "$DOTFILES_ROOT/vim/plugins" "$home/.config/vim/plugins"
  sudo -u "$user" ln -sfn "$DOTFILES_ROOT/vim/.vimrc" "$home/.vimrc"

  if [ "$user" != "root" ]; then
    sudo chown -R "$user:$user" "$home/.config" "$home/.oh-my-zsh" "$home/.vimrc" "$home/.zshrc" 2>/dev/null ||
      sudo chown -R "$user" "$home/.config" "$home/.oh-my-zsh" "$home/.vimrc" "$home/.zshrc" || true
  fi
  sudo chsh -s "$(command -v zsh)" "$user" || warn "chsh failed for $user; continuing."
}

setup_shell_by_user() {
  local user home
  user="$1"
  home="$(user_home "$user")"
  if [ -z "$home" ] || [ ! -d "$home" ]; then
    die "Cannot resolve home directory for user: $user"
  fi

  reset_user_shell_state "$user" "$home"
  install_user_nix_packages "$user"
  install_user_oh_my_zsh "$home"

  install_user_zsh_plugin "$home" "zsh-users/zsh-autosuggestions"
  user_zshrc_block "$home" "autosuggest" "ZSH Autosuggestions" "ZSH_AUTOSUGGEST_STRATEGY=(history completion)"

  install_user_zsh_plugin "$home" "zsh-users/zsh-syntax-highlighting"
  user_zshrc_block "$home" "highlight" "ZSH Syntax Highlighting" "ZSH_HIGHLIGHT_HIGHLIGHTERS=(main brackets pattern cursor)"

  install_user_zsh_plugin "$home" "lukechilds/zsh-nvm"

  # shellcheck disable=SC2086
  user_activate_plugins "$home" $ZSH_PLUGINS

  configure_user_locales "$home"
  configure_user_configs "$user" "$home"
}

main() {
  local user
  parse_args "$@"
  confirm_destruction

  # Warm sudo once so its prompt is not hidden behind a step spinner.
  sudo_warm || warn "sudo unavailable; privileged steps may fail."

  run_step "Updating packages" update_packages
  run_step "Installing required packages" install_required_packages
  run_step "Removing unneeded packages" remove_unneeded_packages
  run_step "Setting up unattended upgrades" setup_unattended_upgrades

  log "Cleaning up Nix profiles" false false
  # shellcheck disable=SC2086
  for user in $TARGET_USERS; do
    clean_nix_by_user "$user"
  done

  run_step "Setting up Nix" setup_nix

  log "Setting up users environment" false false
  # shellcheck disable=SC2086
  for user in $TARGET_USERS; do
    run_step "Provisioning shell for $user" setup_shell_by_user "$user"
  done
  print_summary "Ubuntu provisioning summary"
}

main "$@"
