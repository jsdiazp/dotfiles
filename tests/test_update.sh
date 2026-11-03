#!/usr/bin/env bash
# test_update.sh — scripts/unix/update.sh: the per-ecosystem updater registry,
# the summary table, failure isolation and platform dispatch.
#
# Pins down real bugs / destructive-action guards:
#   - Homebrew: `brew upgrade` already upgrades casks, so the extra
#     `brew upgrade --cask` pass was a double upgrade; `brew doctor` is noise
#     and must stay out of a default (warn) run.
#   - Exactly one summary row per ecosystem: an earlier version recorded each
#     updater twice, so the counts line lied about failures.
#   - One failing ecosystem must not abort the rest (npm failing still lets
#     Yarn cache and Composer run) but must fail the script (exit 1) and show
#     the failing step's output.
#   - A tool missing from PATH is SKIP, never FAIL, and does not fail the run.
#   - Housekeeping is best-effort: a failing `brew autoremove`/`brew cleanup`
#     must not fail the Homebrew row or the exit status; a failing
#     `brew upgrade` must.
#   - Linux: apt-get goes through sudo only when not root, in one exact order,
#     and never touches the macOS tools (softwareupdate/mas).
#   - Oh My Zsh is upgraded through tools/upgrade.sh (`omz update
#     --unattended` was removed upstream); SKIP when not installed.

# TEST_BASH and TEST_ZSH are exported by tests/run.sh, not assigned here.
# shellcheck disable=SC2153

# install_stubs — every tool update.sh can reach, as ONE dispatcher script
# plus symlinks. Real ones (gem, apt-get, softwareupdate...) exist on some
# hosts, so a test that forgets one would run it for real: this list is never
# optional. A single inode also keeps the suite fast on macOS, where each
# freshly created executable is scanned on first exec.
# Behaviour is selected by the invoked name; STUB_FAIL is a space-separated
# list of "<tool>" (always fail) or "<tool>:<subcommand>" (fail that one call).
install_stubs() {
  local dir="$STUBS" tool
  mkdir -p "$dir"
  cat >"$dir/_dotfiles_stub" <<'EOF'
#!/bin/sh
name=${0##*/}
if [ "$#" -gt 0 ]; then
  printf '%s %s\n' "$name" "$*" >>"$CALLS"
else
  printf '%s\n' "$name" >>"$CALLS"
fi
case "$name" in
  sudo)
    exec "$@"
    ;;
  uname)
    case "${1:-}" in
      -s) printf '%s\n' "${STUB_UNAME:-Darwin}" ;;
      -r) printf '%s\n' "${STUB_RELEASE:-5.15.0-generic}" ;;
      -m) printf 'x86_64\n' ;;
      *) printf '%s\n' "${STUB_UNAME:-Darwin}" ;;
    esac
    ;;
  id)
    if [ "${1:-}" = "-u" ]; then
      printf '%s\n' "${STUB_UID:-1000}"
    else
      exec /usr/bin/id "$@"
    fi
    ;;
  *)
    for sel in ${STUB_FAIL:-}; do
      case "$sel" in
        "$name")
          printf '%s: simulated failure\n' "$name" >&2
          exit 1
          ;;
        "$name:"*)
          if [ "${1:-}" = "${sel#*:}" ]; then
            printf '%s %s: simulated failure\n' "$name" "$1" >&2
            exit 1
          fi
          ;;
      esac
    done
    ;;
esac
exit 0
EOF
  chmod +x "$dir/_dotfiles_stub"
  for tool in sudo uname id apt-get snap flatpak softwareupdate mas brew npm gem; do
    ln -sfn _dotfiles_stub "$dir/$tool"
  done
}

# install_optional_tools — the tools whose absence is itself under test.
install_optional_tools() {
  local tool
  for tool in pod yarn composer; do
    ln -sfn _dotfiles_stub "$STUBS/$tool"
  done
}

# stub_everything — every external tool update.sh can reach, all succeeding.
stub_everything() {
  install_stubs
  install_optional_tools
  make_nvm_stub
}

# make_nvm_stub — nvm is a shell function sourced from $NVM_DIR/nvm.sh.
make_nvm_stub() {
  mkdir -p "$TEST_TMP/nvm"
  cat >"$TEST_TMP/nvm/nvm.sh" <<'EOF'
nvm() {
  printf 'nvm %s\n' "$*" >>"$CALLS"
  return 0
}
EOF
}

# make_omz_stub — a fake Oh My Zsh checkout whose tools/upgrade.sh logs.
make_omz_stub() {
  mkdir -p "$TEST_TMP/omz/tools"
  cat >"$TEST_TMP/omz/tools/upgrade.sh" <<'EOF'
#!/bin/sh
printf 'omz-upgrade %s\n' "$*" >>"$CALLS"
EOF
  chmod +x "$TEST_TMP/omz/tools/upgrade.sh"
}

# run_update [VAR=value...] — run the real update.sh. Extra assignments come
# after the defaults (for `env`, the last assignment wins).
run_update() {
  run env STUB_UNAME=Darwin STUB_UID=1000 STUB_RELEASE=5.15.0-generic \
    NVM_DIR="$TEST_TMP/nvm" ZSH="$TEST_TMP/omz" \
    "$@" "$TEST_BASH" "$REPO_ROOT/scripts/unix/update.sh"
}

# summary_rows <output> — the summary table's row lines only.
summary_rows() {
  printf '%s\n' "$1" | sed -n '/Update summary/,$p' |
    grep '^  ' | grep -v '^  STEP' | grep -v ' ok, '
}

# row_for <rows> <label> — the summary row whose label is <label>.
row_for() {
  printf '%s\n' "$1" | while IFS= read -r _row; do
    case "$_row" in
      "  $2 "*) printf '%s\n' "$_row" && break ;;
    esac
  done
}

# rows_matching <rows> <label> — how many rows carry that label.
rows_matching() {
  printf '%s\n' "$1" | grep -cF -- "  $2 " || true
}

# counts_line <output> — "<ok> <failed> <skipped>" from the counts line.
counts_line() {
  printf '%s\n' "$1" | awk '
    /^  [0-9]+ ok, [0-9]+ failed, [0-9]+ skipped$/ { printf "%s %s %s\n", $1, $3, $5 }
  '
}

# call_args <tool> — one line per logged "<tool> ..." call, argv only.
call_args() {
  calls | awk -v t="$1" '$1 == t { sub(/^[^ ]+ /, ""); print }'
}

# sudo_call_args <tool> — argv of "sudo <tool> ..." calls.
sudo_call_args() {
  calls | awk -v t="$1" '$1 == "sudo" && $2 == t { sub(/^sudo [^ ]+ /, ""); print }'
}

test_darwin_tool_calls_and_summary() {
  stub_everything
  make_omz_stub
  run_update
  assert_rc 0

  # brew: update, upgrade, autoremove, cleanup — in that order, and nothing
  # else (no `upgrade --cask`, no `doctor` at the default warn level).
  assert_eq "update upgrade autoremove cleanup" \
    "$(call_args brew | tr '\n' ' ' | sed 's/ $//')" \
    "brew subcommands and order"
  assert_not_called "upgrade --cask" "brew upgrade already covers casks"
  assert_not_called "brew doctor" "brew doctor is debug/info only"
  assert_called "sudo softwareupdate -i -a" "macOS updates must run through sudo"
  assert_called "mas upgrade"

  # Exactly one summary row per ecosystem (an earlier version doubled them).
  local rows label
  rows="$(summary_rows "$OUT")"
  assert_eq "10" "$(printf '%s\n' "$rows" | grep -c .)" \
    "one summary row per ecosystem"
  for label in "macOS" "Mac App Store" "Node.js (nvm)" "RubyGems" \
    "CocoaPods cache" "Homebrew" "npm" "Yarn cache" "Composer" "Oh My Zsh"; do
    assert_eq "1" "$(rows_matching "$rows" "$label")" \
      "exactly one summary row for $label"
  done
  assert_eq "0 10" "$(counts_line "$OUT" | awk '{ print $2, $1 + $3 }')" \
    "counts line must report 0 failed and 10 ecosystems"

  # `brew doctor` only while debugging.
  reset_calls
  run_update DOTFILES_LOG_LEVEL=info
  assert_rc 0
  assert_called "brew doctor" "brew doctor must run at info level"
}

test_failing_ecosystem_is_isolated() {
  stub_everything
  make_omz_stub
  run_update STUB_FAIL=npm
  assert_rc 1 "a failing ecosystem must fail the run"

  local rows
  rows="$(summary_rows "$OUT")"
  assert_contains "$(row_for "$rows" npm)" "FAIL" "npm row must be FAIL"
  assert_contains "$OUT" "[FAIL] npm" "the failing step must be reported"
  assert_contains "$OUT" "npm: simulated failure" \
    "the failing step's output must be shown"

  # Later steps still ran and are listed.
  assert_called "yarn cache clean"
  assert_called "composer global update"
  assert_contains "$(row_for "$rows" "Yarn cache")" "OK" \
    "Yarn cache must still run after npm failed"
  assert_contains "$(row_for "$rows" Composer)" "OK" \
    "Composer must still run after npm failed"
  assert_eq "1 9" "$(counts_line "$OUT" | awk '{ print $2, $1 + $3 }')" \
    "counts line must report the single failure"
}

test_missing_tool_is_skip_not_fail() {
  # composer/pod/yarn are not in /usr/bin or /bin on macOS or Ubuntu.
  local tool
  for tool in composer pod yarn; do
    if command -v "$tool" >/dev/null 2>&1; then
      skip "$tool is on PATH; the missing-tool path cannot be tested"
    fi
  done
  install_stubs
  make_nvm_stub

  run_update
  assert_rc 0 "a missing tool must not fail the run"

  local rows
  rows="$(summary_rows "$OUT")"
  assert_contains "$(row_for "$rows" "CocoaPods cache")" "SKIP"
  assert_contains "$(row_for "$rows" "Yarn cache")" "SKIP"
  assert_contains "$(row_for "$rows" Composer)" "SKIP"
  assert_contains "$OUT" "[skip] CocoaPods cache"
  assert_eq "0 10" "$(counts_line "$OUT" | awk '{ print $2, $1 + $3 }')" \
    "skips are not failures"
}

test_brew_housekeeping_is_best_effort() {
  # A failing autoremove or cleanup must not fail the Homebrew row/run.
  # info level so the captured warnings stream instead of being discarded.
  stub_everything
  make_omz_stub
  run_update STUB_FAIL=brew:autoremove DOTFILES_LOG_LEVEL=info
  assert_rc 0 "brew autoremove is best-effort"
  assert_contains "$OUT" "WARN: brew autoremove failed"
  assert_contains "$(row_for "$(summary_rows "$OUT")" Homebrew)" "OK" \
    "a failed autoremove must not fail the Homebrew row"

  run_update STUB_FAIL=brew:cleanup DOTFILES_LOG_LEVEL=info
  assert_rc 0 "brew cleanup is best-effort"
  assert_contains "$OUT" "WARN: brew cleanup failed"
  assert_contains "$(row_for "$(summary_rows "$OUT")" Homebrew)" "OK" \
    "a failed cleanup must not fail the Homebrew row"

  # ...but a failed `brew upgrade` is a real failure.
  run_update STUB_FAIL=brew:upgrade DOTFILES_LOG_LEVEL=info
  assert_rc 1 "a failed brew upgrade must fail the run"
  assert_contains "$(row_for "$(summary_rows "$OUT")" Homebrew)" "FAIL"
  assert_contains "$OUT" "[FAIL] Homebrew"
}

test_linux_apt_order_and_sudo() {
  stub_everything
  run_update STUB_UNAME=Linux
  assert_rc 0
  assert_eq "update full-upgrade -y autoremove -y autoclean -y" \
    "$(sudo_call_args apt-get | tr '\n' ' ' | sed 's/ $//')" \
    "apt-get calls through sudo, in order"
  assert_not_called "softwareupdate" "Linux must not touch macOS updates"
  assert_not_called "mas " "Linux must not touch the Mac App Store"

  # Root: no sudo at all.
  reset_calls
  run_update STUB_UNAME=Linux STUB_UID=0
  assert_rc 0
  assert_eq "update full-upgrade -y autoremove -y autoclean -y" \
    "$(call_args apt-get | tr '\n' ' ' | sed 's/ $//')" \
    "as root apt-get runs directly, in order"
  assert_eq "0" "$(calls | grep -c '^sudo ' || true)" "root must not call sudo"
}

test_oh_my_zsh_upgrade_script_and_skip() {
  [ -n "$TEST_ZSH" ] || skip "no zsh available"
  install_stubs
  make_nvm_stub
  make_omz_stub

  run_update
  assert_rc 0
  assert_called "omz-upgrade" "Oh My Zsh must be updated via tools/upgrade.sh"
  assert_contains "$(row_for "$(summary_rows "$OUT")" "Oh My Zsh")" "OK"

  # Not installed -> SKIP row, run still succeeds.
  reset_calls
  run_update ZSH="$TEST_TMP/no-omz-here"
  assert_rc 0
  assert_contains "$(row_for "$(summary_rows "$OUT")" "Oh My Zsh")" "SKIP"
  assert_not_called "omz-upgrade"
}
