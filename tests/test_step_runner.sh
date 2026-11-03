#!/usr/bin/env bash
# test_step_runner.sh — pins down the step runner in scripts/shared/common.sh.
#
# Every test here guards a behavior that used to be broken or that would be
# destructive if it regressed:
#   * run_step success prints ONE finished line and records ONE OK row; the
#     step's output stays hidden at warn (captured) and streams at info.
#   * run_step failure exits with the command's own code, shows the captured
#     output plus "Step failed [N]: <label>", and leaves no dotfiles-step.*
#     capture file in $TMPDIR (die() must remove every active capture).
#   * run_step_soft never kills the caller: 0 -> OK, 2 -> SKIP, other -> FAIL
#     with the output dumped, and print_summary counts match exactly.
#   * run_step inside run_step works (an earlier version crashed with
#     "_step_t0: unbound variable"), records two rows, leaks no capture, and
#     a 3-level failure surfaces the innermost output on the real terminal and
#     exits with the innermost code.
#   * run_step_live always streams (prompting steps must be visible) and still
#     fails the caller with the right code.
#   * log levels: debug/info stream step output, warn/error capture it.
#
# Each case runs in a child bash that sources common.sh with set -euo pipefail,
# exactly like a real provisioning script.

# assert_no_step_tempfiles — no captured step output survived in $TMPDIR.
assert_no_step_tempfiles() {
  local f
  for f in "$TMPDIR"/dotfiles-step.*; do
    # An unmatched glob keeps its literal name; only real files count.
    [ -e "$f" ] || continue
    fail "leaked step capture file: $f"
  done
}

test_run_step_ok_one_row_quiet_at_warn() {
  run "$TEST_BASH" -c '
set -euo pipefail
DOTFILES_LOG_LEVEL=warn
. "$REPO_ROOT/scripts/shared/common.sh"
_step_ok() { echo "chatter-from-the-step"; }
run_step "Say hi" _step_ok
printf "SUMMARY-BEGIN\n%sSUMMARY-END\n" "$DOTFILES_SUMMARY"
printf "ROWCOUNT=%s\n" "$(printf "%s" "$DOTFILES_SUMMARY" | grep -c . || true)"
print_summary
'
  assert_rc 0
  assert_contains "$OUT" "[ok] Say hi" "success line"
  assert_eq 1 "$(printf '%s\n' "$OUT" | grep -cF '[ok] Say hi' || true)" "exactly one finished line"
  assert_contains "$OUT" "Say hi|OK|" "one OK row recorded"
  assert_contains "$OUT" "ROWCOUNT=1" "exactly one summary row"
  assert_contains "$OUT" "1 ok, 0 failed, 0 skipped" "counts line"
  assert_not_contains "$OUT" "chatter-from-the-step" "warn level must capture step output"
  assert_no_step_tempfiles
}

test_run_step_ok_streams_at_info() {
  run "$TEST_BASH" -c '
set -euo pipefail
DOTFILES_LOG_LEVEL=info
. "$REPO_ROOT/scripts/shared/common.sh"
_step_ok() { echo "chatter-from-the-step"; }
run_step "Say hi" _step_ok
'
  assert_rc 0
  assert_contains "$OUT" "[ok] Say hi" "success line"
  assert_contains "$OUT" "chatter-from-the-step" "info level must stream step output"
  assert_no_step_tempfiles
}

test_run_step_failure_exits_with_its_code_and_cleans_up() {
  run "$TEST_BASH" -c '
set -euo pipefail
DOTFILES_LOG_LEVEL=warn
. "$REPO_ROOT/scripts/shared/common.sh"
_step_bad() {
  echo "captured-stdout-line"
  echo "captured-stderr-line" >&2
  return 7
}
run_step "Broken step" _step_bad
echo "NOT-REACHED"
'
  assert_rc 7 "a fatal step must exit with the command's own code"
  assert_contains "$OUT" "captured-stdout-line" "failure must dump captured stdout"
  assert_contains "$OUT" "captured-stderr-line" "failure must dump captured stderr"
  assert_contains "$OUT" "Step failed [7]: Broken step" "failure message"
  assert_not_contains "$OUT" "NOT-REACHED" "die() must stop the script"
  assert_no_step_tempfiles
}

test_run_step_soft_never_dies_and_counts_each_outcome() {
  run "$TEST_BASH" -c '
set -euo pipefail
DOTFILES_LOG_LEVEL=warn
. "$REPO_ROOT/scripts/shared/common.sh"
_soft_ok() { echo "soft-ok-output"; }
_soft_skip() { echo "soft-skip-output"; return 2; }
_soft_fail() { echo "soft-fail-output"; return 7; }
run_step_soft "Soft ok" _soft_ok
run_step_soft "Soft skip" _soft_skip
run_step_soft "Soft fail" _soft_fail
printf "AFTER-ALL\n"
printf "ROWCOUNT=%s\n" "$(printf "%s" "$DOTFILES_SUMMARY" | grep -c . || true)"
printf "SUMMARY-BEGIN\n%sSUMMARY-END\n" "$DOTFILES_SUMMARY"
print_summary
printf "COUNTS ok=%s failed=%s skipped=%s\n" "$SUMMARY_OK" "$SUMMARY_FAILED" "$SUMMARY_SKIPPED"
'
  assert_rc 0 "run_step_soft must never fail the caller"
  assert_contains "$OUT" "AFTER-ALL" "the script continues past a soft failure"
  assert_contains "$OUT" "[ok] Soft ok" "exit 0 is OK"
  assert_contains "$OUT" "[skip] Soft skip" "exit 2 is SKIP"
  assert_contains "$OUT" "[FAIL] Soft fail" "any other code is FAIL"
  assert_contains "$OUT" "Soft ok|OK|" "OK row"
  assert_contains "$OUT" "Soft skip|SKIP" "SKIP row"
  assert_contains "$OUT" "Soft fail|FAIL|" "FAIL row"
  assert_contains "$OUT" "soft-fail-output" "a soft failure dumps its output"
  assert_not_contains "$OUT" "soft-ok-output" "a soft success keeps its output captured"
  assert_contains "$OUT" "ROWCOUNT=3" "one row per step"
  assert_contains "$OUT" "1 ok, 1 failed, 1 skipped" "counts line"
  assert_contains "$OUT" "COUNTS ok=1 failed=1 skipped=1" "SUMMARY_* globals"
  assert_no_step_tempfiles
}

test_nested_run_step_succeeds_with_two_rows_no_leak() {
  run "$TEST_BASH" -c '
set -euo pipefail
DOTFILES_LOG_LEVEL=warn
. "$REPO_ROOT/scripts/shared/common.sh"
_inner() { echo "inner-output"; }
_outer() { run_step "Inner step" _inner; }
run_step "Outer step" _outer
printf "ROWCOUNT=%s\n" "$(printf "%s" "$DOTFILES_SUMMARY" | grep -c . || true)"
printf "SUMMARY-BEGIN\n%sSUMMARY-END\n" "$DOTFILES_SUMMARY"
print_summary
'
  assert_rc 0 "a step calling run_step must not crash"
  assert_contains "$OUT" "[ok] Outer step" "outer success line"
  assert_contains "$OUT" "Outer step|OK|" "outer row"
  assert_contains "$OUT" "Inner step|OK|" "inner row"
  assert_contains "$OUT" "ROWCOUNT=2" "two rows, no crash and no double recording"
  assert_contains "$OUT" "2 ok, 0 failed, 0 skipped" "counts line"
  assert_no_step_tempfiles
}

test_nested_failure_surfaces_innermost_output_and_code() {
  run "$TEST_BASH" -c '
set -euo pipefail
DOTFILES_LOG_LEVEL=warn
. "$REPO_ROOT/scripts/shared/common.sh"
_level3() { echo "innermost-output-marker"; return 7; }
_level2() { run_step "Level 2" _level3; }
_level1() { run_step "Level 1" _level2; }
run_step "Level 0" _level1
echo "NOT-REACHED"
'
  assert_rc 7 "the innermost exit code must reach the caller"
  assert_contains "$OUT" "innermost-output-marker" "innermost output must reach the terminal"
  assert_contains "$OUT" "Step failed [7]: Level 2" "the failing level names itself"
  assert_not_contains "$OUT" "NOT-REACHED" "die() must stop the script"
  assert_no_step_tempfiles
}

test_run_step_live_streams_at_warn_and_fails_hard() {
  run "$TEST_BASH" -c '
set -euo pipefail
DOTFILES_LOG_LEVEL=warn
. "$REPO_ROOT/scripts/shared/common.sh"
_live_ok() { echo "live-streamed-line"; }
run_step_live "Live ok" _live_ok
'
  assert_rc 0
  assert_contains "$OUT" "[ok] Live ok" "success line"
  assert_contains "$OUT" "live-streamed-line" "run_step_live always streams"
  assert_no_step_tempfiles

  run "$TEST_BASH" -c '
set -euo pipefail
DOTFILES_LOG_LEVEL=warn
. "$REPO_ROOT/scripts/shared/common.sh"
_live_bad() { echo "live-failure-output"; return 5; }
run_step_live "Live fail" _live_bad
echo "NOT-REACHED"
'
  assert_rc 5 "a failing live step still fails the caller with its code"
  assert_contains "$OUT" "live-failure-output" "live failure output is visible"
  assert_contains "$OUT" "Step failed [5]: Live fail" "failure message"
  assert_not_contains "$OUT" "NOT-REACHED" "die() must stop the script"
  assert_no_step_tempfiles
}

test_log_levels_gate_streaming() {
  run "$TEST_BASH" -c '
set -euo pipefail
DOTFILES_LOG_LEVEL=debug
. "$REPO_ROOT/scripts/shared/common.sh"
_probe() { echo "probe-body-line"; }
run_step "Debug step" _probe
info "info-line-visible"
debug "debug-line-visible"
warn "warn-line-visible"
'
  assert_rc 0
  assert_contains "$OUT" "probe-body-line" "debug streams step output"
  assert_contains "$OUT" "info-line-visible" "info() prints at debug"
  assert_contains "$OUT" "debug-line-visible" "debug() prints at debug"
  assert_contains "$OUT" "warn-line-visible" "warn() always prints"

  run "$TEST_BASH" -c '
set -euo pipefail
DOTFILES_LOG_LEVEL=info
. "$REPO_ROOT/scripts/shared/common.sh"
_probe() { echo "probe-body-line"; }
run_step "Info step" _probe
info "info-line-visible"
debug "debug-line-visible"
warn "warn-line-visible"
'
  assert_rc 0
  assert_contains "$OUT" "probe-body-line" "info streams step output"
  assert_contains "$OUT" "info-line-visible" "info() prints at info"
  assert_not_contains "$OUT" "debug-line-visible" "debug() stays quiet below debug"
  assert_contains "$OUT" "warn-line-visible" "warn() always prints"

  run "$TEST_BASH" -c '
set -euo pipefail
DOTFILES_LOG_LEVEL=warn
. "$REPO_ROOT/scripts/shared/common.sh"
_probe() { echo "probe-body-line"; }
run_step "Warn step" _probe
info "info-line-visible"
debug "debug-line-visible"
warn "warn-line-visible"
'
  assert_rc 0
  assert_not_contains "$OUT" "probe-body-line" "warn captures step output"
  assert_not_contains "$OUT" "info-line-visible" "info() stays quiet at warn"
  assert_not_contains "$OUT" "debug-line-visible" "debug() stays quiet at warn"
  assert_contains "$OUT" "warn-line-visible" "warn() always prints"
  assert_no_step_tempfiles
}
