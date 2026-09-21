#!/usr/bin/env bash
# docker.sh — install Docker on Debian / Ubuntu / Fedora.
#
# Patterns:
#   - Strategy: install_docker_debian_ubuntu vs install_docker_fedora are
#     interchangeable adapters behind a declarative target table.
#   - Template-Method: each step runs via run_step so failures carry context.
#   - Fail-fast: set -euo pipefail; curl failures are no longer masked.

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
  _repo_distro="$1"
  require_cmd dpkg
  _repo_sudo="$(sudo_if_needed)"
  $_repo_sudo install -m 0755 -d /etc/apt/keyrings
  # set -o pipefail is active, so a curl failure aborts instead of being
  # masked by `tee` (the old script's bug).
  curl -fsSL "https://download.docker.com/linux/${_repo_distro}/gpg" | $_repo_sudo tee /etc/apt/keyrings/docker.asc >/dev/null
  $_repo_sudo chmod a+r /etc/apt/keyrings/docker.asc
  _repo_arch="$(dpkg --print-architecture)"
  # VERSION_CODENAME can be absent (e.g. Debian sid); fall back gracefully.
  # The `|| true` keeps set -e alive for the fallback when os-release is
  # missing or unreadable (minimal containers).
  _repo_codename="$(. /etc/os-release 2>/dev/null && printf '%s' "${VERSION_CODENAME:-}" || true)"
  if [ -z "$_repo_codename" ]; then
    _repo_codename="$(lsb_release -cs 2>/dev/null || printf 'stable')"
  fi
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
    "$_repo_arch" "$_repo_distro" "$_repo_codename" | $_repo_sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  unset _repo_distro _repo_arch _repo_codename _repo_sudo
}

# Function to install Docker on Debian/Ubuntu
install_docker_debian_ubuntu() {
  _distro="$1"
  _sudo="$(sudo_if_needed)"
  _require_sudo_apt

  # Remove any existing Docker packages (word-splitting on the constant is
  # intentional; the variable is fully controlled above).
  # shellcheck disable=SC2086
  $_sudo apt-get remove -y $DOCKER_PKGS_DEBIAN || true

  run_step "Updating package index" $_sudo apt-get update
  run_step "Installing dependencies" $_sudo apt-get install -y ca-certificates curl
  run_step "Adding Docker apt repository" _add_docker_apt_repo "$_distro"
  run_step "Updating package index" $_sudo apt-get update
  # shellcheck disable=SC2086
  run_step "Installing Docker" $_sudo apt-get install -y $DOCKER_PKGS_INSTALL

  info "Docker installed successfully on ${_distro}!"
  unset _distro _sudo
}

# Function to install Docker on Fedora
install_docker_fedora() {
  _sudo="$(sudo_if_needed)"
  require_cmd dnf

  # shellcheck disable=SC2086
  $_sudo dnf remove -y $DOCKER_PKGS_FEDORA || true
  run_step "Installing dnf plugins" $_sudo dnf -y install dnf-plugins-core
  # dnf5 renamed `config-manager --add-repo` to `addrepo`; try new, fall back.
  if ! $_sudo dnf addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo 2>/dev/null; then
    run_step "Adding Docker repository" $_sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
  fi
  # shellcheck disable=SC2086
  run_step "Installing Docker" $_sudo dnf install -y $DOCKER_PKGS_INSTALL
  run_step "Starting Docker service" $_sudo systemctl enable --now docker

  info "Docker installed successfully on Fedora!"
  unset _sudo
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

  case "$MENU_CHOICE" in
    1) install_docker_debian_ubuntu "debian" ;;
    2) install_docker_fedora ;;
    3) install_docker_debian_ubuntu "ubuntu" ;;
    *) die "Unsupported platform: $MENU_CHOICE" ;;
  esac

  print_summary "Docker summary"
}

main "$@"
