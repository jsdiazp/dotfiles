#!/usr/bin/env bash
# test_configs.sh — pins the config files the installer rewrite and the shell
# setup depend on, without ever executing them.
#
#   - alacritty/alacritty.toml must stay valid TOML, must keep importing a
#     theme that exists in the repo (the installer downloads only when the
#     file is missing), and must keep the exact `decorations = "Transparent"`
#     line that scripts/unix/shell.sh seds to "None" (a silent no-op if it
#     drifts).
#   - tmux/tmux.conf must load in a real tmux server without config errors,
#     with the options this repo promises (C-s prefix, mouse, vi copy mode).
#     A parse error makes tmux discard the whole file, so the option checks
#     are the real guard.
#   - Every `source ~/.config/vim/plugins/*.vim` in vim/.vimrc must exist in
#     vim/plugins/. .vimrc itself is never executed: it auto-downloads
#     vim-plug on VimEnter.

# _tmux_config_errors <text> — print the lines that look like tmux config
# errors, minus the expected `run ~/.config/tmux/plugins/tpm/tpm` failure
# (tpm is not installed in the scratch HOME).
_tmux_config_errors() {
  local _line
  while IFS= read -r _line; do
    [ -n "$_line" ] || continue
    case "$_line" in
      # tpm is deliberately absent from the scratch HOME; its `run` line is
      # allowed to fail.
      *tpm* | *"command returned"*) continue ;;
      *.conf:[0-9]*:*)
        printf '%s\n' "$_line"
        ;;
      *"unknown command"* | *"unknown option"* | *"invalid"* | *"usage:"* | *"syntax error"*)
        printf '%s\n' "$_line"
        ;;
    esac
  done <<EOF
$1
EOF
}

test_alacritty_toml_parses_and_imports_theme() {
  local conf="$REPO_ROOT/alacritty/alacritty.toml" imports path base
  assert_file_exists "$conf"
  [ -n "${TEST_PYTHON3:-}" ] || skip "python3 not found: cannot parse TOML"
  run "$TEST_PYTHON3" -c 'import tomllib'
  if [ "$RC" -ne 0 ]; then
    skip "python3 lacks tomllib (needs >= 3.11): $("$TEST_PYTHON3" -V 2>&1)"
  fi

  # shellcheck disable=SC2153 # TEST_TMP is the runner's scratch dir; TEST_TMUX is unrelated.
  cat >"$TEST_TMP/read_alacritty.py" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as handle:
    cfg = tomllib.load(handle)
print("decorations=%s" % cfg.get("window", {}).get("decorations"))
for entry in cfg.get("import", []):
    print("import=%s" % entry)
PY
  run "$TEST_PYTHON3" "$TEST_TMP/read_alacritty.py" "$conf"
  assert_rc 0 "alacritty.toml must be valid TOML"
  assert_contains "$OUT" "decorations=Transparent" "window.decorations must stay Transparent"

  imports="$(printf '%s\n' "$OUT" | sed -n 's/^import=//p')"
  [ -n "$imports" ] || fail "alacritty.toml imports no theme file"
  for path in $imports; do
    base="${path##*/}"
    [ -n "$base" ] || fail "alacritty.toml has an empty import path: [$path]"
    assert_file_exists "$REPO_ROOT/alacritty/$base"
  done
}

test_alacritty_transparent_marker_is_literal() {
  local conf="$REPO_ROOT/alacritty/alacritty.toml" n
  assert_file_exists "$conf"
  # scripts/unix/shell.sh rewrites this exact literal; the toml must keep
  # spelling it the same way or the transparency toggle silently dies.
  n="$(grep -c '^decorations = "Transparent"$' "$conf" || true)"
  assert_eq "1" "$n" "alacritty.toml must have exactly one literal decorations = \"Transparent\" line"
  grep -qF 'decorations = "Transparent"' "$REPO_ROOT/scripts/unix/shell.sh" ||
    fail "scripts/unix/shell.sh no longer matches decorations = \"Transparent\""
}

test_tmux_conf_loads_and_keeps_key_options() {
  local conf="$REPO_ROOT/tmux/tmux.conf" sock out errors
  assert_file_exists "$conf"
  [ -n "${TEST_TMUX:-}" ] || skip "tmux not found: cannot validate tmux.conf"

  sock="t-$$-$RANDOM"
  # One client invocation so the options are read from the server that just
  # parsed the config file. -L keeps this off the user's default socket.
  # start-server's own status is not asserted: the missing-tpm `run` line at
  # the bottom of tmux.conf is allowed to fail.
  run "$TEST_TMUX" -L "$sock" -f "$conf" start-server \; \
    show-options -g prefix \; \
    show-options -g mouse \; \
    show-options -gw mode-keys \; \
    show-messages
  out="$OUT"
  "$TEST_TMUX" -L "$sock" kill-server >/dev/null 2>&1 || true
  run "$TEST_TMUX" -L "$sock" ls
  local ls_rc="$RC" ls_out="$OUT"
  # tmux may leave its socket file behind after the server exits on its own;
  # it lives outside $TEST_TMP (TMUX_TMPDIR defaults to /tmp/tmux-<uid>), so
  # remove it rather than littering the machine.
  rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$sock" 2>/dev/null || true

  assert_eq "1" "$ls_rc" "a tmux server was left running on socket $sock (ls: $ls_out)"
  assert_contains "$out" "prefix C-s" "tmux prefix must be C-s"
  assert_contains "$out" "mouse on" "tmux mouse must be on"
  assert_contains "$out" "mode-keys vi" "tmux copy mode must use vi keys"
  errors="$(_tmux_config_errors "$out")"
  [ -z "$errors" ] || fail "tmux.conf reported errors:
$errors"
}

test_tmux_error_scan_keeps_real_errors() {
  # The load test is only as good as this filter: it must drop the expected
  # missing-tpm `run` failure but never a real config error.
  local filtered
  filtered="$(_tmux_config_errors "/home/u/.config/tmux/tmux.conf:88: unknown command: sett
/home/u/.config/tmux/tmux.conf:88: command returned 1
/home/u/.config/tmux/tmux.conf:99: invalid option
/home/u/.config/tmux/tmux.conf:88: run-shell failed for plugins/tpm/tpm")"
  assert_contains "$filtered" "unknown command: sett"
  assert_contains "$filtered" "invalid option"
  assert_not_contains "$filtered" "command returned 1"
  assert_not_contains "$filtered" "plugins/tpm/tpm"
}

test_vimrc_plugin_sources_exist() {
  local vimrc="$REPO_ROOT/vim/.vimrc" refs base
  assert_file_exists "$vimrc"
  refs="$(sed -n 's|^[[:space:]]*source ~/\.config/vim/plugins/\([^[:space:]]*\.vim\).*|\1|p' "$vimrc")"
  [ -n "$refs" ] || fail "vim/.vimrc sources no ~/.config/vim/plugins/*.vim fragment"
  for base in $refs; do
    assert_file_exists "$REPO_ROOT/vim/plugins/$base"
  done
}
