#!/usr/bin/env zsh

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

# Function to validate operating system compatibility
validate_compatibility() {
  if ! command -v swapon >/dev/null; then
    echo "Unsupported operating system"
    exit 1
  fi
}

# Function to check the system for swap information
check_swap_info() {
  sudo swapon --show || {
    log "Failed to retrieve swap information" false
    exit 1
  }
  free -h || {
    log "Failed to retrieve memory information" false
    exit 1
  }
}

# Function to check available space on the hard drive partition
check_disk_space() {
  df -h || {
    log "Failed to check disk space" false
    exit 1
  }
}

# Function to create a swap file
create_swap_file() {
  local total_ram
  local default_gigabytes

  if [[ -f "/swapfile" ]]; then
    echo -n "Swapfile exists in root (/). Resize it? (y/n): "
    read should_resize

    if [[ $should_resize == "y" ]]; then
      sudo swapoff /swapfile || {
        log "Failed to turn off swap" false
        exit 1
      }
      sudo rm /swapfile || {
        log "Failed to remove existing swap file" false
        exit 1
      }
    else
      log "Exiting without making changes." false
      exit 0
    fi
  fi

  total_ram=$(awk '/MemTotal/ { printf "%.2f", $2/1024/1024 }' /proc/meminfo)
  default_gigabytes=$(printf "%.0f" "$(echo "$total_ram * 2" | bc -l)")

  echo -ne "Swap size in GB (Suggested: ${default_gigabytes}G): "
  read gigabytes

  if [[ -z $gigabytes ]]; then
    gigabytes=$default_gigabytes
  fi

  if [[ $gigabytes =~ ^[0-9]+$ ]]; then
    sudo fallocate -l "${gigabytes}G" /swapfile || {
      log "Failed to create swap file" false
      exit 1
    }
    ls -lh /swapfile
  else
    log "Invalid input. Please enter a numeric value for gigabytes." false
    exit 1
  fi
}

# Function to enable the swap file
enable_swap_file() {
  sudo chmod 600 /swapfile || {
    log "Failed to set permissions on swap file" false
    exit 1
  }
  ls -lh /swapfile
  sudo mkswap /swapfile || {
    log "Failed to set up swap space" false
    exit 1
  }
  sudo swapon /swapfile || {
    log "Failed to enable swap file" false
    exit 1
  }
  sudo swapon --show
  free -h
}

# Function to make the swap file permanent
make_swap_permanent() {
  sudo cp /etc/fstab /etc/fstab.bak || {
    log "Failed to back up fstab" false
    exit 1
  }
  echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab || {
    log "Failed to update fstab" false
    exit 1
  }
}

# Main function to execute all steps
main() {
  log "Validating system compatibility" false
  validate_compatibility
  log "Checking the System for Swap Information"
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
