#!/usr/bin/env zsh

# Define colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
RESET='\033[0m'

# Quit the script if the user chooses to exit
handle_exit() {
  if [[ "$choice" == "q" ]]; then
    echo -e "${BLUE}Happy coding!${RESET}"
    exit 0
  fi
}

# Display a list of options to the user
display_options() {
  local options=("$@")
  for i in {1..${#options[@]}}; do
    echo "${YELLOW}$i) ${options[$i]}${RESET}"
  done
}

# Display additional options like quitting
display_additional_options() {
  echo -e "\n${GREEN}Other options:\n${RESET}"
  echo -e "${YELLOW}b) Back to main menu${RESET}\n"
}

# Handle additional non-menu actions like quitting
additional_options_actions() {
  handle_exit
}

# Validate the user's menu selection
validate_choice() {
  local options=("$@")
  if ! [[ "$choice" =~ ^([1-9]|b)+$ ]] || [[ "$choice" -gt "${#options[@]}" ]]; then
    echo -e "${RED}Wrong option. Please try again.${RESET}\n"
    return 1
  fi
  return 0
}

# Display the menu and handle user selections
display_menu() {
  local title="$1"
  shift
  local options=("$@")
  local options_indexes=({1..${#options[@]}})

  echo -e "${BOLD}${GREEN}$title${RESET}\n"

  display_options "${options[@]}"
  display_additional_options

  IFS='/'

  echo -en "[${(j:/:)${options_indexes}}/b]: "
  read -r choice

  unset IFS

  echo -e ""

  additional_options_actions || return 1
  validate_choice "${options[@]}" || return 1

  return 0
}
