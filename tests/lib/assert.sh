#!/usr/bin/env bash
# assert.sh — assertions and command capture for tests (sourced by run.sh).
#
# Every failing assertion prints a diagnostic to stderr and `exit 1`s the test
# process, so a test reads as a straight line of checks. Tests do not use
# `set -e`; capture exit codes explicitly with `run` / `run_stdin`.

# fail <message...> — fail the current test.
fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

# skip <reason...> — mark the current test skipped (exit 77).
skip() {
  printf 'SKIP: %s\n' "$*" >&2
  exit 77
}

# run <cmd...> — run with stdin closed; sets OUT (stdout+stderr) and RC.
run() {
  OUT="$("$@" 2>&1 </dev/null)"
  RC=$?
}

# run_stdin <text> <cmd...> — like run, but feeds <text> (printf %s) on stdin.
run_stdin() {
  local input="$1"
  shift
  OUT="$(printf '%s' "$input" | "$@" 2>&1)"
  RC=$?
}

# assert_eq <expected> <actual> [label]
assert_eq() {
  [ "$1" = "$2" ] || fail "${3:-assert_eq}: expected [$1] but got [$2]"
}

# assert_rc <expected> [label] — compares against the RC set by run/run_stdin.
assert_rc() {
  [ "$RC" -eq "$1" ] || fail "${2:-assert_rc}: expected exit $1 but got $RC; output:
$OUT"
}

# assert_contains <haystack> <needle> [label]
assert_contains() {
  case "$1" in
    *"$2"*) : ;;
    *) fail "${3:-assert_contains}: [$2] not found in:
$1" ;;
  esac
}

# assert_not_contains <haystack> <needle> [label]
assert_not_contains() {
  case "$1" in
    *"$2"*) fail "${3:-assert_not_contains}: [$2] unexpectedly found in:
$1" ;;
  esac
}

# assert_file_exists <path> / assert_no_file <path>
assert_file_exists() {
  [ -e "$1" ] || [ -L "$1" ] || fail "expected file to exist: $1"
}
assert_no_file() {
  if [ -e "$1" ] || [ -L "$1" ]; then
    fail "expected no file at: $1"
  fi
}

# assert_same_file <file> <snapshot> [label] — byte-for-byte equality.
assert_same_file() {
  cmp -s "$1" "$2" || fail "${3:-assert_same_file}: $1 differs from $2"
}

# assert_line_count <expected> <text> [label] — number of non-empty lines.
assert_line_count() {
  local n
  n="$(printf '%s\n' "$2" | grep -c . || true)"
  [ "$n" -eq "$1" ] || fail "${3:-assert_line_count}: expected $1 lines but got $n in:
$2"
}
