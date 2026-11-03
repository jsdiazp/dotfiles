#!/usr/bin/env bash
# docker.sh — install Docker on Debian / Ubuntu / Fedora.
#
# Patterns:
#   - Strategy: install_docker_debian_ubuntu vs install_docker_fedora are
#     interchangeable adapters behind a declarative target table.
#   - Template-Method: each step runs via run_step so failures carry context.
#   - Fail-fast: set -euo pipefail; curl failures are no longer masked.
#   - Privilege: as_root (sudo when needed, direct when already root) instead
#     of an unquoted `$_sudo` prefix at every call site.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../shared/common.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../shared/menu.sh"

DOCKER_PKGS_DEBIAN="docker.io docker-doc docker-compose podman-docker containerd runc"
DOCKER_PKGS_FEDORA="docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-selinux docker-engine-selinux docker-engine"
DOCKER_PKGS_INSTALL="docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"

_require_sudo_apt() {
  require_cmd apt-get
  require_cmd curl
  require_cmd tee
}

_add_docker_apt_repo() {
  local distro arch codename
  distro="$1"
  require_cmd dpkg
  as_root install -m 0755 -d /etc/apt/keyrings
  # set -o pipefail is active, so a curl failure aborts instead of being
  # masked by `tee` (the old script's bug).
  curl -fsSL "https://download.docker.com/linux/${distro}/gpg" | as_root tee /etc/apt/keyrings/docker.asc >/dev/null
  as_root chmod a+r /etc/apt/keyrings/docker.asc
  arch="$(dpkg --print-architecture)"
  # VERSION_CODENAME can be absent (e.g. Debian sid); fall back gracefully.
  # The `|| true` keeps set -e alive for the fallback when os-release is
  # missing or unreadable (minimal containers).
  codename="$(. /etc/os-release 2>/dev/null && printf '%s' "${VERSION_CODENAME:-}" || true)"
  if [ -z "$codename" ]; then
    codename="$(lsb_release -cs 2>/dev/null || printf 'stable')"
  fi
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
    "$arch" "$distro" "$codename" | as_root tee /etc/apt/sources.list.d/docker.list >/dev/null
}

# Function to install Docker on Debian/Ubuntu
install_docker_debian_ubuntu() {
  local distro
  distro="$1"
  _require_sudo_apt

  # Remove any existing Docker packages (word-splitting on the constant is
  # intentional; the variable is fully controlled above).
  # shellcheck disable=SC2086
  as_root apt-get remove -y $DOCKER_PKGS_DEBIAN || true

  run_step "Updating package index" as_root apt-get update
  run_step "Installing dependencies" as_root apt-get install -y ca-certificates curl
  run_step "Adding Docker apt repository" _add_docker_apt_repo "$distro"
  run_step "Updating package index" as_root apt-get update
  # shellcheck disable=SC2086
  run_step "Installing Docker" as_root apt-get install -y $DOCKER_PKGS_INSTALL

  info "Docker installed successfully on ${distro}!"
}

# Function to install Docker on Fedora
install_docker_fedora() {
  require_cmd dnf

  # shellcheck disable=SC2086
  as_root dnf remove -y $DOCKER_PKGS_FEDORA || true
  run_step "Installing dnf plugins" as_root dnf -y install dnf-plugins-core
  # dnf5 renamed `config-manager --add-repo` to `addrepo`; try new, fall back.
  if ! as_root dnf addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo 2>/dev/null; then
    run_step "Adding Docker repository" as_root dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
  fi
  # shellcheck disable=SC2086
  run_step "Installing Docker" as_root dnf install -y $DOCKER_PKGS_INSTALL
  run_step "Starting Docker service" as_root systemctl enable --now docker

  info "Docker installed successfully on Fedora!"
}

# Main function — declarative target table + strategy dispatch.
main() {
  MENU_PATH="Setup > Docker"
  if ! display_menu "Select a platform" "Debian" "Fedora" "Ubuntu"; then
    # Back (1) or EOF (3): unwind without running anything.
    [ "$MENU_CHOICE" = "b" ] && info "Back to previous menu."
    return 0
  fi
  MENU_PATH=""

  # Warm sudo once so its prompt is not hidden behind a step spinner.
  sudo_warm || warn "sudo unavailable; privileged steps may fail."

  case "$MENU_CHOICE" in
    1) install_docker_debian_ubuntu "debian" ;;
    2) install_docker_fedora ;;
    3) install_docker_debian_ubuntu "ubuntu" ;;
    *) die "Unsupported platform: $MENU_CHOICE" ;;
  esac

  print_summary "Docker summary"
}

main "$@"
