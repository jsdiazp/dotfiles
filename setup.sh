#!/bin/bash

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
  "scripts/unix/shell.sh"
  "scripts/unix/swap.sh"
  "scripts/unix/update.sh"
)
server_scripts=(
  "scripts/servers/ubuntu.sh"
)

# Quit the script if the user chooses to exit
quit() {
  if [[ "$choice" == "q" ]]; then
    echo -e "${BLUE}Happy coding!${RESET}"
    exit 0
  fi
}

# Handle other non-menu actions like quitting
other_options_actions() {
  quit
  if [[ "$choice" == "b" ]]; then
    return 1
  fi
}

# Validate the user's menu selection
wrong_option_validation() {
  local alternatives=("$@")
  if ! [[ "$choice" =~ ^([0-9]|b)+$ ]] || [[ "$choice" -ge "${#alternatives[@]}" ]]; then
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
display_other_options() {
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

# Display the main menu for a given set of alternatives
display_menu() {
  echo -e "${BOLD}${GREEN}$1${RESET}\n"

  shift
  local alternatives=("$@")

  display_options "${alternatives[@]}"
  display_other_options

  IFS='/'

  read -rp "[${!alternatives[*]}/b/q]: " choice

  unset IFS

  echo -e ""

  other_options_actions || return 1
  wrong_option_validation "${alternatives[@]}" || return 1

  return 0
}

# Menu for UNIX-based OS setup options
unix_menu() {
  local alternatives=(
    "Setup shell"
    "Setup swap"
    "Update OS"
  )

  display_menu "What do you want to do in your UNIX-based OS?" "${alternatives[@]}" || return

  execute_script "${unix_scripts[$choice]}" zsh
}

# Menu for server OS setup options
server_menu() {
  local alternatives=(
    "Ubuntu"
  )

  display_menu "What server OS do you want to set up?" "${alternatives[@]}" || return

  execute_script "${server_scripts[$choice]}" zsh
}

# Main menu to select the general task
main_menu() {
  local alternatives=(
    "Setup UNIX-based OS"
    "Setup server"
  )

  display_menu "What do you want to do?" "${alternatives[@]}" || return

  case $choice in
  0) unix_menu ;;
  1) server_menu ;;
  esac

}

main() {
  while true; do
    main_menu
  done
}

main
