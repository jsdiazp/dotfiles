#!/usr/bin/env bash
# test_harness.sh — the test framework tests itself (runner, assertions, stubs).

test_environment_is_scrubbed() {
  assert_eq "$TEST_TMP/home" "$HOME" "HOME is the scratch dir"
  assert_eq "$STUBS:/usr/bin:/bin" "$PATH" "PATH is stubs + system dirs only"
  assert_eq "1" "$DOTFILES_ASCII" "ASCII output is pinned"
  assert_eq "" "${ZSH:-}" "ZSH from the caller's shell must not leak in"
  assert_eq "" "${DOTFILES_ASSUME_YES:-}" "no ambient --yes"
  assert_file_exists "$REPO_ROOT/setup.sh"
}

test_stub_logs_its_argv() {
  make_stub brew
  brew install bat fd
  assert_called "brew install bat fd"
  assert_not_called "npm"
}

test_stub_exit_code_and_body() {
  make_stub npm 3
  run npm update -g
  assert_rc 3
  make_stub_body gem <<'EOF'
echo "gem says hi"
EOF
  run gem list
  assert_contains "$OUT" "gem says hi"
  assert_called "gem list"
}

test_no_calls_when_nothing_ran() {
  make_stub brew
  assert_no_calls
}

test_assert_failures_exit_nonzero() {
  # Each failing assertion must terminate its (sub)shell with status 1.
  ("$TEST_BASH" -c '. "$LIB_DIR/assert.sh"; assert_eq a b' _ >/dev/null 2>&1)
  assert_eq "1" "$?" "assert_eq on mismatch"
  ("$TEST_BASH" -c '. "$LIB_DIR/assert.sh"; assert_contains abc z' _ >/dev/null 2>&1)
  assert_eq "1" "$?" "assert_contains on miss"
  ("$TEST_BASH" -c '. "$LIB_DIR/assert.sh"; skip why' _ >/dev/null 2>&1)
  assert_eq "77" "$?" "skip exits 77"
}

test_run_captures_output_and_status() {
  run "$TEST_BASH" -c 'echo out; echo err >&2; exit 4'
  assert_rc 4
  assert_contains "$OUT" "out"
  assert_contains "$OUT" "err"
  run_stdin "hello" cat
  assert_eq "hello" "$OUT"
}

test_runner_fails_when_a_test_fails() {
  local d="$TEST_TMP/fake-tests"
  mkdir -p "$d"
  cat >"$d/test_fake.sh" <<'EOF'
test_good() { assert_eq 1 1; }
test_bad() { assert_eq 1 2 "deliberate"; }
test_skipped() { skip "not today"; }
EOF
  TESTS_DIR="$d" run "$TEST_BASH" "$REPO_ROOT/tests/run.sh"
  assert_rc 1 "runner must exit 1 when any test fails"
  assert_contains "$OUT" "PASS  test_fake.sh::test_good"
  assert_contains "$OUT" "FAIL  test_fake.sh::test_bad"
  assert_contains "$OUT" "SKIP  test_fake.sh::test_skipped"
  assert_contains "$OUT" "1 passed, 1 failed, 1 skipped"
}

test_runner_passes_and_filters() {
  local d="$TEST_TMP/fake-tests"
  mkdir -p "$d"
  printf 'test_a() { :; }\ntest_b() { :; }\n' >"$d/test_ok.sh"
  TESTS_DIR="$d" run "$TEST_BASH" "$REPO_ROOT/tests/run.sh" test_a
  assert_rc 0
  assert_contains "$OUT" "1 passed, 0 failed, 0 skipped"
  TESTS_DIR="$d" run "$TEST_BASH" "$REPO_ROOT/tests/run.sh" no_such_test
  assert_rc 1 "a filter that matches nothing is an error, not a green run"
}
