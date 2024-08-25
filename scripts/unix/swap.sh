#!/bin/bash

# Function to log messages with timestamps
log() {
  local message=$1
  local add_newline_before=${2:-true}
  local add_newline_after=${3:-true}
  local formatted_message=""

  if [[ -n $message ]]; then
    formatted_message="\033[0;35m[$(date +"%Y-%m-%d %H:%M:%S")] ⚡️ $message\033[0m"
    [[ $add_newline_before == true ]] && formatted_message="\n$formatted_message"
    [[ $add_newline_after == true ]] && formatted_message="$formatted_message\n"
    echo -e "$formatted_message"
  fi
}

# Function to check the system for swap information
check_swap_info() {
  sudo swapon --show
  free -h
}

# Function to check available space on the hard drive partition
check_disk_space() {
  df -h
}

# Function to create a swap file
create_swap_file() {
  sudo fallocate -l 4G /swapfile
  ls -lh /swapfile
}

# Function to enable the swap file
enable_swap_file() {
  sudo chmod 600 /swapfile
  ls -lh /swapfile
  sudo mkswap /swapfile
  sudo swapon /swapfile
  sudo swapon --show
  free -h
}

# Function to make the swap file permanent
make_swap_permanent() {
  sudo cp /etc/fstab /etc/fstab.bak
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
}

# Main function to execute all steps
main() {
  log "Checking the System for Swap Information" false
  check_swap_info
  log "Checking Available Space on the Hard Drive Partition"
  check_disk_space
  log "Creating a Swap File"
  create_swap_file
  log "Enabling the Swap File"
  enable_swap_file
  log "Making the Swap File Permanent"
  make_swap_permanent
}

# Execute the main function
main
