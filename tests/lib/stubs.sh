#!/usr/bin/env bash
# stubs.sh — stub binaries and call logging for tests (sourced by run.sh).
#
# Stubs live in $STUBS, which is first on PATH, and append "<name> <argv>" to
# $CALLS every time they run. Nothing here ever runs a real package manager.

# make_stub <name> [exit-code=0] — log the call, then exit with the code.
make_stub() {
  local name="$1" code="${2:-0}"
  mkdir -p "$STUBS"
  {
    printf '#!/bin/sh\n'
    printf 'echo "%s $*" >> "$CALLS"\n' "$name"
    printf 'exit %s\n' "$code"
  } >"$STUBS/$name"
  chmod +x "$STUBS/$name"
}

# make_stub_body <name> — log the call, then run /bin/sh code read from stdin.
# Example: make_stub_body brew <<'EOF'
#          [ "$1" = update ] && exit 1
#          EOF
make_stub_body() {
  local name="$1"
  mkdir -p "$STUBS"
  {
    printf '#!/bin/sh\n'
    printf 'echo "%s $*" >> "$CALLS"\n' "$name"
    cat
  } >"$STUBS/$name"
  chmod +x "$STUBS/$name"
}

# make_sudo_passthrough — `sudo <cmd...>` logs "sudo <cmd...>", then runs it.
make_sudo_passthrough() {
  make_stub_body sudo <<'EOF'
exec "$@"
EOF
}

# make_uname <kernel> [release] — fake uname: -s kernel, -r release, -m x86_64.
make_uname() {
  local kernel="$1" release="${2:-5.15.0-generic}"
  mkdir -p "$STUBS"
  cat >"$STUBS/uname" <<EOF
#!/bin/sh
case "\$1" in
  -s) echo "$kernel" ;;
  -r) echo "$release" ;;
  -m) echo x86_64 ;;
  *) echo "$kernel" ;;
esac
EOF
  chmod +x "$STUBS/uname"
}

# make_id <uid> — fake `id`: `id -u` prints <uid>; other forms defer to real id.
make_id() {
  local uid="$1" real
  real="$(PATH=/usr/bin:/bin command -v id)"
  mkdir -p "$STUBS"
  cat >"$STUBS/id" <<EOF
#!/bin/sh
if [ "\$1" = "-u" ]; then echo $uid; else exec "$real" "\$@"; fi
EOF
  chmod +x "$STUBS/id"
}

# calls — print the call log (empty if nothing ran).
calls() {
  if [ -f "$CALLS" ]; then cat "$CALLS"; fi
}

# reset_calls — start a fresh call log.
reset_calls() {
  : >"$CALLS"
}

# assert_called <fixed-string> [label] — some logged call contains the text.
assert_called() {
  calls | grep -qF -- "$1" || fail "${2:-assert_called}: no call matching [$1]; calls were:
$(calls)"
}

# assert_not_called <fixed-string> [label]
assert_not_called() {
  if calls | grep -qF -- "$1"; then
    fail "${2:-assert_not_called}: unexpected call matching [$1]; calls were:
$(calls)"
  fi
}

# assert_no_calls [label] — no stub ran at all.
assert_no_calls() {
  [ -z "$(calls)" ] || fail "${1:-assert_no_calls}: expected no calls but got:
$(calls)"
}

# make_repo_copy — copy setup.sh and scripts/ into $TEST_TMP/repo (so a test
# can swap in stub task scripts); prints the copy's path.
make_repo_copy() {
  local dest="$TEST_TMP/repo"
  mkdir -p "$dest"
  cp "$REPO_ROOT/setup.sh" "$dest/"
  cp -R "$REPO_ROOT/scripts" "$dest/"
  printf '%s\n' "$dest"
}
