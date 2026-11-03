#!/usr/bin/env bash
# swap.sh — create, enable, and persist a swap file on Linux.
#
# Patterns:
#   - Template-Method pipeline: main() is an ordered run_step list.
#   - Idempotency: fstab entry is added once (grep guard); backup is kept.
#   - Fail-fast with clear context instead of 10x copy-pasted `|| { ... }`.
#   - No `bc` dependency (missing on minimal images) — awk only.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../shared/common.sh"

SWAPFILE="/swapfile"
FSTAB="/etc/fstab"
FSTAB_LINE="$SWAPFILE none swap sw 0 0"

# Function to validate operating system compatibility
validate_compatibility() {
  if [ ! -f /proc/meminfo ]; then
    die "Unsupported operating system: /proc/meminfo not found (Linux only)."
  fi
  require_cmd swapon
  require_cmd free
}

# Function to check the system for swap information (informational probes:
# `swapon --show` exits non-zero when no swap exists, so these must NOT run
# via run_step, which treats any failure as fatal).
check_swap_info() {
  log "Retrieving swap information" false false
  as_root swapon --show || info "(no active swap)"
  log "Retrieving memory information" false false
  free -h
}

# Function to check available space on the hard drive partition
check_disk_space() {
  run_step "Checking disk space" df -h /
}

# suggested_swap_gb — 2x total RAM, rounded. awk only (no bc).
suggested_swap_gb() {
  awk '/MemTotal/ { printf "%.0f", ($2/1024/1024)*2 }' /proc/meminfo
}

# Function to create a swap file
create_swap_file() {
  local default_gb gigabytes
  if [ -f "$SWAPFILE" ]; then
    if ! confirm "Swapfile exists in root (/). Resize it?" n; then
      printf '%s\n' "Exiting without making changes."
      exit 0
    fi
    run_step "Turning off existing swap" as_root swapoff "$SWAPFILE"
    run_step "Removing existing swap file" as_root rm -f "$SWAPFILE"
  fi

  default_gb="$(suggested_swap_gb)"
  printf 'Swap size in GB (Suggested: %sG): ' "$default_gb"
  gigabytes=""
  IFS= read -r gigabytes || true
  if [ -z "$gigabytes" ]; then
    gigabytes="$default_gb"
  fi
  case "$gigabytes" in
    *[!0-9]* | "" | "0")
      die "Invalid input. Please enter a positive numeric value for gigabytes."
      ;;
  esac

  # fallocate fails on tmpfs/ZFS/btrfs — fall back to dd.
  if ! as_root fallocate -l "${gigabytes}G" "$SWAPFILE"; then
    warn "fallocate failed, falling back to dd (slower but portable)."
    run_step "Creating swap file with dd" as_root dd if=/dev/zero of="$SWAPFILE" bs=1G count="$gigabytes" status=progress
  fi
  ls -lh "$SWAPFILE"
}

# Function to enable the swap file
enable_swap_file() {
  run_step "Setting swap file permissions" as_root chmod 600 "$SWAPFILE"
  ls -lh "$SWAPFILE"
  run_step "Formatting swap space" as_root mkswap "$SWAPFILE"
  run_step "Enabling swap file" as_root swapon "$SWAPFILE"
  as_root swapon --show
  free -h
}

# Function to make the swap file permanent (idempotent: no duplicate lines).
make_swap_permanent() {
  if grep -qF "$FSTAB_LINE" "$FSTAB" 2>/dev/null; then
    info "fstab already contains swap entry; skipping."
    return 0
  fi
  run_step "Backing up fstab" as_root cp -a "$FSTAB" "${FSTAB}.bak.$(date +%Y%m%d%H%M%S)"
  printf '%s\n' "$FSTAB_LINE" | as_root tee -a "$FSTAB" >/dev/null
}

# Main function to execute all steps
main() {
  run_step "Validating system compatibility" validate_compatibility
  # Warm sudo once so its prompt is not hidden behind a step spinner.
  sudo_warm || warn "sudo unavailable; privileged steps may fail."
  run_step "Checking the System for Swap Information" check_swap_info
  run_step "Checking Available Space on the Hard Drive Partition" check_disk_space
  # Live output: create_swap_file prompts (resize? size?).
  run_step_live "Creating a Swap File" create_swap_file
  run_step "Enabling the Swap File" enable_swap_file
  run_step "Making the Swap File Permanent" make_swap_permanent
  print_summary "Swap summary"
}

main "$@"
