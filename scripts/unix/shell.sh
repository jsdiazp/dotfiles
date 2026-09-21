#!/usr/bin/env bash
# shell.sh — provision ZSH + Homebrew + CLI tools + dotfile symlinks.
#
# Refactor notes (high-level patterns):
#   - Decomposed god-functions into one function per concern; main() is a
#     Template-Method pipeline of run_step stages.
#   - Configuration as data: BREW_TOOLS / APT_DEPS_* lists and zshrc_block()
#     cases replace scattered imperative blocks.
#   - Idempotency: zshrc_block() wraps append_once (re-runs are no-ops),
#     symlinks use safe_link (repo-root anchored, not $PWD), clones use
#     clone_or_update (no blind rm -rf, no clone-over-existing failure).
#   - Adapters: pkg_manager()/os_family() from common.sh replace the
#     apt-vs-yum branches; `command -v zsh` replaces hardcoded /bin/zsh.
#   - No `source ~/.zshrc` mid-script (side-effectful, often a no-op for
#     nvm/brew in non-interactive shells).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../shared/common.sh"
DOTFILES_ROOT="$(repo_root_from "$SCRIPT_DIR")"

DOTFILES_OS="$(os_family)"

# ---------------------------------------------------------------------------
# Declarative manifests
# ---------------------------------------------------------------------------
BREW_TAPS="oven-sh/bun"
BREW_TOOLS="bat btop bun fastfetch fd fzf lazydocker lazygit lsd ripgrep starship thefuck tmux vim zoxide"
# macOS-only brews (Linuxbrew has no Mac App Store).
BREW_TOOLS_DARWIN="mas"

ZSH_PLUGINS="git zsh-autosuggestions zsh-syntax-highlighting zsh-nvm"

APT_DEPS_DEBIAN="build-essential curl file git procps"
APT_DEPS_FEDORA="curl file git procps-ng"

# zshrc_block <id> — prints the snippet body for a named block.
# (case-dispatch instead of an associative array for bash 3.2 compat.)
zshrc_block() {
  case "$1" in
    autosuggest) printf '%s\n' "ZSH_AUTOSUGGEST_STRATEGY=(history completion)" ;;
    highlight) printf '%s\n' "ZSH_HIGHLIGHT_HIGHLIGHTERS=(main brackets pattern cursor)" ;;
    homebrew) printf '%s\n' "eval \"${2:-}\"" ;;
    fzf) printf '%s\n' "source <(fzf --zsh)" ;;
    starship) printf '%s\n' 'eval "$(starship init zsh)"' ;;
    thefuck) printf '%s\n' 'eval "$(thefuck --alias)"' ;;
    tmux) printf '%s\n' 'alias tm="tmux attach || tmux"' ;;
    zoxide) printf '%s\n' 'eval "$(zoxide init zsh)"' ;;
    *) die "Unknown zshrc block: $1" ;;
  esac
}

# Configure additional tools (idempotent marked block).
configure_tool() {
  _name="$1"
  _code="$2"
  _id="$(printf '%s' "$_name" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-')"
  append_once "$HOME/.zshrc" "$_id" "# $_name
$_code"
  unset _name _code _id
}

# Detect the operating system and architecture (sets DOTFILES_OS/ARCH).
detect_os() {
  DOTFILES_OS="$(os_family)"
  DOTFILES_ARCH="$(uname -m 2>/dev/null || printf 'unknown')"
  export DOTFILES_OS DOTFILES_ARCH
}

# Install ZSH based on the package manager (adapter over apt/dnf/yum).
install_zsh() {
  have_cmd zsh && return 0
  _sudo="$(sudo_if_needed)"
  case "$(pkg_manager)" in
    apt)
      run_step "Updating apt index" $_sudo apt-get update
      run_step "Installing zsh" $_sudo apt-get install -y zsh
      ;;
    dnf)
      run_step "Installing zsh" $_sudo dnf install -y zsh
      ;;
    yum)
      run_step "Installing zsh" $_sudo yum install -y zsh
      ;;
    *)
      die "Unsupported package manager. Please install ZSH manually."
      ;;
  esac
  unset _sudo
}

# Install Oh My Zsh (idempotent: fresh template only on first install;
# user .zshrc — including append_once blocks — is preserved on re-runs).
install_oh_my_zsh() {
  _fresh=0
  if [ ! -d "$HOME/.oh-my-zsh/.git" ]; then
    _fresh=1
  fi
  clone_or_update "https://github.com/ohmyzsh/ohmyzsh.git" "$HOME/.oh-my-zsh"
  if [ "$_fresh" -eq 1 ] || [ ! -f "$HOME/.zshrc" ]; then
    if [ -e "$HOME/.zshrc" ] || [ -L "$HOME/.zshrc" ]; then
      backup_once "$HOME/.zshrc"
      rm -f "$HOME/.zshrc"
    fi
    cp "$HOME/.oh-my-zsh/templates/zshrc.zsh-template" "$HOME/.zshrc"
  fi
  if [ -e "$HOME/.zprofile" ] || [ -L "$HOME/.zprofile" ]; then
    backup_once "$HOME/.zprofile"
    rm -f "$HOME/.zprofile"
  fi
  unset _fresh
}

# Install ZSH Plugin (idempotent).
install_zsh_plugin() {
  _repo="$1"
  _dir="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/$(basename "$_repo")"
  clone_or_update "https://github.com/${_repo}.git" "$_dir"
  unset _repo _dir
}

# Activate the specified ZSH plugins in .zshrc.
activate_zsh_plugins() {
  _plugins="$*"
  require_cmd sed
  if ! grep -q '^plugins=' "$HOME/.zshrc" 2>/dev/null; then
    warn "No plugins= line in ~/.zshrc; appending one."
    printf '\nplugins=(%s)\n' "$_plugins" >>"$HOME/.zshrc"
    return 0
  fi
  case "$DOTFILES_OS" in
    darwin) sed -i '' -e "s/^plugins=.*/plugins=(${_plugins})/" "$HOME/.zshrc" ;;
    *) sed -i "s/^plugins=.*/plugins=(${_plugins})/" "$HOME/.zshrc" ;;
  esac
  unset _plugins
}

# Set up ZSH and install plugins.
setup_zsh() {
  case "$DOTFILES_OS" in
    linux | wsl) install_zsh ;;
  esac

  run_step "Installing Oh My Zsh" install_oh_my_zsh

  run_step "Installing zsh-autosuggestions" install_zsh_plugin zsh-users/zsh-autosuggestions
  configure_tool "ZSH Autosuggestions" "$(zshrc_block autosuggest)"

  run_step "Installing zsh-syntax-highlighting" install_zsh_plugin zsh-users/zsh-syntax-highlighting
  configure_tool "ZSH Syntax Highlighting" "$(zshrc_block highlight)"

  run_step "Installing zsh-nvm" install_zsh_plugin lukechilds/zsh-nvm

  # shellcheck disable=SC2086
  activate_zsh_plugins $ZSH_PLUGINS
}

# Activate ZSH as the default shell (portable path, not hardcoded /bin/zsh).
activate_zsh() {
  _zsh="$(command -v zsh || true)"
  if [ -z "$_zsh" ]; then
    die "zsh not found on PATH; cannot chsh."
  fi
  run_step "Setting default shell to $_zsh" chsh -s "$_zsh"
  unset _zsh
}

# Install node.js via nvm when the shell integration is available.
install_node() {
  if ! command -v nvm >/dev/null 2>&1; then
    if [ -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]; then
      # shellcheck disable=SC1091
      . "${NVM_DIR:-$HOME/.nvm}/nvm.sh"
    elif [ -s "$HOME/.oh-my-zsh/custom/plugins/zsh-nvm/zsh-nvm.plugin.zsh" ]; then
      warn "zsh-nvm installed but nvm not loaded in this shell; skipping node install (open a new shell and re-run)."
      return 0
    else
      warn "nvm not available; skipping node install."
      return 0
    fi
  fi
  run_step "Installing Node.js LTS" nvm install --lts --latest-npm
  nvm use --lts || true
}

# brew_on_path — ensure just-installed brew is usable in this process.
brew_on_path() {
  have_cmd brew && return 0
  for _brew in /opt/homebrew/bin/brew /usr/local/bin/brew /home/linuxbrew/.linuxbrew/bin/brew; do
    if [ -x "$_brew" ]; then
      eval "$("$_brew" shellenv)"
      break
    fi
  done
  unset _brew
}

# Install Homebrew (decomposed: deps -> install -> configure).
install_homebrew_deps() {
  _sudo="$(sudo_if_needed)"
  case "$(pkg_manager)" in
    apt)
      run_step "Updating apt index" $_sudo apt-get update
      # shellcheck disable=SC2086
      run_step "Installing Homebrew build deps" $_sudo apt-get install -y $APT_DEPS_DEBIAN
      ;;
    dnf)
      run_step "Installing Development Tools" $_sudo dnf groupinstall -y 'Development Tools'
      # shellcheck disable=SC2086
      run_step "Installing Homebrew deps" $_sudo dnf install -y $APT_DEPS_FEDORA
      ;;
    yum)
      run_step "Installing Development Tools" $_sudo yum groupinstall -y 'Development Tools'
      # shellcheck disable=SC2086
      run_step "Installing Homebrew deps" $_sudo yum install -y $APT_DEPS_FEDORA
      ;;
  esac
  unset _sudo
}

homebrew_shellenv_line() {
  case "$DOTFILES_OS" in
    darwin)
      case "$DOTFILES_ARCH" in
        arm64 | aarch64) printf 'eval "$(/opt/homebrew/bin/brew shellenv)"\n' ;;
        *) printf 'eval "$(/usr/local/bin/brew shellenv)"\n' ;;
      esac
      ;;
    *) printf 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"\n' ;;
  esac
}

install_homebrew() {
  # Uninstall only when a brew installation actually exists.
  if have_cmd brew; then
    if confirm "Homebrew already installed. Reinstall from scratch?" "n"; then
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh)" || true
    else
      info "Keeping existing Homebrew installation."
    fi
  fi

  case "$DOTFILES_OS" in
    linux | wsl) install_homebrew_deps ;;
  esac

  if ! have_cmd brew; then
    run_step "Installing Homebrew" /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
  brew_on_path
  require_cmd brew
  configure_tool "Homebrew" "$(homebrew_shellenv_line)"
}

# Install additional tools (single declarative manifest + one brew call).
install_tools() {
  brew_on_path
  require_cmd brew

  # Taps first (word-splitting on controlled constant is intentional).
  # shellcheck disable=SC2086
  for _tap in $BREW_TAPS; do
    brew tap "$_tap" || warn "brew tap $_tap failed; continuing."
  done

  # shellcheck disable=SC2086
  _tools="$BREW_TOOLS"
  case "$DOTFILES_OS" in
    darwin) _tools="$_tools $BREW_TOOLS_DARWIN" ;;
  esac
  run_step "Installing brew tools" brew install $_tools
  unset _tools

  configure_tool "fzf" "$(zshrc_block fzf)"
  configure_tool "starship" "$(zshrc_block starship)"
  configure_tool "The Fuck" "$(zshrc_block thefuck)"
  configure_tool "tmux" "$(zshrc_block tmux)"
  configure_tool "zoxide" "$(zshrc_block zoxide)"
  unset _tap
}

# Symlink a config dir/file from the repo into $HOME (repo-anchored).
link_config() {
  _src_rel="$1"
  _dst="$2"
  safe_link "$DOTFILES_ROOT/$_src_rel" "$_dst"
  unset _src_rel _dst
}

# Configure dotfiles and related tools.
configure_dotfiles() {
  ensure_dir "$HOME/.config"

  link_config "alacritty" "$HOME/.config/alacritty"
  # Fetch upstream theme only when missing (never overwrite user edits).
  if [ ! -f "$HOME/.config/alacritty/catppuccin-mocha.toml" ]; then
    curl -fLO --output-dir "$HOME/.config/alacritty" \
      https://github.com/catppuccin/alacritty/raw/main/catppuccin-mocha.toml || \
      warn "Could not download catppuccin theme; continuing."
  fi
  # Non-macOS terminals need opaque decorations; edit the *installed* copy,
  # and only when the Transparent marker is present.
  case "$DOTFILES_OS" in
    darwin) : ;;
    *)
      if grep -q 'decorations = "Transparent"' "$HOME/.config/alacritty/alacritty.toml" 2>/dev/null; then
        sed -i 's/decorations = "Transparent"/decorations = "None"/' "$HOME/.config/alacritty/alacritty.toml"
      fi
      ;;
  esac

  link_config "btop" "$HOME/.config/btop"

  if have_cmd starship; then
    starship preset gruvbox-rainbow -o "$HOME/.config/starship.toml" || \
      warn "starship preset failed; continuing."
  else
    warn "starship not on PATH yet; skipping preset (open a new shell)."
  fi

  link_config "tmux" "$HOME/.config/tmux"
  clone_or_update "https://github.com/tmux-plugins/tpm" "$HOME/.config/tmux/plugins/tpm"

  ensure_dir "$HOME/.config/vim"
  safe_link "$DOTFILES_ROOT/vim/.vimrc" "$HOME/.vimrc"
  safe_link "$DOTFILES_ROOT/vim/plugins" "$HOME/.config/vim/plugins"
}

# Main script execution.
main() {
  detect_os
  run_step "Setting up ZSH" setup_zsh
  run_step "Installing Node.js" install_node
  # Live output: install_homebrew may prompt (confirm reinstall).
  run_step_live "Installing Homebrew" install_homebrew
  run_step "Installing tools" install_tools
  run_step "Configuring dotfiles" configure_dotfiles
  run_step "Activating ZSH shell" activate_zsh
  print_summary "Setup summary"
  log "System setup completed!"
}

main "$@"
