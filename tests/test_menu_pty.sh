#!/usr/bin/env bash
# test_menu_pty.sh — a task's summary must survive the menu coming back.
#
# display_menu clears the screen on first render, and `clear` on xterm-like
# terminals also erases the scrollback (ESC[3J). Returning to the menu right
# after a task therefore wiped the task's summary for good. The clear only
# happens on a real terminal, so this runs setup.sh under a pty (python3 `pty`,
# keystrokes sent expect-style): main menu -> UNIX menu -> Update OS (a stub
# that prints SUMMARY-MARKER) -> back at the main menu -> quit.

_write_menu_driver() {
  cat >"$1" <<'PY'
import os
import pty
import select
import subprocess
import sys
import time

bash, repo, outfile = sys.argv[1], sys.argv[2], sys.argv[3]
env = dict(os.environ)
env["TERM"] = "xterm-256color"
env["NO_COLOR"] = "1"

fd, slave = pty.openpty()
proc = subprocess.Popen(
    [bash, os.path.join(repo, "setup.sh")],
    stdin=slave, stdout=slave, stderr=slave, env=env, cwd=repo,
)
os.close(slave)

buf = b""
deadline = time.time() + 25


def expect(text, start=0):
    """Read until `text` shows up at/after `start`; return its index or -1."""
    global buf
    while time.time() < deadline:
        i = buf.find(text, start)
        if i >= 0:
            return i
        if select.select([fd], [], [], 0.1)[0]:
            try:
                chunk = os.read(fd, 4096)
            except OSError:
                return -1
            if not chunk:
                return -1
            buf += chunk
    return -1


status = "ok"
if expect(b"What do you want to do?") < 0:
    status = "no main menu"
else:
    os.write(fd, b"1")
    if expect(b"UNIX-based OS?") < 0:
        status = "no unix menu"
    else:
        os.write(fd, b"4")
        marker = expect(b"SUMMARY-MARKER")
        if marker < 0:
            status = "task did not run"
        elif expect(b"What do you want to do?", marker) < 0:
            status = "main menu did not come back"
        else:
            os.write(fd, b"q")
            expect(b"Happy coding!", marker)

try:
    proc.wait(timeout=5)
except subprocess.TimeoutExpired:
    proc.kill()
    status += " (killed)"
while select.select([fd], [], [], 0.2)[0]:
    try:
        chunk = os.read(fd, 4096)
    except OSError:
        break
    if not chunk:
        break
    buf += chunk
open(outfile, "wb").write(buf)

marker = buf.find(b"SUMMARY-MARKER")
clears = []
i = buf.find(b"\x1b[2J")
while i >= 0:
    clears.append(i)
    i = buf.find(b"\x1b[2J", i + 1)
back = buf.find(b"What do you want to do?", marker) if marker >= 0 else -1
print("status=%s marker=%d clears=%d last_clear=%d menu_after=%d"
      % (status, marker, len(clears), clears[-1] if clears else -1, back))
PY
}

test_summary_is_not_wiped_when_the_menu_returns() {
  [ -n "$TEST_PYTHON3" ] || skip "python3 not available"
  local repo
  repo="$(make_repo_copy)"
  printf '#!/usr/bin/env bash\necho SUMMARY-MARKER\n' >"$repo/scripts/unix/update.sh"
  _write_menu_driver "$TEST_TMP/driver.py"

  run "$TEST_PYTHON3" "$TEST_TMP/driver.py" "$TEST_BASH" "$repo" "$TEST_TMP/pty.out"
  assert_rc 0 "driver ran"
  assert_contains "$OUT" "status=ok" "the whole menu flow completed"
  # Proves the mechanism is live: the menus themselves cleared the screen.
  assert_not_contains "$OUT" "clears=0" "no clear was ever emitted, so this test proves nothing"

  local marker last_clear menu_after
  marker="$(printf '%s' "$OUT" | sed -n 's/.*marker=\([-0-9]*\).*/\1/p')"
  last_clear="$(printf '%s' "$OUT" | sed -n 's/.*last_clear=\([-0-9]*\).*/\1/p')"
  menu_after="$(printf '%s' "$OUT" | sed -n 's/.*menu_after=\([-0-9]*\).*/\1/p')"
  [ "$last_clear" -lt "$marker" ] ||
    fail "the screen was cleared after the summary (clear at byte $last_clear, summary at $marker): $OUT"
  [ "$menu_after" -gt "$marker" ] ||
    fail "the main menu was not redrawn below the summary: $OUT"
}
