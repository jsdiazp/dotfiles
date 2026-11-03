#!/usr/bin/env bash
# test_spinner_pty.sh — pins the TTY spinner's whole lifecycle in common.sh.
#
# The spinner only starts when stdout is a real terminal, so every check here
# runs the probe under a pseudo-terminal driven by python3 (the stdlib `pty`
# module is portable; `script` is not). What each test pins down:
#   - run_step animates (repeating "\r<frame>" writes) and cleans its line up
#     before printing the final "[ok]" line.
#   - The spinner never outlives its shell: neither through a nested failure
#     routed through die() nor through a step that exits the shell directly.
#     A surviving frame printer, or a captured-output file left behind by
#     die()/a soft failure, fails the test.
#   - A soft step that fails under a TTY still dumps its captured output and
#     lets the script continue (exit 0).

# _write_pty_driver <path> — write the python pty driver.
# usage: python3 driver.py <bash> <probe> <outfile> <grace> [marker]
# Prints: exit=<n> survivors=<n> timeout=<0|1>; raw pty bytes go to <outfile>.
# <marker> is a unique string in the probe's path: any process whose command
# line still contains it after the probe exited is reported as a survivor.
_write_pty_driver() {
  cat >"$1" <<'PY'
import os
import pty
import select
import subprocess
import sys
import time

HARD_LIMIT = 20.0


def survivor_pids(marker):
    """PIDs whose command line still contains marker (our own pid excluded)."""
    proc = subprocess.Popen(
        ["/bin/ps", "-axo", "pid,command"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    out = proc.communicate()[0].decode("utf-8", "replace")
    me = os.getpid()
    pids = []
    for line in out.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) != 2:
            continue
        pid, cmd = parts
        if not pid.isdigit():
            continue  # header line ("PID COMMAND")
        if int(pid) == me:
            continue
        if marker in cmd and "ps -axo" not in cmd:
            pids.append(int(pid))
    return pids


def main():
    bash, probe, outfile = sys.argv[1], sys.argv[2], sys.argv[3]
    grace = float(sys.argv[4])
    marker = sys.argv[5] if len(sys.argv) > 5 else ""

    env = dict(os.environ)
    env.pop("DOTFILES_NO_SPINNER", None)
    env["NO_COLOR"] = "1"
    env["DOTFILES_ASCII"] = "1"
    env["DOTFILES_LOG_LEVEL"] = "warn"
    env["TERM"] = "xterm"

    # pty.openpty + Popen instead of pty.fork: with pty.fork the probe bash is
    # the pty's session leader, so the kernel HUPs its process group when it
    # exits and would mask a leaked spinner. Bash only needs fd 1 to be a tty
    # for _spin_enabled; the pty must not be its controlling terminal.
    fd, slave = pty.openpty()
    proc = subprocess.Popen(
        [bash, probe], stdin=slave, stdout=slave, stderr=slave, env=env
    )
    os.close(slave)

    chunks = []
    eof = False
    status = None
    exited_at = None
    found = 0
    timed_out = 0
    started = time.time()

    def pump():
        nonlocal eof
        ready, _, _ = select.select([fd], [], [], 0.05)
        if not ready:
            return
        try:
            data = os.read(fd, 4096)
        except OSError:
            data = b""
        if data:
            chunks.append(data)
        else:
            eof = True

    # Phase 1: until the probe shell exits.
    while status is None:
        if time.time() - started > HARD_LIMIT:
            timed_out = 1
            break
        pump()
        status = proc.poll()
        if status is not None:
            exited_at = time.time()

    # Phase 2: keep the pty open and look for survivors. A leaked spinner
    # writes to this pty, so it stays alive while the master is open.
    if status is not None:
        deadline = exited_at + grace
        # One ps sample shortly after the exit: a dropped guard makes the
        # spinner immortal (see the mutation check), while a clean one is gone
        # within a frame (0.15s); 0.8s leaves room for a loaded machine.
        samples = [0.8] if marker else []
        while True:
            now = time.time()
            pump()
            if marker:
                while samples and now >= exited_at + samples[0]:
                    samples.pop(0)
                    leaked = survivor_pids(marker)
                    found = max(found, len(leaked))
                    # Do not leave a runaway frame printer burning CPU on
                    # the machine even though the test has already failed.
                    for leaked_pid in leaked:
                        try:
                            os.kill(leaked_pid, 9)
                        except OSError:
                            pass
                    if found:
                        break
                if found:
                    break
                if not samples and (eof or now >= deadline + 0.5):
                    break
            elif eof or now >= deadline:
                break
            if now - started > HARD_LIMIT:
                timed_out = 1
                break

    if status is None:
        try:
            proc.kill()
        except OSError:
            pass
        exit_code = 255
    elif status < 0:
        exit_code = 128 - status
    else:
        exit_code = status

    with open(outfile, "wb") as fh:
        fh.write(b"".join(chunks))
    try:
        os.close(fd)
    except OSError:
        pass
    print("exit=%d" % exit_code)
    print("survivors=%d" % found)
    print("timeout=%d" % timed_out)
    print("bytes=%d" % sum(len(c) for c in chunks))


main()
PY
}

# _require_pty — skip reason when there is no python3 to drive the pty.
_require_pty() {
  [ -n "${TEST_PYTHON3:-}" ] || skip "python3 not found: cannot drive a pseudo-terminal"
}

# _count_spinner_frames <text> — number of "\r<frame>" sequences written by
# the spinner. Carriage returns from the tty's ONLCR ("\r\n") never match.
_count_spinner_frames() {
  local _cr _n
  _cr="$(printf '\r')"
  _n="$(printf '%s' "$1" | grep -o "${_cr}[|/-]" | wc -l | tr -d ' ')"
  printf '%s\n' "$_n"
}

# _assert_no_step_captures [label] — no dotfiles-step.* temp file survived.
_assert_no_step_captures() {
  local _left
  _left="$(ls "$TMPDIR"/dotfiles-step.* 2>/dev/null || true)"
  [ -z "$_left" ] || fail "${1:-step captures leaked}: $_left"
}

# _assert_driver_clean <driver-output> <label>
# The driver prints exit=/survivors=/timeout= for every run.
_assert_driver_clean() {
  assert_contains "$1" "timeout=0" "$2: pty driver hit its hard time limit"
  assert_contains "$1" "survivors=0" "$2: the spinner outlived its shell"
}

test_spinner_animates_and_cleans_up() {
  _require_pty
  local marker="zz-spinner-probe-$$-$RANDOM.sh"
  local probe="$TEST_TMP/$marker"
  local out="$TEST_TMP/pty-out.bin"
  _write_pty_driver "$TEST_TMP/pty_driver.py"

  # A quiet (warn-level) step captures output behind the spinner.
  cat >"$probe" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091 # path computed at runtime
. "$REPO_ROOT/scripts/shared/common.sh"
slow_ok() {
  sleep 0.5
  printf 'step-noise\n'
}
run_step 'spin-demo' slow_ok
printf 'PROBE-DONE\n'
EOF

  run "$TEST_PYTHON3" "$TEST_TMP/pty_driver.py" "$TEST_BASH" "$probe" "$out" 0.3
  assert_rc 0 "pty driver must complete"
  _assert_driver_clean "$OUT" "spinner run"
  local text frames
  text="$(cat "$out")"
  assert_eq "0" "$(printf '%s\n' "$OUT" | sed -n 's/^exit=//p')" "probe must exit 0"
  frames="$(_count_spinner_frames "$text")"
  [ "$frames" -ge 2 ] || fail "expected repeating \\r spinner frames, got $frames in:
$text"
  assert_contains "$text" "[ok] spin-demo" "final ok line"
  assert_contains "$text" "PROBE-DONE"
  _assert_no_step_captures "after a successful step"
}

test_spinner_dies_with_its_shell() {
  _require_pty
  local marker="zz-spinner-probe-$$-$RANDOM.sh"
  local probe="$TEST_TMP/$marker"
  local out="$TEST_TMP/pty-nested.bin"
  local out2="$TEST_TMP/pty-exit.bin"
  _write_pty_driver "$TEST_TMP/pty_driver.py"

  # 1. Nested failure: the inner run_step fails inside the outer capture.
  #    die() must reach the real terminal, take the spinner with it before the
  #    EXIT trap's cleanup runs, and leave no capture behind.
  cat >"$probe" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091 # path computed at runtime
. "$REPO_ROOT/scripts/shared/common.sh"
cleanup() {
  # Stands in for real trap cleanup (temp dirs, terminal restore): the
  # spinner must already be stopped when this runs.
  sleep 0.5
}
trap cleanup EXIT
inner() {
  sleep 0.6
  run_step 'inner-fails' false
}
run_step 'outer' inner
EOF
  run "$TEST_PYTHON3" "$TEST_TMP/pty_driver.py" "$TEST_BASH" "$probe" "$out" 0.4 "$marker"
  assert_rc 0 "pty driver must complete"
  _assert_driver_clean "$OUT" "nested failure"
  assert_eq "1" "$(printf '%s\n' "$OUT" | sed -n 's/^exit=//p')" "nested failure must exit 1"
  local text after late
  text="$(cat "$out")"
  assert_contains "$text" "Step failed [1]: inner-fails" "die() must not be swallowed by the outer capture"
  # Anything the spinner writes after the error line means it survived die().
  # One in-flight frame is tolerated (kill can race a write already started);
  # without _spinner_stop the 0.5s EXIT trap shows several frames.
  after="${text#*Step failed \[1\]: inner-fails}"
  late="$(_count_spinner_frames "$after")"
  [ "$late" -le 1 ] || fail "the spinner kept printing after die(); $late late frames:
$after"
  # die() dumps and removes every active capture before exiting.
  _assert_no_step_captures "after a fatal nested step"

  # 2. A step that exits its own shell: no _spinner_stop runs, so the frame
  #    printer must notice its parent is gone and quit by itself. (This path
  #    leaks its $TMPDIR/dotfiles-step.* capture; reported, not asserted, so
  #    the guard under test stays the only failure here.)
  cat >"$probe" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091 # path computed at runtime
. "$REPO_ROOT/scripts/shared/common.sh"
dying_step() {
  sleep 0.1
  exit 7
}
run_step 'dying-step' dying_step
EOF
  run "$TEST_PYTHON3" "$TEST_TMP/pty_driver.py" "$TEST_BASH" "$probe" "$out2" 0.4 "$marker"
  assert_rc 0 "pty driver must complete"
  _assert_driver_clean "$OUT" "step exiting its shell"
  assert_eq "7" "$(printf '%s\n' "$OUT" | sed -n 's/^exit=//p')" "the step's exit status must survive"
}

test_soft_step_dumps_capture_under_tty() {
  _require_pty
  local marker="zz-spinner-probe-$$-$RANDOM.sh"
  local probe="$TEST_TMP/$marker"
  local out="$TEST_TMP/pty-soft.bin"
  _write_pty_driver "$TEST_TMP/pty_driver.py"

  cat >"$probe" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091 # path computed at runtime
. "$REPO_ROOT/scripts/shared/common.sh"
soft_boom() {
  printf 'soft-stdout-detail\n'
  printf 'soft-stderr-detail\n' >&2
  return 3
}
run_step_soft 'soft-step' soft_boom
printf 'AFTER-SOFT\n'
EOF

  run "$TEST_PYTHON3" "$TEST_TMP/pty_driver.py" "$TEST_BASH" "$probe" "$out" 0.3
  assert_rc 0 "pty driver must complete"
  _assert_driver_clean "$OUT" "soft step"
  assert_eq "0" "$(printf '%s\n' "$OUT" | sed -n 's/^exit=//p')" "a soft failure must not abort the script"
  local text
  text="$(cat "$out")"
  assert_contains "$text" "soft-stdout-detail" "soft failure must dump captured stdout"
  assert_contains "$text" "soft-stderr-detail" "soft failure must dump captured stderr"
  assert_contains "$text" "[FAIL] soft-step" "soft failure must be reported"
  assert_contains "$text" "AFTER-SOFT" "the script must continue after a soft failure"
  _assert_no_step_captures "after a soft failure"
}
