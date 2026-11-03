#!/usr/bin/env bash
# test_servers.sh — regression gates for scripts/servers/ubuntu.sh,
# scripts/unix/docker.sh and scripts/unix/swap.sh.
#
# What this file pins down (each was a real bug or a destructive-action guard):
#   1. ubuntu.sh is consent-gated: stdin closed or "n" exits 0 with
#      "Aborted, nothing changed." and NOT A SINGLE command runs (the script
#      wipes /nix, Linuxbrew, ~/.zshrc and ~/.nvm). The confirmation text lists
#      exactly those targets.
#   2. --yes / -y / DOTFILES_ASSUME_YES=1 skip the prompt and the first thing
#      that happens is `sudo apt-get update` (no accidental reordering, no
#      action before the gate).
#   3. An unknown argument prints usage, exits non-zero, and runs nothing.
#   4. user_zshrc_block writes the historic marked-block format exactly once
#      (duplicated fzf/starship blocks were the original bug), and recognises a
#      block written by the previous implementation.
#   5. docker.sh installs the apt repo in order: apt-get update, then
#      ca-certificates/curl, then docker-ce — and needs no sudo when root.
#   6. swap.sh: declining the resize exits without swapoff/rm; accepting it
#      does swapoff + rm through as_root; the fstab entry is appended once.
#
# Every privileged/destructive command is a logging stub. sudo always FAILS
# here, so nothing can get past the first privileged step.
# Style: bash 3.2 (macOS /bin/bash), no `set -e`, deterministic assertions only.

set -u

# ---------------------------------------------------------------------------
# Helpers (local to this file; tests/lib only holds generic helpers)
# ---------------------------------------------------------------------------

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

# _sourceable_copy <relative script> — copy the repo and write the script into
# the same directory with its final `main "$@"` removed. Prints its path.
_sourceable_copy() {
  local rel="$1" repo dest
  repo="$(make_repo_copy)"
  dest="$repo/scripts/${rel%/*}/probe_$(basename "$rel")"
  grep -v '^main "\$@"$' "$repo/scripts/$rel" >"$dest"
  assert_file_exists "$dest"
  printf '%s\n' "$dest"
}

# _stub_server_destruction — every privileged/destructive command logs only;
# sudo fails so the script cannot reach a second step.
_stub_server_destruction() {
  make_stub sudo 1
  make_stub rm
  make_stub userdel
  make_stub groupdel
  make_stub systemctl
  make_stub apt-get
  make_stub curl
  make_stub git
  make_stub chsh
}

# _first_call — the first logged call (empty when nothing ran).
_first_call() {
  calls | head -1
}

# _call_line_of <fixed-string> — 1-based line of its first call, empty if absent.
_call_line_of() {
  calls | grep -nF -- "$1" | head -1 | cut -d: -f1
}

# _curl_stub — logs the URL and prints a harmless script body (never network).
_curl_stub() {
  make_stub_body curl <<'EOF'
printf '%s\n' 'PUBKEY'
EOF
}

# _tee_discard_stub — logs and swallows stdin, so nothing can reach /etc.
_tee_discard_stub() {
  mkdir -p "$STUBS"
  cat >"$STUBS/tee" <<'EOF'
#!/bin/sh
printf 'tee %s\n' "$*" >>"$CALLS"
cat >/dev/null
EOF
  chmod +x "$STUBS/tee"
}

# _tee_append_stub — logs and appends stdin to the last path argument (used by
# the swap fstab test, where the real append must be observable in $TEST_TMP).
_tee_append_stub() {
  mkdir -p "$STUBS"
  cat >"$STUBS/tee" <<'EOF'
#!/bin/sh
printf 'tee %s\n' "$*" >>"$CALLS"
append=0
target=""
for a in "$@"; do
  case "$a" in
    -a | --append) append=1 ;;
    -*) : ;;
    *) target="$a" ;;
  esac
done
[ -n "$target" ] || exit 0
if [ "$append" -eq 1 ]; then
  cat >>"$target"
else
  cat >"$target"
fi
EOF
  chmod +x "$STUBS/tee"
}

# ---------------------------------------------------------------------------
# 1. Consent gate: nothing runs before an explicit yes
# ---------------------------------------------------------------------------

test_ubuntu_aborts_on_eof_and_runs_no_command() {
  _stub_server_destruction
  run "$TEST_BASH" "$REPO_ROOT/scripts/servers/ubuntu.sh"
  assert_rc 0 "aborting must be a clean exit"
  assert_contains "$OUT" "Aborted, nothing changed."
  assert_no_calls "the consent gate must come BEFORE any command"
  assert_contains "$OUT" "/nix" "the wipe list must name /nix"
  assert_contains "$OUT" "/home/linuxbrew" "the wipe list must name Linuxbrew"
  # shellcheck disable=SC2088 # the literal "~" is what the script prints.
  assert_contains "$OUT" "~/.zshrc" "the wipe list must name ~/.zshrc"
  # shellcheck disable=SC2088 # the literal "~" is what the script prints.
  assert_contains "$OUT" "~/.nvm" "the wipe list must name ~/.nvm"
}

test_ubuntu_aborts_on_explicit_no_and_runs_no_command() {
  _stub_server_destruction
  run_stdin 'n
' "$TEST_BASH" "$REPO_ROOT/scripts/servers/ubuntu.sh"
  assert_rc 0
  assert_contains "$OUT" "Aborted, nothing changed."
  assert_no_calls "answering no must not mutate anything"
}

# ---------------------------------------------------------------------------
# 2. --yes / -y / DOTFILES_ASSUME_YES=1 skip the prompt
# ---------------------------------------------------------------------------

test_ubuntu_yes_flags_skip_the_prompt_and_start_with_apt_update() {
  _stub_server_destruction
  run "$TEST_BASH" "$REPO_ROOT/scripts/servers/ubuntu.sh" --yes
  assert_rc 1 "with a failing sudo the first step must abort the run"
  assert_contains "$OUT" "[auto-yes]" "--yes must not read stdin"
  assert_eq "sudo apt-get update" "$(_first_call)" "--yes: first command"

  reset_calls
  run "$TEST_BASH" "$REPO_ROOT/scripts/servers/ubuntu.sh" -y
  assert_rc 1
  assert_contains "$OUT" "[auto-yes]" "-y must not read stdin"
  assert_eq "sudo apt-get update" "$(_first_call)" "-y: first command"

  reset_calls
  run env DOTFILES_ASSUME_YES=1 "$TEST_BASH" "$REPO_ROOT/scripts/servers/ubuntu.sh"
  assert_rc 1
  assert_contains "$OUT" "[auto-yes]" "DOTFILES_ASSUME_YES=1 must not read stdin"
  assert_eq "sudo apt-get update" "$(_first_call)" "env --yes: first command"
}

# ---------------------------------------------------------------------------
# 3. Unknown argument: usage + non-zero, still nothing runs
# ---------------------------------------------------------------------------

test_ubuntu_rejects_unknown_arguments_before_anything_runs() {
  _stub_server_destruction
  run "$TEST_BASH" "$REPO_ROOT/scripts/servers/ubuntu.sh" --bogus
  assert_rc 1
  assert_contains "$OUT" "Usage:"
  assert_contains "$OUT" "Unknown argument: --bogus"
  assert_no_calls "a bad argument must not touch the machine"
}

# ---------------------------------------------------------------------------
# 4. user_zshrc_block: historic format, written once
# ---------------------------------------------------------------------------

test_user_zshrc_block_writes_the_historic_format_exactly_once() {
  local ubuntu_probe
  ubuntu_probe="$(_sourceable_copy servers/ubuntu.sh)"
  printf '\n# >>> dotfiles:locale >>>\n# Locale\nexport LC_ALL=en_US.UTF-8\n# <<< dotfiles:locale <<<\n' \
    >"$TEST_TMP/expected.zshrc"

  _probe "$ubuntu_probe" 'user_zshrc_block "$HOME" locale "Locale" "export LC_ALL=en_US.UTF-8"
user_zshrc_block "$HOME" locale "Locale" "export LC_ALL=en_US.UTF-8"'
  assert_rc 0
  assert_same_file "$HOME/.zshrc" "$TEST_TMP/expected.zshrc" \
    "the block format must stay # >>> dotfiles:<id> >>> / # <comment> / <code>"
  assert_eq 1 "$(grep -c '^# >>> dotfiles:locale >>>$' "$HOME/.zshrc")" \
    "writing the same id twice must yield exactly one block"

  # A block left behind by the previous implementation is recognised.
  cp "$TEST_TMP/expected.zshrc" "$HOME/.zshrc"
  reset_calls
  _probe "$ubuntu_probe" 'user_zshrc_block "$HOME" locale "Locale" "export LC_ALL=en_US.UTF-8"'
  assert_rc 0
  assert_same_file "$HOME/.zshrc" "$TEST_TMP/expected.zshrc" \
    "an existing block must not be duplicated"
  assert_no_calls "writing to ~/.zshrc must not shell out"
}

# ---------------------------------------------------------------------------
# 5. docker.sh: repo first, then docker-ce; no sudo when root
# ---------------------------------------------------------------------------

# _docker_test_stubs — everything docker.sh may reach, none of it privileged.
_docker_test_stubs() {
  make_stub apt-get
  make_stub_body dpkg <<'EOF'
echo amd64
EOF
  make_stub_body lsb_release <<'EOF'
echo stable
EOF
  _curl_stub
  make_stub install
  _tee_discard_stub
  make_stub chmod
}

test_docker_installs_the_repo_then_docker_ce_in_order() {
  local docker_probe up deps docker
  docker_probe="$(_sourceable_copy unix/docker.sh)"
  make_sudo_passthrough
  _docker_test_stubs

  _probe "$docker_probe" 'install_docker_debian_ubuntu ubuntu'
  assert_rc 0 "install_docker_debian_ubuntu must succeed with stubs"
  assert_called "sudo apt-get update" "the package index must be refreshed"
  assert_called "sudo apt-get install -y ca-certificates curl" "deps first"
  assert_called "sudo tee /etc/apt/keyrings/docker.asc" "the Docker key must be added"

  up="$(_call_line_of "sudo apt-get update")"
  deps="$(_call_line_of "sudo apt-get install -y ca-certificates curl")"
  docker="$(_call_line_of "docker-ce docker-ce-cli")"
  [ -n "$up" ] && [ -n "$deps" ] && [ -n "$docker" ] ||
    fail "missing a docker step; calls were:
$(calls)"
  [ "$up" -lt "$deps" ] || fail "apt-get update must run before the dependency install"
  [ "$deps" -lt "$docker" ] || fail "the dependency install must run before docker-ce"
}

test_docker_needs_no_sudo_when_already_root() {
  local docker_probe
  docker_probe="$(_sourceable_copy unix/docker.sh)"
  make_sudo_passthrough
  make_id 0
  _docker_test_stubs

  _probe "$docker_probe" 'install_docker_debian_ubuntu ubuntu'
  assert_rc 0
  assert_not_called "sudo" "as_root must not use sudo when uid is 0"
  assert_called "apt-get install -y ca-certificates curl"
  assert_called "docker-ce docker-ce-cli"
}

# ---------------------------------------------------------------------------
# 6. swap.sh: resize consent, then the fstab guard
# ---------------------------------------------------------------------------

test_swap_declining_the_resize_touches_nothing() {
  local swap_probe
  swap_probe="$(_sourceable_copy unix/swap.sh)"
  make_sudo_passthrough
  make_stub swapoff
  make_stub rm
  : >"$TEST_TMP/swapfile"
  _probe "$swap_probe" "SWAPFILE='$TEST_TMP/swapfile'
create_swap_file"
  assert_rc 0 "declining must exit cleanly"
  assert_contains "$OUT" "Exiting without making changes."
  assert_no_calls "no swapoff/rm may run when the resize is declined"

  reset_calls
  _probe_stdin 'n
' "$swap_probe" "SWAPFILE='$TEST_TMP/swapfile'
create_swap_file"
  assert_rc 0
  assert_contains "$OUT" "Exiting without making changes."
  assert_no_calls "an explicit no must also run nothing"
}

test_swap_accepting_the_resize_swaps_off_and_removes_the_file() {
  local swap_probe
  swap_probe="$(_sourceable_copy unix/swap.sh)"
  make_sudo_passthrough
  make_stub swapoff
  make_stub rm
  make_stub fallocate
  make_stub_body awk <<'EOF'
echo 2
EOF
  : >"$TEST_TMP/swapfile"
  _probe_stdin 'y
1
' "$swap_probe" "SWAPFILE='$TEST_TMP/swapfile'
create_swap_file"
  assert_rc 0 "accepting the resize must complete"
  assert_called "swapoff $TEST_TMP/swapfile" "the old swap must be turned off"
  assert_called "rm -f $TEST_TMP/swapfile" "the old swap file must be removed"
}

test_swap_fstab_entry_is_appended_exactly_once() {
  local swap_probe
  swap_probe="$(_sourceable_copy unix/swap.sh)"
  make_sudo_passthrough
  _tee_append_stub
  : >"$TEST_TMP/fstab"
  _probe "$swap_probe" "SWAPFILE='$TEST_TMP/swapfile'
FSTAB='$TEST_TMP/fstab'
FSTAB_LINE='$TEST_TMP/swapfile none swap sw 0 0'
make_swap_permanent
make_swap_permanent"
  assert_rc 0
  assert_eq 1 "$(grep -cF "$TEST_TMP/swapfile none swap sw 0 0" "$TEST_TMP/fstab" || true)" \
    "two runs must leave exactly one fstab entry"
  assert_eq 1 "$(wc -l <"$TEST_TMP/fstab" | tr -d ' ')" "no extra fstab lines"
}
