#!/usr/bin/env bash
# shell.sh — provision ZSH + Homebrew + CLI tools + dotfile symlinks.
#
# Refactor notes (high-level patterns):
#   - Decomposed god-functions into one function per concern; main() is a
#     Template-Method pipeline of run_step stages.
#   - Configuration as data: BREW_TOOLS / APT_DEPS_* lists and zshrc_block()
#     cases replace scattered imperative blocks.
#   - Idempotent: configure_tool() wraps append_once (re-runs are no-ops),
#     symlinks use safe_link (repo-root anchored, not $PWD), clones use
#     clone_or_update (no blind rm -rf, no clone-over-existing failure), and
#     generated files (OMZ template, starship preset, catppuccin theme) are
#     only written when missing.
#   - Non-destructive: user rc files are never deleted or overwritten.
#     ~/.zprofile is never touched at all. The OMZ template seeds ~/.zshrc
#     only when it does not exist; an existing ~/.zshrc that does not load
#     Oh My Zsh yet gets a marked block prepended (plugins= BEFORE the
#     source line) with the user content left intact.
#   - Interactive steps are live: run_step_live wraps anything that prompts
#     (the Homebrew installer, chsh), because a captured step would hide the
#     prompt behind the spinner.
#   - Adapters: pkg_manager()/os_family() from common.sh replace the
#     apt-vs-yum branches, as_root replaces unquoted $_sudo, sed_inplace
#     hides the BSD/GNU `sed -i` difference, and `command -v zsh` replaces
#     the hardcoded /bin/zsh.
#   - No `source ~/.zshrc` mid-script (side-effectful, often a no-op for
#     nvm/brew in non-interactive shells).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../shared/common.sh"
DOTFILES_ROOT="$(repo_root_from "$SCRIPT_DIR")"

# Detected once; the helpers below are pure switches on these two globals.
DOTFILES_OS="$(os_family)"
DOTFILES_ARCH="$(uname -m 2>/dev/null || printf 'unknown')"

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
  local _name _code _id
  _name="$1"
  _code="$2"
  _id="$(printf '%s' "$_name" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-')"
  append_once "$HOME/.zshrc" "$_id" "# $_name
$_code"
}

# zshrc_omz_block — body of the marked block that wires Oh My Zsh into a
# pre-existing ~/.zshrc. plugins= must come BEFORE the source line: Oh My
# Zsh reads it while sourcing, so setting it afterwards has no effect.
zshrc_omz_block() {
  printf '%s\n' 'export ZSH="${ZSH:-$HOME/.oh-my-zsh}"'
  printf '%s\n' 'plugins=(git)'
  printf '%s\n' 'source $ZSH/oh-my-zsh.sh'
}

# prepend_once <file> <marker> <content...> — prepends a marked block once.
# Mirrors append_once's guard markers; the file keeps its inode and mode
# because the merged result is written back with `cat >` (not mv).
prepend_once() {
  local _file _marker _begin _end _tmp
  _file="$1"
  _marker="$2"
  _begin="# >>> dotfiles:${_marker} >>>"
  _end="# <<< dotfiles:${_marker} <<<"
  shift 2
  ensure_dir "$(dirname "$_file")"
  [ -e "$_file" ] || : >"$_file"
  if grep -qF "$_begin" "$_file" 2>/dev/null; then
    return 0
  fi
  _tmp="$(mktemp "${TMPDIR:-/tmp}/dotfiles-prepend.XXXXXX")"
  {
    printf '%s\n' "$_begin"
    printf '%s\n' "$*"
    printf '%s\n' "$_end"
    printf '\n'
    cat "$_file"
  } >"$_tmp"
  cat "$_tmp" >"$_file"
  rm -f "$_tmp"
}

# Install ZSH based on the package manager (adapter over apt/dnf/yum).
install_zsh() {
  have_cmd zsh && return 0
  case "$(pkg_manager)" in
    apt)
      run_step "Updating apt index" as_root apt-get update
      run_step "Installing zsh" as_root apt-get install -y zsh
      ;;
    dnf)
      run_step "Installing zsh" as_root dnf install -y zsh
      ;;
    yum)
      run_step "Installing zsh" as_root yum install -y zsh
      ;;
    *)
      die "Unsupported package manager. Please install ZSH manually."
      ;;
  esac
}

# Install Oh My Zsh (idempotent and non-destructive: the template seeds
# ~/.zshrc only when it is absent; an existing ~/.zshrc only gains a marked
# block when it does not load Oh My Zsh yet; ~/.zprofile is never touched).
install_oh_my_zsh() {
  clone_or_update "https://github.com/ohmyzsh/ohmyzsh.git" "$HOME/.oh-my-zsh"
  if [ ! -e "$HOME/.zshrc" ] && [ ! -L "$HOME/.zshrc" ]; then
    cp "$HOME/.oh-my-zsh/templates/zshrc.zsh-template" "$HOME/.zshrc"
    return 0
  fi
  # Already wired (ignore commented-out mentions of the file).
  if grep -q '^[^#]*oh-my-zsh\.sh' "$HOME/.zshrc" 2>/dev/null; then
    return 0
  fi
  info "Wiring Oh My Zsh into existing ~/.zshrc (content preserved)."
  prepend_once "$HOME/.zshrc" "oh-my-zsh" "$(zshrc_omz_block)"
}

# Install ZSH Plugin (idempotent).
install_zsh_plugin() {
  local _repo _dir
  _repo="$1"
  _dir="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/$(basename "$_repo")"
  clone_or_update "https://github.com/${_repo}.git" "$_dir"
}

# Activate the specified ZSH plugins in .zshrc (idempotent).
activate_zsh_plugins() {
  local _plugins
  _plugins="$*"
  require_cmd sed
  if ! grep -q '^plugins=' "$HOME/.zshrc" 2>/dev/null; then
    # Prepend (not append): plugins= is only read while Oh My Zsh is sourced.
    warn "No plugins= line in ~/.zshrc; prepending one."
    prepend_once "$HOME/.zshrc" "zsh-plugins" "plugins=($_plugins)"
    return 0
  fi
  sed_inplace "s/^plugins=.*/plugins=(${_plugins})/" "$HOME/.zshrc"
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

  # shellcheck disable=SC2086 # intentional word-splitting of the plugin manifest
  activate_zsh_plugins $ZSH_PLUGINS
}

# Activate ZSH as the default shell (portable path, not hardcoded /bin/zsh).
# Live step: chsh prompts for a password. Skips when the login shell is
# already zsh, and on Linux when the path is missing from /etc/shells
# (chsh would reject it).
activate_zsh() {
  local _zsh
  _zsh="$(command -v zsh || true)"
  if [ -z "$_zsh" ]; then
    die "zsh not found on PATH; cannot chsh."
  fi
  if [ "${SHELL:-}" = "$_zsh" ]; then
    info "Login shell is already $_zsh; skipping chsh."
    return 0
  fi
  case "$DOTFILES_OS" in
    darwin) : ;;
    *)
      if ! grep -qx "$_zsh" /etc/shells 2>/dev/null; then
        warn "$_zsh is not listed in /etc/shells; skipping chsh."
        return 0
      fi
      ;;
  esac
  run_step_live "Setting default shell to $_zsh" chsh -s "$_zsh"
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
  local _brew
  have_cmd brew && return 0
  for _brew in /opt/homebrew/bin/brew /usr/local/bin/brew /home/linuxbrew/.linuxbrew/bin/brew; do
    if [ -x "$_brew" ]; then
      eval "$("$_brew" shellenv)"
      break
    fi
  done
}

# Install Homebrew (decomposed: deps -> install -> configure).
install_homebrew_deps() {
  case "$(pkg_manager)" in
    apt)
      run_step "Updating apt index" as_root apt-get update
      # shellcheck disable=SC2086 # intentional word-splitting of the dep manifest
      run_step "Installing Homebrew build deps" as_root apt-get install -y $APT_DEPS_DEBIAN
      ;;
    dnf)
      run_step "Installing Development Tools" as_root dnf groupinstall -y 'Development Tools'
      # shellcheck disable=SC2086 # intentional word-splitting of the dep manifest
      run_step "Installing Homebrew deps" as_root dnf install -y $APT_DEPS_FEDORA
      ;;
    yum)
      run_step "Installing Development Tools" as_root yum groupinstall -y 'Development Tools'
      # shellcheck disable=SC2086 # intentional word-splitting of the dep manifest
      run_step "Installing Homebrew deps" as_root yum install -y $APT_DEPS_FEDORA
      ;;
  esac
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
    # Live: the installer waits for RETURN and may ask for the sudo password.
    run_step_live "Installing Homebrew" /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi
  brew_on_path
  require_cmd brew
  configure_tool "Homebrew" "$(homebrew_shellenv_line)"
}

# Install additional tools (single declarative manifest + one brew call).
install_tools() {
  local _tap _tools
  brew_on_path
  require_cmd brew

  # Taps first (word-splitting on the controlled manifest is intentional).
  # shellcheck disable=SC2086 # intentional word-splitting of the tap manifest
  for _tap in $BREW_TAPS; do
    brew tap "$_tap" || warn "brew tap $_tap failed; continuing."
  done

  _tools="$BREW_TOOLS"
  case "$DOTFILES_OS" in
    darwin) _tools="$_tools $BREW_TOOLS_DARWIN" ;;
  esac
  # shellcheck disable=SC2086 # intentional word-splitting of the tool manifest
  run_step "Installing brew tools" brew install $_tools

  configure_tool "fzf" "$(zshrc_block fzf)"
  configure_tool "starship" "$(zshrc_block starship)"
  configure_tool "The Fuck" "$(zshrc_block thefuck)"
  configure_tool "tmux" "$(zshrc_block tmux)"
  configure_tool "zoxide" "$(zshrc_block zoxide)"
}

# Symlink a config dir/file from the repo into $HOME (repo-anchored).
link_config() {
  local _src_rel _dst
  _src_rel="$1"
  _dst="$2"
  safe_link "$DOTFILES_ROOT/$_src_rel" "$_dst"
}

# Configure dotfiles and related tools.
configure_dotfiles() {
  ensure_dir "$HOME/.config"

  link_config "alacritty" "$HOME/.config/alacritty"
  # Fetch upstream theme only when missing (never overwrite user edits).
  if [ ! -f "$HOME/.config/alacritty/catppuccin-mocha.toml" ]; then
    curl -fLO --output-dir "$HOME/.config/alacritty" \
      https://github.com/catppuccin/alacritty/raw/main/catppuccin-mocha.toml ||
      warn "Could not download catppuccin theme; continuing."
  fi
  # Non-macOS terminals need opaque decorations; edit the *installed* copy,
  # and only when the Transparent marker is present.
  case "$DOTFILES_OS" in
    darwin) : ;;
    *)
      if grep -q 'decorations = "Transparent"' "$HOME/.config/alacritty/alacritty.toml" 2>/dev/null; then
        sed_inplace 's/decorations = "Transparent"/decorations = "None"/' "$HOME/.config/alacritty/alacritty.toml"
      fi
      ;;
  esac

  link_config "btop" "$HOME/.config/btop"

  if have_cmd starship; then
    # Generate only when missing: an existing file holds user edits.
    if [ ! -e "$HOME/.config/starship.toml" ]; then
      starship preset gruvbox-rainbow -o "$HOME/.config/starship.toml" ||
        warn "starship preset failed; continuing."
    fi
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
  run_step "Setting up ZSH" setup_zsh
  run_step "Installing Node.js" install_node
  # Live output: install_homebrew may prompt (confirm reinstall).
  run_step_live "Installing Homebrew" install_homebrew
  run_step "Installing tools" install_tools
  run_step "Configuring dotfiles" configure_dotfiles
  # Live output: chsh asks for a password.
  run_step_live "Activating ZSH shell" activate_zsh
  print_summary "Setup summary"
  log "System setup completed!"
}

main "$@"
