#!/usr/bin/env bash
# test_shell.sh — regression gates for scripts/unix/shell.sh.
#
# What this file pins down (each was a real bug or a destructive-action guard):
#   1. install_tools passes every tool to `brew install` as its OWN argument
#      (a quoted "$tools" turned the whole manifest into one bogus formula) and
#      appends the darwin-only `mas`.
#   2. Oh My Zsh wiring: a fresh ~/.zshrc is seeded from the template; a custom
#      ~/.zshrc keeps every original line, gains a marked block BEFORE them and
#      really loads the four plugins in zsh; an already-wired file only gets its
#      plugins= line rewritten; a second run is byte-identical (idempotent).
#   3. ~/.zprofile is never touched, and an existing ~/.zshrc is never deleted,
#      moved aside or backed up (a `rm -f ~/.zprofile` regression wiped user
#      state). Later dotfile steps must not rewrite it at all.
#   4. `starship preset` runs only when ~/.config/starship.toml is missing, so an
#      existing file with user edits is never overwritten.
#   5. chsh is skipped when the login shell already IS the resolved zsh, and run
#      exactly once otherwise.
#   6. --yes (DOTFILES_ASSUME_YES=1) can never uninstall an existing Homebrew:
#      the reinstall prompt is `strict`.
#   7. configure_dotfiles links the repo configs, creates no `.bak.*` on a second
#      run, and only disables alacritty transparency on non-darwin.
#
# Style: bash 3.2 (macOS /bin/bash), no `set -e`, deterministic assertions only.
# All probes run against a throwaway copy of the repo under $TEST_TMP: the
# linux alacritty step edits the *linked* copy, never the real checkout.

set -u

# ---------------------------------------------------------------------------
# Helpers (local to this file; tests/lib only holds generic helpers)
# ---------------------------------------------------------------------------

# _repo_copy — make_repo_copy plus the config trees configure_dotfiles links
# (make_repo_copy only ships setup.sh + scripts/). tmux/plugins is deliberately
# NOT copied: it is gitignored and TPM-filled, so a fresh clone does not have
# it either (and the plugin trees here are huge). Prints the copy's path.
_repo_copy() {
  local dest src
  dest="$(make_repo_copy)"
  for src in alacritty btop vim; do
    cp -R "$REPO_ROOT/$src" "$dest/"
  done
  mkdir -p "$dest/tmux"
  cp "$REPO_ROOT/tmux/tmux.conf" "$dest/tmux/"
  # Normalize like repo_root_from does (cd + pwd): assertions compare against
  # the paths safe_link resolves to, and $TEST_TMP may carry a doubled slash.
  (cd "$dest" && pwd)
}

# _shell_probe_copy — copy the repo, then write a sourceable shell.sh into it
# (same directory, final `main "$@"` removed). Sets REPO_COPY and SHELL_PROBE.
_shell_probe_copy() {
  local src
  REPO_COPY="$(_repo_copy)"
  src="$REPO_COPY/scripts/unix/shell.sh"
  SHELL_PROBE="$REPO_COPY/scripts/unix/shell_probe.sh"
  grep -v '^main "\$@"$' "$src" >"$SHELL_PROBE"
  assert_file_exists "$SHELL_PROBE"
}

# _probe <script> <code> — source <script> in a fresh bash where $0 points at it
# (so its own SCRIPT_DIR/../shared/common.sh resolution matches a real run),
# then run <code>. Sets OUT and RC.
_probe() {
  local script="$1" code="$2"
  # shellcheck disable=SC2153 # TEST_BASH comes from tests/run.sh, not this file.
  run "$TEST_BASH" -c ". \"\$0\"
$code" "$script"
}

# _probe_stdin <input> <script> <code> — like _probe, with <input> on stdin.
_probe_stdin() {
  local input="$1" script="$2" code="$3"
  # shellcheck disable=SC2153 # TEST_BASH comes from tests/run.sh, not this file.
  run_stdin "$input" "$TEST_BASH" -c ". \"\$0\"
$code" "$script"
}

# _brew_stub — brew whose log shows one `<arg>` token per argv entry (so a
# single-quoted "$BREW_TOOLS" mutant is visible) plus the argc of every call.
_brew_stub() {
  mkdir -p "$STUBS"
  cat >"$STUBS/brew" <<'EOF'
#!/bin/sh
{
  printf 'brew'
  for a in "$@"; do printf ' <%s>' "$a"; done
  printf '\n'
} >>"$CALLS"
printf 'brew-argc %s\n' "$#" >>"$CALLS"
if [ "$1" = shellenv ]; then printf '%s\n' 'export PATH="$PATH:/stub"'; fi
exit 0
EOF
  chmod +x "$STUBS/brew"
}

# _starship_stub — logs, and writes the -o target when `preset` is asked for.
_starship_stub() {
  mkdir -p "$STUBS"
  cat >"$STUBS/starship" <<'EOF'
#!/bin/sh
printf 'starship %s\n' "$*" >>"$CALLS"
prev=""
target=""
for a in "$@"; do
  if [ "$prev" = "-o" ]; then target="$a"; fi
  prev="$a"
done
if [ -n "$target" ]; then printf '%s\n' 'generated = true' >"$target"; fi
exit 0
EOF
  chmod +x "$STUBS/starship"
}

# _curl_stub — logs the URL and prints a harmless script body for the
# `bash -c "$(curl ...)"` pattern. Never touches the network.
_curl_stub() {
  make_stub_body curl <<'EOF'
printf '%s\n' 'exit 0'
EOF
}

# _seed_omz — a stub Oh My Zsh checkout in $HOME, including a template and an
# oh-my-zsh.sh that reports the final plugin list.
_seed_omz() {
  local omz="$HOME/.oh-my-zsh"
  mkdir -p "$omz/.git" "$omz/templates" "$omz/custom/plugins"
  cat >"$omz/templates/zshrc.zsh-template" <<'EOF'
# Path to your oh-my-zsh installation.
export ZSH="$HOME/.oh-my-zsh"

# Which plugins would you like to load?
plugins=(git)

source $ZSH/oh-my-zsh.sh
EOF
  cat >"$omz/oh-my-zsh.sh" <<'EOF'
echo "PLUGINS_AT_SOURCE=${plugins[*]-unset}"
EOF
}

# _expected_plugins — the plugins= line the script must converge on.
_expected_plugins() {
  printf '%s\n' 'plugins=(git zsh-autosuggestions zsh-syntax-highlighting zsh-nvm)'
}

# _count_calls <fixed-string> — how many logged calls contain it (0 when none).
_count_calls() {
  calls | grep -cF -- "$1" || true
}

# ---------------------------------------------------------------------------
# 1. install_tools: one brew argument per tool, tap first, mas on darwin
# ---------------------------------------------------------------------------

test_install_tools_passes_each_tool_as_a_separate_brew_argument() {
  _shell_probe_copy
  _brew_stub
  local tools n argc_line expected install_line
  _probe "$SHELL_PROBE" 'DOTFILES_OS=darwin
printf "TOOLS=%s\n" "$BREW_TOOLS"
install_tools'
  assert_rc 0 "install_tools must succeed with stub brew"
  assert_called "brew <tap> <oven-sh/bun>" "the tap manifest must be tapped"

  tools="$(printf '%s\n' "$OUT" | sed -n 's/^TOOLS=//p')"
  [ -n "$tools" ] || fail "could not read BREW_TOOLS from the probe: $OUT"

  n="$(calls | grep -nF 'brew <install>' | head -1 | cut -d: -f1)"
  [ -n "$n" ] || fail "no 'brew install' call; calls were:
$(calls)"
  install_line="$(calls | sed -n "${n}p")"
  argc_line="$(calls | sed -n "$((n + 1))p")"
  expected=$(($(printf '%s\n' "$tools" | wc -w) + 2))

  for tool in $tools; do
    assert_contains "$install_line" "<$tool>" "tool [$tool] must be its own brew argument"
  done
  assert_contains "$install_line" "<mas>" "mas is appended on darwin"
  assert_eq "brew-argc $expected" "$argc_line" \
    "brew install must receive one argument per tool (not one blob)"
}

# ---------------------------------------------------------------------------
# 2. Oh My Zsh wiring
# ---------------------------------------------------------------------------

test_omz_seeds_a_fresh_zshrc_from_the_template() {
  _shell_probe_copy
  _seed_omz
  make_stub git
  _probe "$SHELL_PROBE" 'DOTFILES_OS=darwin
setup_zsh'
  assert_rc 0
  assert_file_exists "$HOME/.zshrc"
  local rc
  rc="$(cat "$HOME/.zshrc")"
  assert_contains "$rc" 'export ZSH="$HOME/.oh-my-zsh"' "the template must seed ~/.zshrc"
  assert_contains "$rc" 'source $ZSH/oh-my-zsh.sh'
  assert_contains "$rc" "$(_expected_plugins)" "all four plugins must be active"
}

test_omz_wires_an_existing_zshrc_without_losing_user_lines() {
  _shell_probe_copy
  _seed_omz
  make_stub git
  cat >"$HOME/.zshrc" <<'EOF'
export EDITOR=vim
alias ll='ls -la'
export PATH="$HOME/bin:$PATH"
EOF
  cp "$HOME/.zshrc" "$TEST_TMP/zshrc.user"
  _probe "$SHELL_PROBE" 'DOTFILES_OS=darwin
setup_zsh'
  assert_rc 0
  local content line marker_line user_line
  content="$(cat "$HOME/.zshrc")"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    assert_contains "$content" "$line" "user line [$line] must survive"
  done <"$TEST_TMP/zshrc.user"

  marker_line="$(grep -n '^# >>> dotfiles:oh-my-zsh >>>$' "$HOME/.zshrc" | head -1 | cut -d: -f1)"
  user_line="$(grep -n '^export EDITOR=vim$' "$HOME/.zshrc" | head -1 | cut -d: -f1)"
  [ -n "$marker_line" ] || fail "no marked oh-my-zsh block in ~/.zshrc:
$content"
  [ -n "$user_line" ] || fail "user content disappeared from ~/.zshrc:
$content"
  [ "$marker_line" -lt "$user_line" ] ||
    fail "the oh-my-zsh block must be prepended (marker line $marker_line, user line $user_line)"
  assert_contains "$content" "$(_expected_plugins)" "the block's plugins= must be rewritten"
}

test_omz_block_makes_zsh_load_all_four_plugins() {
  if [ -z "$TEST_ZSH" ]; then
    skip "zsh not available"
  fi
  _shell_probe_copy
  _seed_omz
  make_stub git
  cat >"$HOME/.zshrc" <<'EOF'
export EDITOR=vim
EOF
  _probe "$SHELL_PROBE" 'DOTFILES_OS=darwin
setup_zsh'
  assert_rc 0
  # env -i: a caller's $ZSH must not leak into the block's resolution.
  run env -i HOME="$HOME" PATH=/usr/bin:/bin "$TEST_ZSH" -f "$HOME/.zshrc"
  assert_rc 0 "zsh could not source the rewritten ~/.zshrc"
  assert_contains "$OUT" \
    "PLUGINS_AT_SOURCE=git zsh-autosuggestions zsh-syntax-highlighting zsh-nvm" \
    "plugins= must be set BEFORE Oh My Zsh is sourced"
}

test_omz_rewrites_only_the_plugins_line_of_a_wired_zshrc() {
  _shell_probe_copy
  _seed_omz
  make_stub git
  cat >"$HOME/.zshrc" <<'EOF'
export ZSH="$HOME/.oh-my-zsh"
plugins=(git docker)
source $ZSH/oh-my-zsh.sh
export EDITOR=vim
EOF
  cat >"$TEST_TMP/expected.zshrc" <<'EOF'
export ZSH="$HOME/.oh-my-zsh"
plugins=(git zsh-autosuggestions zsh-syntax-highlighting zsh-nvm)
source $ZSH/oh-my-zsh.sh
export EDITOR=vim
EOF
  _probe "$SHELL_PROBE" 'DOTFILES_OS=darwin
setup_zsh'
  assert_rc 0
  head -4 "$HOME/.zshrc" >"$TEST_TMP/actual.head"
  head -4 "$TEST_TMP/expected.zshrc" >"$TEST_TMP/expected.head"
  assert_same_file "$TEST_TMP/actual.head" "$TEST_TMP/expected.head" \
    "an already-wired ~/.zshrc may only have its plugins= line rewritten"
  assert_eq 1 "$(grep -c '^plugins=' "$HOME/.zshrc")" "exactly one plugins= line"
  assert_not_contains "$(cat "$HOME/.zshrc")" "# >>> dotfiles:oh-my-zsh >>>" \
    "no extra block when Oh My Zsh is already sourced"
}

test_omz_setup_is_byte_identical_on_a_second_run() {
  _shell_probe_copy
  _seed_omz
  make_stub git
  _probe "$SHELL_PROBE" 'DOTFILES_OS=darwin
setup_zsh'
  assert_rc 0
  cp "$HOME/.zshrc" "$TEST_TMP/zshrc.first"
  reset_calls
  _probe "$SHELL_PROBE" 'DOTFILES_OS=darwin
setup_zsh'
  assert_rc 0
  assert_same_file "$HOME/.zshrc" "$TEST_TMP/zshrc.first" \
    "a second setup_zsh run must not touch ~/.zshrc"
}

# ---------------------------------------------------------------------------
# 3. ~/.zprofile untouched, ~/.zshrc never deleted/replaced
# ---------------------------------------------------------------------------

test_zprofile_is_never_deleted_and_zshrc_is_never_replaced() {
  _shell_probe_copy
  _seed_omz
  make_stub git
  _brew_stub
  _curl_stub
  _starship_stub
  printf '%s\n' 'export ZDOTDIR_PROBE=1' '# zprofile must stay byte-identical' >"$HOME/.zprofile"
  cat >"$HOME/.zshrc" <<'EOF'
# my precious zshrc
export EDITOR=vim
EOF
  cp "$HOME/.zprofile" "$TEST_TMP/zprofile.snapshot"
  cp "$HOME/.zshrc" "$TEST_TMP/zshrc.user"
  _probe "$SHELL_PROBE" 'DOTFILES_OS=darwin
setup_zsh'
  assert_rc 0
  assert_file_exists "$HOME/.zprofile"
  assert_same_file "$HOME/.zprofile" "$TEST_TMP/zprofile.snapshot" \
    "setup_zsh must never touch ~/.zprofile"
  # Not deleted/recreated: the file is still a regular file we own, no .bak.*
  # and no symlink swap (sed -i legitimately replaces the inode, see the report).
  assert_eq "" "$(find "$HOME" -maxdepth 1 -name '.zshrc.bak.*' -print)" \
    "the user zshrc must not be backed up or moved aside"
  [ -f "$HOME/.zshrc" ] && [ ! -L "$HOME/.zshrc" ] ||
    fail "the user zshrc must stay a regular file at its original path"
  local line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    assert_contains "$(cat "$HOME/.zshrc")" "$line" "user line [$line] must survive"
  done <"$TEST_TMP/zshrc.user"

  cp "$HOME/.zshrc" "$TEST_TMP/zshrc.after-omz"
  reset_calls
  _probe "$SHELL_PROBE" 'DOTFILES_OS=darwin
configure_dotfiles'
  assert_rc 0
  assert_same_file "$HOME/.zprofile" "$TEST_TMP/zprofile.snapshot" \
    "configure_dotfiles must never touch ~/.zprofile"
  assert_same_file "$HOME/.zshrc" "$TEST_TMP/zshrc.after-omz" \
    "configure_dotfiles must not write ~/.zshrc"
}

# ---------------------------------------------------------------------------
# 4. starship preset only when the config file is missing
# ---------------------------------------------------------------------------

test_starship_preset_runs_only_when_the_config_is_missing() {
  _shell_probe_copy
  make_stub git
  _curl_stub
  _starship_stub
  _probe "$SHELL_PROBE" 'DOTFILES_OS=darwin
configure_dotfiles'
  assert_rc 0
  assert_called "starship preset gruvbox-rainbow -o $HOME/.config/starship.toml" \
    "a missing starship.toml must be generated"
  assert_file_exists "$HOME/.config/starship.toml"

  printf '%s\n' '# hand-tuned by the user' >"$HOME/.config/starship.toml"
  cp "$HOME/.config/starship.toml" "$TEST_TMP/starship.snapshot"
  reset_calls
  _probe "$SHELL_PROBE" 'DOTFILES_OS=darwin
configure_dotfiles'
  assert_rc 0
  assert_not_called "starship preset" "an existing starship.toml must never be regenerated"
  assert_same_file "$HOME/.config/starship.toml" "$TEST_TMP/starship.snapshot" \
    "user edits in starship.toml must survive"
}

# ---------------------------------------------------------------------------
# 5. chsh: skipped when already zsh, otherwise exactly once
# ---------------------------------------------------------------------------

test_activate_zsh_skips_chsh_when_already_zsh_and_runs_it_once_otherwise() {
  _shell_probe_copy
  make_stub chsh
  make_stub zsh
  _probe "$SHELL_PROBE" "DOTFILES_OS=darwin
DOTFILES_LOG_LEVEL=info
SHELL='$STUBS/zsh'
activate_zsh"
  assert_rc 0
  assert_eq 0 "$(_count_calls chsh)" "no chsh when the login shell is already zsh"
  assert_contains "$OUT" "skipping chsh"

  reset_calls
  _probe "$SHELL_PROBE" "DOTFILES_OS=darwin
SHELL=/bin/sh
activate_zsh"
  assert_rc 0
  assert_eq 1 "$(_count_calls chsh)" "chsh must run exactly once for a foreign shell"
  assert_called "chsh -s $STUBS/zsh" "chsh must be pointed at the resolved zsh"
}

# ---------------------------------------------------------------------------
# 6. --yes can never uninstall Homebrew
# ---------------------------------------------------------------------------

test_assume_yes_never_uninstalls_an_existing_homebrew() {
  _shell_probe_copy
  _brew_stub
  _curl_stub
  # stdin closed: the strict prompt falls back to its default (no).
  _probe "$SHELL_PROBE" 'DOTFILES_OS=darwin
DOTFILES_LOG_LEVEL=info
DOTFILES_ASSUME_YES=1
install_homebrew'
  assert_rc 0
  assert_not_called "uninstall" "DOTFILES_ASSUME_YES must not answer the strict prompt"
  assert_contains "$OUT" "Keeping existing Homebrew installation."
  assert_contains "$(cat "$HOME/.zshrc")" "# >>> dotfiles:homebrew >>>" \
    "the kept Homebrew must still be configured"

  # explicit "n" while --yes is set: still no uninstaller.
  reset_calls
  _probe_stdin 'n
' "$SHELL_PROBE" 'DOTFILES_OS=darwin
DOTFILES_LOG_LEVEL=info
DOTFILES_ASSUME_YES=1
install_homebrew'
  assert_rc 0
  assert_not_called "uninstall" "an explicit no must win over --yes"
}

test_explicit_yes_still_reinstalls_homebrew() {
  _shell_probe_copy
  _brew_stub
  _curl_stub
  _probe_stdin 'y
' "$SHELL_PROBE" 'DOTFILES_OS=darwin
install_homebrew'
  assert_rc 0
  assert_called "uninstall.sh" "a real yes must still be able to reinstall"
}

# ---------------------------------------------------------------------------
# 7. safe symlinks + alacritty transparency
# ---------------------------------------------------------------------------

test_configure_dotfiles_links_configs_and_creates_no_backup_on_rerun() {
  _shell_probe_copy
  make_stub git
  _curl_stub
  _starship_stub
  _probe "$SHELL_PROBE" 'DOTFILES_OS=darwin
configure_dotfiles'
  assert_rc 0
  assert_eq "$REPO_COPY/alacritty" "$(readlink "$HOME/.config/alacritty")" "alacritty link"
  assert_eq "$REPO_COPY/btop" "$(readlink "$HOME/.config/btop")" "btop link"
  assert_eq "$REPO_COPY/tmux" "$(readlink "$HOME/.config/tmux")" "tmux link"
  assert_eq "$REPO_COPY/vim/.vimrc" "$(readlink "$HOME/.vimrc")" "vimrc link"
  assert_eq "$REPO_COPY/vim/plugins" "$(readlink "$HOME/.config/vim/plugins")" "vim plugins link"

  local backups_first backups_second
  backups_first="$(find "$HOME" -name '*.bak.*' | wc -l | tr -d ' ')"
  reset_calls
  _probe "$SHELL_PROBE" 'DOTFILES_OS=darwin
configure_dotfiles'
  assert_rc 0
  backups_second="$(find "$HOME" -name '*.bak.*' | wc -l | tr -d ' ')"
  assert_eq "$backups_first" "$backups_second" \
    "an idempotent second run must not create another .bak.*"
  assert_eq "$REPO_COPY/alacritty" "$(readlink "$HOME/.config/alacritty")" \
    "links must still point at the repo after a re-run"
}

test_alacritty_transparency_is_disabled_only_on_non_darwin() {
  _shell_probe_copy
  make_stub git
  _curl_stub
  _starship_stub
  _probe "$SHELL_PROBE" 'DOTFILES_OS=darwin
configure_dotfiles'
  assert_rc 0
  assert_contains "$(cat "$HOME/.config/alacritty/alacritty.toml")" \
    'decorations = "Transparent"' "darwin keeps the transparent window"

  # Same installed copy (a symlink into the repo copy), now as linux: the
  # marker must be rewritten there.
  _probe "$SHELL_PROBE" 'DOTFILES_OS=linux
configure_dotfiles'
  assert_rc 0
  assert_contains "$(cat "$HOME/.config/alacritty/alacritty.toml")" \
    'decorations = "None"' "non-darwin needs opaque decorations"
  assert_not_contains "$(cat "$HOME/.config/alacritty/alacritty.toml")" \
    'decorations = "Transparent"'
}

# ~/.zshrc is often a symlink into a dotfiles repo. setup_zsh edits it with
# sed; that must go through the link (BSD sed used to abort halfway through,
# GNU sed would have replaced the link with a regular file).
test_symlinked_zshrc_stays_a_symlink_and_gets_the_plugins() {
  _shell_probe_copy
  _seed_omz
  make_stub git
  mkdir -p "$TEST_TMP/dotfiles-src"
  cat >"$TEST_TMP/dotfiles-src/zshrc" <<'RC'
export ZSH="$HOME/.oh-my-zsh"
plugins=(git)
source $ZSH/oh-my-zsh.sh
export EDITOR=vim
RC
  ln -s "$TEST_TMP/dotfiles-src/zshrc" "$HOME/.zshrc"
  _probe "$SHELL_PROBE" 'DOTFILES_OS=darwin
setup_zsh'
  assert_rc 0 "setup_zsh must not abort on a symlinked ~/.zshrc"
  [ -L "$HOME/.zshrc" ] || fail "the home zshrc was replaced by a regular file"
  assert_contains "$(cat "$TEST_TMP/dotfiles-src/zshrc")" "$(_expected_plugins)" \
    "the plugins line was written into the file the link points to"
  assert_contains "$(cat "$TEST_TMP/dotfiles-src/zshrc")" "export EDITOR=vim" \
    "user content preserved"
}
