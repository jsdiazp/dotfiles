# 🛠️ My Dotfiles

My personal dotfiles plus a small provisioning framework for macOS, Linux
(including WSL) and — partially — Windows. `setup.sh` dispatches every task, and
each task is also a standalone bash script. The shell side targets **bash 3.2**
(the `/bin/bash` that ships with macOS), so it needs no newer shell.

## 📂 What's inside

| Path | What it is |
| --- | --- |
| `alacritty/` | `alacritty.toml` plus the Catppuccin Mocha theme it imports |
| `btop/` | `btop.conf` |
| `tmux/` | `tmux.conf` (Catppuccin + TPM plugin list); `tmux/plugins/` is gitignored and filled by TPM |
| `vim/` | `.vimrc` plus per-plugin fragments in `plugins/` |
| `scripts/shared/` | `common.sh` (logging, steps, helpers) and `menu.sh` (interactive menu) |
| `scripts/unix/` | `docker.sh`, `shell.sh`, `swap.sh`, `update.sh` |
| `scripts/servers/` | `ubuntu.sh` (wipe-and-reprovision) |
| `scripts/windows/` | `shell.ps1`, `update.ps1`, `lib/Common.ps1` |
| `setup.sh` | Interactive menu and CLI dispatcher |
| `.github/workflows/lint.yml` | CI: `shellcheck` + `shfmt` |
| `.shellcheckrc`, `.editorconfig` | Lint config and whitespace/format config (shfmt reads it) |

## 🚀 Installation

There is nothing to install: the repo *is* the configuration, and `bash setup.sh` with no arguments opens the menu.

```bash
git clone https://github.com/jsdiazp/dotfiles.git
cd dotfiles
bash setup.sh          # interactive menu

# or call one task directly:
bash setup.sh --list                  # print the task list and exit
bash setup.sh --help                  # usage, flags, and examples
bash setup.sh --unix shell            # workstation setup (Zsh, brew, tools, links)
bash setup.sh --unix update -v        # update everything, verbose
bash setup.sh --unix 4 -q             # numeric alias for update, quiet
bash setup.sh --server ubuntu         # destructive server reprovision
```

`--unix` accepts `docker`, `shell`, `swap`, `update` or `1`–`4`; `--server`
accepts `ubuntu` (or `1`). Task names are case-insensitive, and verbosity or
`--yes` may come before or after the task option.

Task scripts always run with **bash**, even when your login shell is zsh.
`--yes` answers the scripts' own confirmations (exported as
`DOTFILES_ASSUME_YES=1`); it does **not** answer `sudo` or `chsh` passwords.

## 🧰 Tasks

| Task | What it does | Platform | Prompts / risk |
| --- | --- | --- | --- |
| `docker` | Installs Docker CE from Docker's repo on Debian/Ubuntu (apt) or Fedora (dnf), removing conflicting distro Docker packages first. | Debian, Ubuntu, Fedora | Asks which platform; needs sudo; replaces system packages. |
| `shell` | Installs/activates Zsh, Oh My Zsh and plugins, Node LTS via nvm (skipped with a warning if nvm is not loadable yet), Homebrew and CLI tools; links configs and sets Zsh as login shell. | macOS, Linux, WSL | Prompts (optional Homebrew reinstall, `chsh`). Backs up link destinations it replaces. |
| `swap` | Creates or resizes `/swapfile`, formats and enables it, and adds an `/etc/fstab` entry once. | Linux only | Asks for size and to confirm a resize; edits `/etc/fstab` (backed up). |
| `update` | Updates what is installed: OS packages, Mac App Store (`mas`), WinGet/Snap/Flatpak, nvm/Node LTS, RubyGems, CocoaPods cache, Homebrew, npm, Yarn cache, Composer, Oh My Zsh. Missing tools are skipped and one failure does not stop the rest. | macOS, Linux, WSL | Needs sudo; no yes/no questions. |
| `ubuntu` (server) | Wipes and reprovisions an Ubuntu server: removes the `APT_PURGE` packages, resets each user's shell state, removes `/nix` and `/home/linuxbrew`, then installs Nix, Zsh and the dotfiles. | Ubuntu (users `ubuntu` and `root`) | **Destructive.** Lists what it removes and asks for confirmation unless `-y` / `DOTFILES_ASSUME_YES=1`. |

About the `shell` task specifically: it never deletes `~/.zprofile`, never
deletes an existing `~/.zshrc` (it seeds one only if absent, otherwise adds
marked blocks), and symlinks `alacritty/`, `btop/` and `tmux/` into `~/.config`
plus `vim/.vimrc` and `vim/plugins` into `~/.vimrc` and
`~/.config/vim/plugins`. Anything already at a link destination is copied to
`<path>.bak.<timestamp>` before being replaced.

`ubuntu.sh` is deliberately destructive: it runs `apt-get remove` on
`bat btop duf fd-find fzf lsd neovim ripgrep vim zoxide`, deletes
`~/.oh-my-zsh`, `~/.zshrc`, `~/.zprofile`, `~/.nvm` and `~/.nix-*` for both
users, removes `/nix` (plus the `nixbld` users/groups), `/home/linuxbrew` and
the standalone `starship` binary, and uninstalls the `thefuck` pip package.

## 🌱 Environment variables

| Variable | Effect |
| --- | --- |
| `DOTFILES_LOG_LEVEL` | `debug`, `info`, `warn` (default) or `error`. `-v`/`--debug`/`-q` set it for the task scripts too. |
| `NO_COLOR` | Any non-empty value disables ANSI colors. |
| `DOTFILES_ASCII` | Any non-empty value uses ASCII status symbols and spinner frames. |
| `DOTFILES_NO_SPINNER` | Any non-empty value disables the animated spinner (step lines are printed instead). |
| `DOTFILES_ASSUME_YES` | `1` makes `confirm` answer yes; same as `--yes`. |
| `DOTFILES_NO_CLEAR` | Any non-empty value stops the menu from clearing the screen. |
| `DOTFILES_NO_FZF` | Any non-empty value disables the optional fzf menu picker. |
| `MENU_*` | `MENU_PATH`, `MENU_DEFAULT`, `MENU_SINGLE_KEY`, `MENU_USE_FZF`, `MENU_FZF_THRESHOLD` and `MENU_CLEAR` are per-call overrides for scripts that call `display_menu`; you rarely need them by hand. |

## 🪟 Windows

The PowerShell scripts are separate from `setup.sh` and target PowerShell 5.1.
`shell.ps1` installs Scoop, PowerShell modules and a winget tool list, edits
`$PROFILE` through marker-guarded blocks (backing it up first), applies the
Starship preset, and sets up vim-plug with the repo's `.vimrc` and plugin
fragments; it asks before each section. `update.ps1` updates npm, PowerShell
modules, Scoop and WinGet (all, or a subset via `-Only`) without prompting.

## 🧑‍💻 Development

Lint exactly what CI lints:

```bash
shellcheck -x setup.sh scripts/*/*.sh
shfmt -d setup.sh scripts/*/*.sh
```

Conventions used throughout the shell code:

- `setup.sh` is a composition root: it owns the menu and dispatch tables, while
  each task lives in `scripts/unix/` or `scripts/servers/`.
- Run work through `run_step` (fatal), `run_step_soft` (best effort: exit 0 is
  OK, 2 is skipped, anything else is a failure that does not abort), or
  `run_step_live` (always streams output).
- **Steps that prompt must use `run_step_live`** — captured output would hide
  the prompt while waiting on invisible input.
- Privileged commands go through `as_root`; never leave an unquoted `$_sudo`.
- Function state is `local`; no associative arrays, `read -p` or
  `readlink -f`, so everything runs on bash 3.2.
- Re-runs must be safe: use `safe_link`, `append_once` and `clone_or_update`
  instead of raw `ln`/`>>`/`rm -rf`, and back up before replacing.

## ⚠️ Known limitations

- The Windows scripts have not been exercised in this checkout (macOS); review
  them before running. They are not reachable from `setup.sh`.
- `--server ubuntu` is destructive by design. Read the confirmation list, take a
  backup, and do not run it on a machine you care about.
- `--yes` is blunt: it confirms the `ubuntu` wipe and a `swap` resize without
  asking. The one exception is the `shell` task's "reinstall Homebrew?" prompt,
  which is marked strict and is never auto-answered. Prefer `--yes` only for
  tasks whose prompts you know.
- On Linux arm64, `ubuntu.sh` leaves the Ruby/rbenv setup manual and only warns;
  it also removes Linuxbrew without reinstalling it, and `shell.sh` expects
  `/home/linuxbrew/.linuxbrew`.
- tmux plugins are not vendored. TPM is cloned by the `shell` task, and the
  rest install from inside tmux with `prefix + I`.

## 🧭 Roadmap

- Test the PowerShell scripts on a real Windows machine.
- Decide whether the manual arm64 Ruby step in `ubuntu.sh` should be automated.

Suggestions and pull requests are welcome — open an issue if something here
does not match your machine. Thanks to the open-source projects these configs
build on.
