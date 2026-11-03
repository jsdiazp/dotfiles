#!/usr/bin/env bash
# run.sh — dependency-free test runner (bash >= 3.2, no bats).
#
# Usage: bash tests/run.sh [filter]
#   filter  only run tests whose "file::function" id contains this text.
#
# A test file is tests/test_*.sh and defines functions named test_*. Every
# test runs in its OWN process with a scrubbed environment (env -i):
#   HOME, TMPDIR   scratch dirs under a per-test temp root (never your real ones)
#   PATH           "$STUBS:/usr/bin:/bin" — stub binaries first, no brew/npm/...
#   CALLS          file where stubs log their argv (see tests/lib/stubs.sh)
#   NO_COLOR=1 DOTFILES_ASCII=1 DOTFILES_NO_SPINNER=1 LC_ALL=C
#   REPO_ROOT, TEST_BASH (the bash running this runner), TEST_TMP, STUBS
#   TEST_PYTHON3 / TEST_TMUX / TEST_ZSH  absolute paths if found, else empty
# so a variable exported in the developer's shell (ZSH, DOTFILES_*, NVM_DIR...)
# can never change a result. Run it with the bash you want to test, e.g.
# `/bin/bash tests/run.sh` for macOS bash 3.2.
#
# Exit codes inside a test: 0 pass, 77 skip (see `skip`), anything else fail.
# Env: TESTS_DIR (default: this dir) selects the test files; TEST_KEEP=1 keeps
# the temp dir of failing tests for inspection.

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="${TESTS_DIR:-$HERE}"
LIB_DIR="$HERE/lib"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
TEST_BASH="$BASH"
FILTER="${1:-}"

passed=0
failed=0
skipped=0
failed_ids=""

_tool() {
  command -v "$1" 2>/dev/null || true
}
TEST_PYTHON3="$(_tool python3)"
TEST_TMUX="$(_tool tmux)"
TEST_ZSH="$(_tool zsh)"

# _list_tests <file> — print the names of its test_* functions, one per line.
_list_tests() {
  "$TEST_BASH" -c '
    . "$1"; . "$2"; . "$3"
    declare -F | while read -r _ _ name; do
      case "$name" in test_*) printf "%s\n" "$name" ;; esac
    done
  ' _ "$LIB_DIR/assert.sh" "$LIB_DIR/stubs.sh" "$1" 2>/dev/null
}

# _run_one <file> <function> — run one test in a scrubbed environment.
_run_one() {
  local file="$1" fn="$2" tmp rc
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-test.XXXXXX")"
  mkdir -p "$tmp/home" "$tmp/tmp" "$tmp/bin"
  env -i \
    HOME="$tmp/home" TMPDIR="$tmp/tmp" TERM=dumb LC_ALL=C \
    PATH="$tmp/bin:/usr/bin:/bin" STUBS="$tmp/bin" CALLS="$tmp/calls" \
    TEST_TMP="$tmp" REPO_ROOT="$REPO_ROOT" TEST_BASH="$TEST_BASH" \
    LIB_DIR="$LIB_DIR" \
    TEST_PYTHON3="$TEST_PYTHON3" TEST_TMUX="$TEST_TMUX" TEST_ZSH="$TEST_ZSH" \
    NO_COLOR=1 DOTFILES_ASCII=1 DOTFILES_NO_SPINNER=1 \
    "$TEST_BASH" -c '. "$LIB_DIR/assert.sh"; . "$LIB_DIR/stubs.sh"; . "$1"; "$2"' \
    _ "$file" "$fn" >"$tmp/out" 2>&1
  rc=$?
  case "$rc" in
    0)
      printf '  PASS  %s::%s\n' "$(basename "$file")" "$fn"
      passed=$((passed + 1))
      ;;
    77)
      printf '  SKIP  %s::%s  (%s)\n' "$(basename "$file")" "$fn" \
        "$(sed -n 's/^SKIP: //p' "$tmp/out" | head -1)"
      skipped=$((skipped + 1))
      ;;
    *)
      printf '  FAIL  %s::%s  (exit %s)\n' "$(basename "$file")" "$fn" "$rc"
      sed 's/^/        | /' "$tmp/out"
      failed=$((failed + 1))
      failed_ids="${failed_ids} $(basename "$file")::${fn}"
      ;;
  esac
  if [ "$rc" -eq 0 ] || [ "$rc" -eq 77 ] || [ -z "${TEST_KEEP:-}" ]; then
    rm -rf "$tmp"
  else
    printf '        (kept %s)\n' "$tmp"
  fi
}

main() {
  local file fn id
  for file in "$TESTS_DIR"/test_*.sh; do
    [ -e "$file" ] || continue
    for fn in $(_list_tests "$file"); do
      id="$(basename "$file")::$fn"
      case "$id" in
        *"$FILTER"*) _run_one "$file" "$fn" ;;
      esac
    done
  done
  printf '\n%d passed, %d failed, %d skipped\n' "$passed" "$failed" "$skipped"
  if [ "$failed" -gt 0 ]; then
    printf 'failed:%s\n' "$failed_ids"
    return 1
  fi
  if [ "$((passed + skipped))" -eq 0 ]; then
    printf 'no tests ran (filter: "%s")\n' "$FILTER"
    return 1
  fi
}

main
