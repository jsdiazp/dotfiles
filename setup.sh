#!/bin/bash

# Get the absolute path of the script
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
# Get the directory of the script
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

# Define colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
# CYAN='\033[0;36m'
# WHITE='\033[0;37m'
BOLD='\033[1m'
RESET='\033[0m'

unix_scripts=(
  "$SCRIPT_DIR/scripts/unix/docker.sh"
  "$SCRIPT_DIR/scripts/unix/shell.sh"
  "$SCRIPT_DIR/scripts/unix/swap.sh"
  "$SCRIPT_DIR/scripts/unix/update.sh"
)
server_scripts=(
  "$SCRIPT_DIR/scripts/servers/ubuntu.sh"
)

# Quit the script if the user chooses to exit
handle_exit() {
  if [[ "$choice" == "q" ]]; then
    echo -e "${BLUE}Happy coding!${RESET}"
    exit 0
  fi
}

# Handle additional non-menu actions like quitting
additional_options_actions() {
  handle_exit
  if [[ "$choice" == "b" ]]; then
    return 1
  fi
}

# Validate the user's menu selection
validate_choice() {
  local options=("$@")
  if ! [[ "$choice" =~ ^([0-9]|b)+$ ]] || [[ "$choice" -ge "${#options[@]}" ]]; then
    echo -e "${RED}Wrong option. Please try again.${RESET}\n"
    return 1
  fi
  return 0
}

# Display a list of options to the user
display_options() {
  local opts=("$@")
  for i in "${!opts[@]}"; do
    echo -e "${YELLOW}$i) ${opts[$i]}${RESET}"
  done
}

# Display additional options like quitting
display_additional_options() {
  echo -e "\n${GREEN}Other options:\n${RESET}"
  echo -e "${YELLOW}b) Back to main menu${RESET}"
  echo -e "${YELLOW}q) Quit${RESET}\n"
}

# Execute the chosen script if it exists
execute_script() {
  local script=$1
  local interpreter=$2
  if [[ -f "$script" ]]; then
    "$interpreter" "$script"
    echo -e "\n${BLUE}Script executed successfully.${RESET}\n"
  else
    echo "Script not found: $script"
  fi
}

# Display the menu and handle user selections
display_menu() {
  local title="$1"
  shift
  local options=("$@")

  echo -e "${BOLD}${GREEN}$title${RESET}\n"

  display_options "${options[@]}"
  display_additional_options

  IFS='/'

  read -rp "[${!options[*]}/b/q]: " choice

  unset IFS

  echo -e ""

  additional_options_actions || return 1
  validate_choice "${options[@]}" || return 1

  return 0
}

# Menu for UNIX-based OS setup options
unix_menu() {
  local options=(
    "Setup Docker"
    "Setup shell"
    "Setup swap"
    "Update OS"
  )

  if display_menu "What do you want to do in your UNIX-based OS?" "${options[@]}"; then
    execute_script "${unix_scripts[$choice]}" zsh
  fi
}

# Menu for server OS setup options
server_menu() {
  local options=(
    "Ubuntu"
  )

  if display_menu "What server OS do you want to set up?" "${options[@]}"; then
    execute_script "${server_scripts[$choice]}" zsh
  fi
}

# Main menu to select the general task
main_menu() {
  local options=(
    "Setup UNIX-based OS"
    "Setup server"
  )

  if display_menu "What do you want to do?" "${options[@]}"; then
    case $choice in
    0) unix_menu ;;
    1) server_menu ;;
    esac
  fi
}

main() {
  while true; do
    main_menu
  done
}

main
