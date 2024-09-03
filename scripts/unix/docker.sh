#!/usr/bin/env zsh

# Get the absolute path of the script
SCRIPT_PATH="$(readlink -f "$0")"
# Get the directory of the script
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

# Source the shared menu script
source "$SCRIPT_DIR/../shared/menu.sh"

# Function to install Docker on Debian/Ubuntu
install_docker_debian_ubuntu() {
  local distro=$1

  # Remove any existing Docker packages
  for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
    sudo apt-get remove -y $pkg
  done

  # Update package index and install dependencies
  sudo apt update
  sudo apt install -y ca-certificates curl

  # Add Docker’s official GPG key
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/$distro/gpg | sudo tee /etc/apt/keyrings/docker.asc >/dev/null
  sudo chmod a+r /etc/apt/keyrings/docker.asc

  # Set up the stable repository
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$distro \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

  # Update package index and install Docker
  sudo apt update
  sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  echo -e "\nDocker installed successfully on $distro!"
}

# Function to install Docker on Fedora
install_docker_fedora() {
  # Remove any existing Docker packages
  sudo dnf remove -y docker \
    docker-client \
    docker-client-latest \
    docker-common \
    docker-latest \
    docker-latest-logrotate \
    docker-logrotate \
    docker-selinux \
    docker-engine-selinux \
    docker-engine

  # Install required plugins
  sudo dnf -y install dnf-plugins-core

  # Add Docker’s official repository
  sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo

  # Install Docker
  sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  # Start Docker service
  sudo systemctl start docker

  echo -e "\nDocker installed successfully on Fedora!"
}

# Main function
main() {
  local options=(
    "Debian"
    "Fedora"
    "Ubuntu"
  )

  display_menu "Select a platform" "${options[@]}"

  case $choice in
  1) install_docker_debian_ubuntu "debian" ;;
  2) install_docker_fedora ;;
  3) install_docker_debian_ubuntu "ubuntu" ;;
  *) echo "Unsupported platform" ;;
  esac
}

main
