#!/usr/bin/env bash
# test_setup_cli.sh — setup.sh dispatch contract: task registry, CLI flags,
# interpreter, exit-code propagation and the interactive menu.
#
# Pins down real bugs / destructive-action guards:
#   - Tasks must run under bash. A zsh interpreter word-splits differently
#     (`T="a b c"; set -- $T` yields 3 words in bash, 1 in zsh), which silently
#     broke every task script. The stub proves it with ARGC.
#   - A failed task must never print the success banner, and setup.sh must
#     return the task's own exit status (CI and unattended runs branch on it).
#   - -y/--yes must reach the task as an exported DOTFILES_ASSUME_YES=1, from
#     either side of `--unix <task>`; without it the variable must stay unset.
#   - --help/--list must parse the whole command line before exiting 0, so
#     `--list --bogus` cannot hide a typo; --unix/--server are exclusive and
#     need a value; names are case-insensitive and numeric aliases work.
#   - The menu must survive a failing task (report it, stay in the menu) and
#     unwind cleanly on EOF instead of looping forever.
#   - Verbosity flags must be exported to the task as DOTFILES_LOG_LEVEL.

# setup_cli_repo — copy of setup.sh + scripts/ with every task replaced by a
# stub. Prints the copy's path.
setup_cli_repo() {
  local repo
  repo="$(make_repo_copy)"
  write_task_stub "$repo" scripts/unix/docker.sh docker
  write_task_stub "$repo" scripts/unix/shell.sh shell
  write_task_stub "$repo" scripts/unix/swap.sh swap
  write_task_stub "$repo" scripts/unix/update.sh update
  write_task_stub "$repo" scripts/servers/ubuntu.sh ubuntu
  # Safety net: setup.sh never needs root, so any sudo call is a bug.
  make_stub sudo 99
  printf '%s\n' "$repo"
}

# write_task_stub <repo> <relative-path> <name> — stand-in task script.
# It reports which interpreter ran it (BASH_VERSION), whether --yes and the
# log level crossed the process boundary, and the word-split count (ARGC).
write_task_stub() {
  local repo="$1" rel="$2" name="$3"
  mkdir -p "$(dirname "$repo/$rel")"
  cat >"$repo/$rel" <<EOF
#!/usr/bin/env bash
T="a b c"
set -- \$T
echo "RAN $name ASSUME_YES=\${DOTFILES_ASSUME_YES:-unset} BASH=\${BASH_VERSION:+bash} LEVEL=\${DOTFILES_LOG_LEVEL:-unset} ARGC=\$#"
exit "\${STUB_RC:-0}"
EOF
  chmod +x "$repo/$rel"
}

# count_exact_lines <text> <line> — how many lines of <text> equal <line>.
count_exact_lines() {
  printf '%s\n' "$1" | grep -cxF -- "$2" || true
}

test_tasks_run_under_bash() {
  local repo
  repo="$(setup_cli_repo)"
  run "$TEST_BASH" "$repo/setup.sh" --unix update
  assert_rc 0
  assert_contains "$OUT" "RAN update" "the update task must run"
  # Word splitting: bash splits "a b c" into 3 words, zsh into 1.
  assert_contains "$OUT" "ARGC=3" "task scripts must be interpreted by bash"
  assert_contains "$OUT" "BASH=bash" "BASH_VERSION must be set inside the task"
}

test_success_path_prints_banner() {
  local repo
  repo="$(setup_cli_repo)"
  run "$TEST_BASH" "$repo/setup.sh" --unix docker
  assert_rc 0
  assert_contains "$OUT" "RAN docker"
  assert_contains "$OUT" "Script executed successfully."
}

test_failure_path_returns_task_status() {
  local repo
  repo="$(setup_cli_repo)"
  run env STUB_RC=3 "$TEST_BASH" "$repo/setup.sh" --unix update
  assert_rc 3 "setup.sh must return the task's own exit status"
  assert_contains "$OUT" "ERROR: Script failed (exit 3)"
  assert_not_contains "$OUT" "Script executed successfully." \
    "a failed task must not print the success banner"
}

test_yes_flag_is_exported_to_the_task() {
  local repo
  repo="$(setup_cli_repo)"
  run "$TEST_BASH" "$repo/setup.sh" --unix update
  assert_rc 0
  assert_contains "$OUT" "ASSUME_YES=unset" "no --yes: DOTFILES_ASSUME_YES stays unset"

  run "$TEST_BASH" "$repo/setup.sh" -y --unix update
  assert_rc 0
  assert_contains "$OUT" "ASSUME_YES=1" "-y before --unix must be exported"

  run "$TEST_BASH" "$repo/setup.sh" --unix update --yes
  assert_rc 0
  assert_contains "$OUT" "ASSUME_YES=1" "--yes after --unix must be exported"

  run "$TEST_BASH" "$repo/setup.sh" --unix update -y
  assert_rc 0
  assert_contains "$OUT" "ASSUME_YES=1" "-y after --unix must be exported"
}

test_cli_parsing_help_list_and_aliases() {
  local repo
  repo="$(setup_cli_repo)"

  run "$TEST_BASH" "$repo/setup.sh" --list
  assert_rc 0
  assert_contains "$OUT" "docker"
  assert_contains "$OUT" "shell"
  assert_contains "$OUT" "swap"
  assert_contains "$OUT" "update"
  assert_contains "$OUT" "ubuntu"
  assert_no_calls "--list must not run a task"

  run "$TEST_BASH" "$repo/setup.sh" --help
  assert_rc 0
  assert_contains "$OUT" "docker"
  assert_contains "$OUT" "shell"
  assert_contains "$OUT" "swap"
  assert_contains "$OUT" "update"
  assert_contains "$OUT" "ubuntu"
  assert_contains "$OUT" "-y, --yes" "--help must document --yes"
  assert_no_calls "--help must not run a task"

  run "$TEST_BASH" "$repo/setup.sh" --bogus
  assert_rc 1
  assert_contains "$OUT" "Unknown option: --bogus"

  # Informational flags only win after the whole line parses.
  run "$TEST_BASH" "$repo/setup.sh" --list --bogus
  assert_rc 1 "a trailing unknown option must still fail"
  assert_contains "$OUT" "Unknown option: --bogus"

  run "$TEST_BASH" "$repo/setup.sh" --unix
  assert_rc 1 "--unix without a value must fail"
  assert_contains "$OUT" "Missing value for --unix"

  run "$TEST_BASH" "$repo/setup.sh" --unix nope
  assert_rc 1
  assert_contains "$OUT" "Unknown UNIX task: nope"

  run "$TEST_BASH" "$repo/setup.sh" --unix update --server ubuntu
  assert_rc 1 "--unix and --server are mutually exclusive"
  assert_contains "$OUT" "Only one of --unix / --server"

  reset_calls
  run "$TEST_BASH" "$repo/setup.sh" --unix 4
  assert_rc 0
  assert_contains "$OUT" "RAN update" "numeric alias --unix 4 must run update"

  run "$TEST_BASH" "$repo/setup.sh" --unix UPDATE
  assert_rc 0
  assert_contains "$OUT" "RAN update" "task names must be case-insensitive"

  run "$TEST_BASH" "$repo/setup.sh" --server ubuntu
  assert_rc 0
  assert_contains "$OUT" "RAN ubuntu"
}

test_menu_runs_task_and_survives_failure() {
  local repo
  repo="$(setup_cli_repo)"

  run_stdin $'1\n4\nq\n' "$TEST_BASH" "$repo/setup.sh"
  assert_rc 0
  assert_contains "$OUT" "RAN update" "menu choice 1 -> 4 must run update"
  assert_contains "$OUT" "Script executed successfully."
  assert_contains "$OUT" "Happy coding!"
  assert_not_contains "$OUT" "RAN docker"

  run_stdin $'1\n4\nq\n' env STUB_RC=3 "$TEST_BASH" "$repo/setup.sh"
  assert_rc 0 "a failing task must not kill the menu"
  assert_contains "$OUT" "ERROR: Script failed (exit 3)"
  assert_not_contains "$OUT" "Script executed successfully."
  # Back at the main menu exactly twice: initial render + after the failure.
  assert_eq "2" "$(count_exact_lines "$OUT" "| What do you want to do? |")" \
    "the menu must re-render after a failed task"
  assert_contains "$OUT" "Happy coding!"

  # EOF (closed stdin) must unwind instead of looping forever.
  run "$TEST_BASH" "$repo/setup.sh"
  assert_rc 0
  assert_contains "$OUT" "Happy coding!"
  assert_not_contains "$OUT" "RAN "
}

test_verbosity_is_exported_to_the_task() {
  local repo
  repo="$(setup_cli_repo)"

  run "$TEST_BASH" "$repo/setup.sh" --unix update
  assert_rc 0
  assert_contains "$OUT" "LEVEL=warn" "default log level must be warn"

  run "$TEST_BASH" "$repo/setup.sh" -v --unix update
  assert_rc 0
  assert_contains "$OUT" "LEVEL=info" "-v must be exported as info"

  run "$TEST_BASH" "$repo/setup.sh" --unix update --debug
  assert_rc 0
  assert_contains "$OUT" "LEVEL=debug" "--debug must be exported as debug"

  run "$TEST_BASH" "$repo/setup.sh" -q --unix update
  assert_rc 0
  assert_contains "$OUT" "LEVEL=error" "-q must be exported as error"
}
