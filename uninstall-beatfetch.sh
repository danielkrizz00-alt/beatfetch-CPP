#!/usr/bin/env bash
set -euo pipefail

BOLD='\033[1m'
CYAN='\033[36m'
GREEN='\033[32m'
RED='\033[31m'
YELLOW='\033[33m'
RESET='\033[0m'

ui_banner() {
  clear
  echo -e "${BOLD}${CYAN}========================================${RESET}"
  echo -e "${BOLD}       BeatFetch Uninstaller         ${RESET}"
  echo -e "${BOLD}${CYAN}========================================${RESET}"
  echo
}

remove_binary() {
  if [ -f "$HOME/.local/bin/beatfetch" ]; then
    rm -f "$HOME/.local/bin/beatfetch"
    echo -e "${GREEN}Removed user binary: $HOME/.local/bin/beatfetch${RESET}"
  else
    echo -e "${YELLOW}No user-level beatfetch binary found.${RESET}"
  fi
}

remove_python_wrapper() {
  if [ -f "$HOME/.local/bin/beatfetch.py" ]; then
    rm -f "$HOME/.local/bin/beatfetch.py"
  fi
}

remove_repo_stubs() {
  for target in "$HOME/.local/share/beatfetch" "$HOME/.local/share/BeatFetch" "$HOME/.cache/beatfetch"; do
    if [ -d "$target" ]; then
      rm -rf "$target"
      echo -e "${GREEN}Removed leftover files in $target${RESET}"
    fi
  done
}

clean_shell_path() {
  local marker="# Added by BeatFetch installer"
  if [ -f "$HOME/.bashrc" ]; then
    if grep -Fq "$marker" "$HOME/.bashrc"; then
      cp "$HOME/.bashrc" "$HOME/.bashrc.bak.beatfetch"
      grep -Fvx "$marker" "$HOME/.bashrc" > "$HOME/.bashrc.tmp" || true
      grep -Fv 'export PATH="$HOME/.local/bin:$PATH"' "$HOME/.bashrc.tmp" > "$HOME/.bashrc.clean" || true
      mv "$HOME/.bashrc.clean" "$HOME/.bashrc"
      rm -f "$HOME/.bashrc.tmp"
      echo -e "${GREEN}Removed PATH entries from ~/.bashrc${RESET}"
    fi
  fi
}

prompt_confirm() {
  echo -e "${YELLOW}This will remove the installed BeatFetch command and shell PATH entries.${RESET}"
  read -rp "Continue? [y/N]: " confirm
  case "$confirm" in
    y|Y|yes|YES) return 0 ;;
    *) echo -e "${RED}Uninstall cancelled.${RESET}"; exit 0 ;;
  esac
}

ui_banner
prompt_confirm
remove_binary
remove_python_wrapper
remove_repo_stubs
clean_shell_path

echo
echo -e "${GREEN}BeatFetch has been uninstalled.${RESET}"
echo -e "${DIM}You may need to reopen the terminal or run: source ~/.bashrc${RESET}"
