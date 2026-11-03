#!/usr/bin/env bash
# test_primitives.sh — pins down confirm/as_root/os_family and the idempotency
# primitives (sed_inplace, append_once, safe_link, backup_once,
# clone_or_update) from scripts/shared/common.sh, plus display_menu from
# scripts/shared/menu.sh.
#
# These are the safety-critical helpers: each one guards a real incident or a
# destructive action, so a regression must fail CI:
#   * confirm: y/yes/Y -> 0; n/empty/EOF -> default; DOTFILES_ASSUME_YES=1
#     answers without reading stdin, EXCEPT for `strict` prompts (so --yes can
#     never answer a "reinstall Homebrew from scratch?" question).
#   * as_root: sudo only when non-root AND sudo exists; sudo_warm never
#     prompts off a TTY.
#   * sed_inplace works with spaces in the path and leaves no backup debris.
#   * append_once writes its marked block exactly once (re-runs used to
#     duplicate fzf/starship/zoxide blocks) and creates missing parent dirs.
#   * safe_link / backup_once / clone_or_update fail closed: a failed backup
#     must never be followed by rm -rf, so user data stays byte-identical.
#   * os_family: darwin / linux / wsl (Microsoft kernel release).
#   * display_menu: 1-based selection, b=back(1), EOF=3, re-prompts on
#     invalid input, MENU_DEFAULT on bare Enter, and no `_menu*` variable
#     leaks out of the call.

# confirm_probe <stdin-text> [default] [strict] [assume-yes] — answer confirm
# with the given stdin and print YES/NO.
confirm_probe() {
  local input="$1" default="${2:-n}" strict="${3:-}" assume="${4:-}"
  run_stdin "$input" "$TEST_BASH" -c '
DOTFILES_ASSUME_YES="$3"
export DOTFILES_ASSUME_YES
. "$REPO_ROOT/scripts/shared/common.sh"
if confirm "Go?" "$1" "$2"; then echo YES; else echo NO; fi
' _ "$default" "$strict" "$assume"
}

test_confirm_accepts_yes_variants() {
  local answer
  for answer in y yes Y YES; do
    confirm_probe "$answer"$'\n'
    assert_rc 0 "confirm must accept [$answer]"
    assert_contains "$OUT" "YES"
    assert_contains "$OUT" "[n]" "the prompt shows the default"
  done
}

test_confirm_no_empty_and_eof_use_the_default() {
  confirm_probe "n"$'\n'
  assert_rc 0 "the probe itself exits 0"
  assert_contains "$OUT" "NO" "n is a no"

  confirm_probe $'\n'
  assert_contains "$OUT" "NO" "empty input falls back to default n"

  # EOF: run() closes stdin, so read hits end-of-file.
  run "$TEST_BASH" -c '
. "$REPO_ROOT/scripts/shared/common.sh"
if confirm "Go?"; then echo YES; else echo NO; fi
'
  assert_rc 0
  assert_contains "$OUT" "NO" "EOF falls back to default n"

  confirm_probe $'\n' y
  assert_contains "$OUT" "YES" "default y answers yes on empty input"
}

test_confirm_assume_yes_answers_without_reading_stdin() {
  # Feed "n": if confirm reads stdin at all, the answer would be NO.
  confirm_probe "n"$'\n' n "" 1
  assert_rc 0
  assert_contains "$OUT" "YES" "DOTFILES_ASSUME_YES must win"
  assert_contains "$OUT" "[auto-yes]" "the auto answer is announced"
}

test_confirm_strict_ignores_assume_yes() {
  confirm_probe "n"$'\n' n strict 1
  assert_rc 0
  assert_contains "$OUT" "NO" "strict must read stdin even with ASSUME_YES"

  confirm_probe "y"$'\n' n strict 1
  assert_contains "$OUT" "YES" "strict accepts an explicit y"

  confirm_probe "" n strict 1
  assert_contains "$OUT" "NO" "strict + EOF uses the default, never auto-yes"
  assert_not_contains "$OUT" "[auto-yes]" "strict must not print the auto-yes line"
}

test_as_root_uses_sudo_only_when_needed() {
  make_stub probe_cmd
  make_sudo_passthrough
  make_id 501
  run "$TEST_BASH" -c '
set -u
. "$REPO_ROOT/scripts/shared/common.sh"
as_root probe_cmd "arg one"
'
  assert_rc 0
  assert_called "sudo probe_cmd arg one" "non-root goes through sudo"
  assert_called "probe_cmd arg one" "the command really ran"

  reset_calls
  make_id 0
  run "$TEST_BASH" -c '
set -u
. "$REPO_ROOT/scripts/shared/common.sh"
as_root probe_cmd "arg one"
'
  assert_rc 0
  assert_called "probe_cmd arg one" "root runs the command itself"
  assert_not_called "sudo" "root must never call sudo"

  # No sudo anywhere: PATH holds only the id stub, so have_cmd sudo fails.
  reset_calls
  make_id 501
  mkdir -p "$TEST_TMP/minbin"
  cp "$STUBS/id" "$TEST_TMP/minbin/id"
  run "$TEST_BASH" -c '
set -u
. "$REPO_ROOT/scripts/shared/common.sh"
PATH="$TEST_TMP/minbin"
as_root echo "no-sudo-probe"
'
  assert_rc 0
  assert_contains "$OUT" "no-sudo-probe" "without sudo the command runs directly"
  assert_no_calls "no sudo available means nothing is logged"
}

test_sudo_warm_is_silent_off_a_tty() {
  make_stub sudo 0
  make_id 501
  run "$TEST_BASH" -c '
set -u
. "$REPO_ROOT/scripts/shared/common.sh"
sudo_warm
printf "warm-rc=%s\n" "$?"
sudo_warm
printf "warm2-rc=%s\n" "$?"
'
  assert_rc 0
  assert_contains "$OUT" "warm-rc=0"
  assert_contains "$OUT" "warm2-rc=0" "already warmed is still a no-op"
  assert_not_called "sudo" "sudo_warm must not prompt when stdin is not a TTY"
}

# count_entries <dir> <find-name-pattern> — number of entries directly in <dir>
# whose name matches the pattern (hidden files included, no ls|grep).
count_entries() {
  find "$1" -mindepth 1 -maxdepth 1 -name "$2" | wc -l | tr -d ' '
}

test_sed_inplace_edits_spaces_and_leaves_no_backup() {
  local dir="$TEST_TMP/dir with space"
  local file="$dir/my file.conf"
  mkdir -p "$dir"
  printf 'setting=old\nkeep=me\n' >"$file"
  run "$TEST_BASH" -c '
set -u
. "$REPO_ROOT/scripts/shared/common.sh"
sed_inplace "s/setting=old/setting=new/" "$TEST_TMP/dir with space/my file.conf"
'
  assert_rc 0
  assert_contains "$(cat "$file")" "setting=new" "the edit landed"
  assert_contains "$(cat "$file")" "keep=me" "other lines untouched"
  assert_no_file "$file.bak" "no .bak file on either BSD or GNU sed"
  assert_eq 1 "$(count_entries "$dir" '*')" "exactly one file, no debris"
}

test_append_once_writes_one_marked_block() {
  local file="$TEST_TMP/conf/.zshrc"
  local fresh="$TEST_TMP/new/deep/tools.conf"
  mkdir -p "$TEST_TMP/conf"
  printf 'preexisting-line\n' >"$file"
  run "$TEST_BASH" -c '
set -u
. "$REPO_ROOT/scripts/shared/common.sh"
append_once "$TEST_TMP/conf/.zshrc" zoxide "eval \"\$(zoxide init zsh)\""
append_once "$TEST_TMP/conf/.zshrc" zoxide "eval \"\$(zoxide init zsh)\""
append_once "$TEST_TMP/new/deep/tools.conf" keys "bindkey -v"
'
  assert_rc 0
  assert_contains "$(cat "$file")" "preexisting-line" "existing content preserved"
  assert_eq 1 "$(grep -cF '# >>> dotfiles:zoxide >>>' "$file" || true)" "one begin marker"
  assert_eq 1 "$(grep -cF '# <<< dotfiles:zoxide <<<' "$file" || true)" "one end marker"
  assert_eq 1 "$(grep -cF 'zoxide init zsh' "$file" || true)" "one payload line"
  assert_file_exists "$fresh" "a missing file (and its dirs) is created"
  assert_contains "$(cat "$fresh")" "# >>> dotfiles:keys >>>"
  assert_contains "$(cat "$fresh")" "bindkey -v"
}

test_safe_link_is_idempotent_and_backs_up_real_file() {
  local dir="$TEST_TMP/link dir"
  local rep="$TEST_TMP/replace"
  mkdir -p "$dir" "$rep"
  printf 'payload\n' >"$dir/src file"
  ln -s "$dir/src file" "$dir/dst"
  run "$TEST_BASH" -c '
set -u
. "$REPO_ROOT/scripts/shared/common.sh"
safe_link "$TEST_TMP/link dir/src file" "$TEST_TMP/link dir/dst"
'
  assert_rc 0
  assert_eq "$dir/src file" "$(readlink "$dir/dst")" "the correct symlink is kept"
  assert_eq 0 "$(count_entries "$dir" '*.bak.*')" "a no-op creates no backup"

  printf 'new source data\n' >"$rep/src"
  printf 'old destination data\n' >"$rep/dst"
  printf 'old destination data\n' >"$rep/expected"
  local bak
  run "$TEST_BASH" -c '
set -u
. "$REPO_ROOT/scripts/shared/common.sh"
safe_link "$TEST_TMP/replace/src" "$TEST_TMP/replace/dst"
'
  assert_rc 0
  if [ ! -L "$rep/dst" ]; then fail "destination must become a symlink"; fi
  assert_eq "$rep/src" "$(readlink "$rep/dst")"
  assert_eq 1 "$(count_entries "$rep" 'dst.bak.*')" "exactly one backup"
  bak="$(find "$rep" -mindepth 1 -maxdepth 1 -name 'dst.bak.*' | head -1)"
  assert_same_file "$bak" "$rep/expected" "the backup holds the old content"
}

test_safe_link_refuses_when_backup_fails() {
  local dir="$TEST_TMP/cpfail"
  mkdir -p "$dir"
  printf 'precious data\n' >"$dir/dst"
  printf 'precious data\n' >"$dir/expected"
  printf 'source data\n' >"$dir/src"
  make_stub cp 1
  run "$TEST_BASH" -c '
set -u
. "$REPO_ROOT/scripts/shared/common.sh"
if safe_link "$TEST_TMP/cpfail/src" "$TEST_TMP/cpfail/dst"; then
  echo "safe_link-rc=0"
else
  echo "safe_link-rc=$?"
fi
'
  assert_contains "$OUT" "safe_link-rc=1" "a failed backup must fail safe_link"
  assert_called "cp -a" "it must actually attempt the backup"
  assert_same_file "$dir/dst" "$dir/expected" "destination must stay byte-identical"
  if [ -L "$dir/dst" ]; then fail "destination must never be replaced after a failed backup"; fi
}

test_backup_once_and_clone_or_update_fail_closed() {
  mkdir -p "$TEST_TMP/bk"
  printf 'x\n' >"$TEST_TMP/bk/file"
  make_stub cp 1
  run "$TEST_BASH" -c '
set -u
. "$REPO_ROOT/scripts/shared/common.sh"
if backup_once "$TEST_TMP/bk/file"; then echo "backup-rc=0"; else echo "backup-rc=$?"; fi
'
  assert_contains "$OUT" "backup-rc=1" "backup_once reports a failed copy"
  assert_called "cp -a" "backup_once must attempt the copy"

  mkdir -p "$TEST_TMP/clone/dest"
  printf 'keep me\n' >"$TEST_TMP/clone/dest/file"
  printf 'keep me\n' >"$TEST_TMP/clone/expected"
  make_stub git 0
  run "$TEST_BASH" -c '
set -u
. "$REPO_ROOT/scripts/shared/common.sh"
if clone_or_update "https://example.invalid/x.git" "$TEST_TMP/clone/dest"; then
  echo "clone-rc=0"
else
  echo "clone-rc=$?"
fi
'
  assert_contains "$OUT" "clone-rc=1" "clone_or_update fails when the backup fails"
  assert_not_called "git clone" "it must never clone over unbacked-up data"
  assert_same_file "$TEST_TMP/clone/dest/file" "$TEST_TMP/clone/expected" "destination intact"
}

test_os_family_detects_darwin_linux_wsl() {
  make_uname Darwin 23.0.0
  run "$TEST_BASH" -c '
set -u
. "$REPO_ROOT/scripts/shared/common.sh"
os_family
'
  assert_rc 0
  assert_eq "darwin" "$OUT" "Darwin"

  make_uname Linux 5.15.0-generic
  run "$TEST_BASH" -c '
set -u
. "$REPO_ROOT/scripts/shared/common.sh"
os_family
'
  assert_rc 0
  assert_eq "linux" "$OUT" "plain Linux"

  make_uname Linux 5.15.0-microsoft-standard-WSL2
  run "$TEST_BASH" -c '
set -u
. "$REPO_ROOT/scripts/shared/common.sh"
os_family
'
  assert_rc 0
  assert_eq "wsl" "$OUT" "Linux with a Microsoft release is WSL"
}

# menu_probe <stdin-text> [setup-lines] — run display_menu with three options
# and print the rc/choice/mirror plus any leaked `_menu*` variable.
menu_probe() {
  local input="$1" setup="${2:-}"
  run_stdin "$input" "$TEST_BASH" -c '
set -u
. "$REPO_ROOT/scripts/shared/common.sh"
. "$REPO_ROOT/scripts/shared/menu.sh"
MENU_CLEAR=0
MENU_USE_FZF=never
'"$setup"'
display_menu "Pick a target" alpha beta gamma
_dm_rc=$?
printf "MENU rc=%s choice=[%s] mirror=[%s]\n" "$_dm_rc" "$MENU_CHOICE" "$choice"
printf "LEAK[%s]\n" "$(set | grep "^_menu[A-Za-z0-9_]*=" || true)"
exit "$_dm_rc"
'
}

test_menu_returns_number_back_and_eof() {
  menu_probe "2"$'\n'
  assert_rc 0 "a valid number returns 0"
  assert_contains "$OUT" "choice=[2]"
  assert_contains "$OUT" "mirror=[2]" "the legacy choice mirror is set"
  assert_contains "$OUT" "LEAK[]" "no _menu* variable leaks out of display_menu"

  menu_probe "b"$'\n'
  assert_rc 1 "b means back"
  assert_contains "$OUT" "choice=[b]"

  menu_probe ""
  assert_rc 3 "EOF must return 3 instead of looping forever"
  assert_contains "$OUT" "LEAK[]" "no _menu* variable leaks out of display_menu"
}

test_menu_reprompts_on_invalid_input() {
  menu_probe "x"$'\n'"3"$'\n'
  assert_rc 0 "a retry after bad input still selects"
  assert_contains "$OUT" "Wrong option" "non-numeric input is rejected"
  assert_contains "$OUT" "choice=[3]"

  menu_probe "0"$'\n'"1"$'\n'
  assert_rc 0
  assert_contains "$OUT" "Wrong option" "0 is out of range and rejected"
  assert_contains "$OUT" "choice=[1]"
}

test_menu_default_on_bare_enter() {
  menu_probe $'\n' "MENU_DEFAULT=2"
  assert_rc 0
  assert_contains "$OUT" "(Enter=2)" "the prompt advertises the default"
  assert_contains "$OUT" "choice=[2]" "bare Enter selects MENU_DEFAULT"
  assert_contains "$OUT" "LEAK[]" "no _menu* variable leaks out of display_menu"
}

# A symlinked file (typically ~/.zshrc -> a dotfiles repo) must be edited
# THROUGH the link: BSD sed errors on a symlink and GNU sed replaces it with a
# regular file. Either way the user's setup would silently break.
test_sed_inplace_edits_through_symlinks_and_keeps_them() {
  local src="$TEST_TMP/dotfiles-src"
  mkdir -p "$src" "$TEST_TMP/links"
  printf 'plugins=(git)\nkeep=me\n' >"$src/zshrc"
  ln -s "$src/zshrc" "$TEST_TMP/links/direct"
  ln -s "../links/direct" "$TEST_TMP/links/chain"
  run "$TEST_BASH" -c '
set -u
. "$REPO_ROOT/scripts/shared/common.sh"
sed_inplace "s/plugins=(git)/plugins=(git docker)/" "$TEST_TMP/links/chain"
'
  assert_rc 0
  [ -L "$TEST_TMP/links/chain" ] || fail "the symlink was replaced by a regular file"
  [ -L "$TEST_TMP/links/direct" ] || fail "the link chain was broken"
  assert_contains "$(cat "$src/zshrc")" "plugins=(git docker)" "the real file was edited"
  assert_contains "$(cat "$src/zshrc")" "keep=me" "other lines untouched"
}

test_sed_inplace_refuses_a_symlink_loop() {
  mkdir -p "$TEST_TMP/loop"
  ln -s b "$TEST_TMP/loop/a"
  ln -s a "$TEST_TMP/loop/b"
  run "$TEST_BASH" -c '
set -u
. "$REPO_ROOT/scripts/shared/common.sh"
sed_inplace "s/x/y/" "$TEST_TMP/loop/a"
'
  assert_rc 1 "a symlink cycle is an error, not a hang"
  assert_contains "$OUT" "Too many levels of symbolic links"
}
