#!/usr/bin/env bash
set -euo pipefail

BOLD='\033[1m'
DIM='\033[2m'
CYAN='\033[36m'
GREEN='\033[32m'
RED='\033[31m'
YELLOW='\033[33m'
RESET='\033[0m'

USE_ZENITY=0
FORCE_MODE=""
STATUS_LOG=()

usage() {
  cat <<EOF
Usage: $(basename "$0") [--gui|--no-gui] [-h|--help]

  --gui      Use zenity dialogs (requires zenity to already be installed).
  --no-gui   Use plain terminal prompts, even in a graphical session.
  -h, --help Show this help text.
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --gui) FORCE_MODE="gui" ;;
      --no-gui|--cli) FORCE_MODE="cli" ;;
      -h|--help) usage; exit 0 ;;
      *) echo -e "${RED}Unknown option: $1${RESET}"; usage; exit 1 ;;
    esac
    shift
  done
}

ui_banner() {
  clear
  echo -e "${BOLD}${CYAN}========================================${RESET}"
  echo -e "${BOLD}       BeatFetch Uninstaller         ${RESET}"
  echo -e "${BOLD}${CYAN}========================================${RESET}"
  echo
}

has_display() {
  [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]
}

# Unlike the installer, we deliberately do NOT offer to install zenity here:
# uninstalling shouldn't need sudo or a package install of its own. If it's
# not already present, we just use the terminal prompts.
setup_mode() {
  case "$FORCE_MODE" in
    gui)
      if command -v zenity >/dev/null 2>&1; then
        USE_ZENITY=1
      else
        echo -e "${YELLOW}zenity isn't installed; falling back to terminal prompts.${RESET}"
        USE_ZENITY=0
      fi
      ;;
    cli)
      USE_ZENITY=0
      ;;
    *)
      if has_display && command -v zenity >/dev/null 2>&1; then
        USE_ZENITY=1
        echo -e "${DIM}Graphical session detected — using zenity dialogs. Pass --no-gui to use the terminal instead.${RESET}"
      else
        USE_ZENITY=0
      fi
      ;;
  esac
}

log_status() {
  STATUS_LOG+=("$1")
}

remove_binary() {
  if [ -f "$HOME/.local/bin/beatfetch" ]; then
    rm -f "$HOME/.local/bin/beatfetch"
    echo -e "${GREEN}Removed user binary: $HOME/.local/bin/beatfetch${RESET}"
    log_status "Removed $HOME/.local/bin/beatfetch"
  else
    echo -e "${YELLOW}No user-level beatfetch binary found.${RESET}"
  fi
}

remove_python_wrapper() {
  if [ -f "$HOME/.local/bin/beatfetch.py" ]; then
    rm -f "$HOME/.local/bin/beatfetch.py"
    log_status "Removed $HOME/.local/bin/beatfetch.py"
  fi
}

remove_repo_stubs() {
  for target in "$HOME/.local/share/beatfetch" "$HOME/.local/share/BeatFetch" "$HOME/.cache/beatfetch"; do
    if [ -d "$target" ]; then
      rm -rf "$target"
      echo -e "${GREEN}Removed leftover files in $target${RESET}"
      log_status "Removed $target"
    fi
  done
}

clean_shell_path() {
  # Must match the marker install-cpp-beatfetch.sh actually writes.
  local marker="# Added by BeatFetch C++ installer"
  if [ -f "$HOME/.bashrc" ]; then
    if grep -Fq "$marker" "$HOME/.bashrc"; then
      cp "$HOME/.bashrc" "$HOME/.bashrc.bak.beatfetch"
      grep -Fvx "$marker" "$HOME/.bashrc" > "$HOME/.bashrc.tmp" || true
      grep -Fv 'export PATH="$HOME/.local/bin:$PATH"' "$HOME/.bashrc.tmp" > "$HOME/.bashrc.clean" || true
      mv "$HOME/.bashrc.clean" "$HOME/.bashrc"
      rm -f "$HOME/.bashrc.tmp"
      echo -e "${GREEN}Removed PATH entries from ~/.bashrc${RESET}"
      log_status "Cleaned PATH entry from ~/.bashrc (backup: ~/.bashrc.bak.beatfetch)"
    fi
  fi
}

prompt_confirm() {
  if [ "$USE_ZENITY" -eq 1 ]; then
    zenity --question \
      --title="BeatFetch Uninstaller" \
      --text="This will remove the installed BeatFetch command and shell PATH entries.\n\nContinue?" \
      --width=360 \
      || { echo -e "${RED}Uninstall cancelled.${RESET}"; exit 0; }
    return
  fi

  echo -e "${YELLOW}This will remove the installed BeatFetch command and shell PATH entries.${RESET}"
  local confirm
  read -rp "Continue? [y/N]: " confirm
  case "$confirm" in
    y|Y|yes|YES) return 0 ;;
    *) echo -e "${RED}Uninstall cancelled.${RESET}"; exit 0 ;;
  esac
}

finish_success() {
  echo
  echo -e "${GREEN}BeatFetch has been uninstalled.${RESET}"
  echo -e "${DIM}You may need to reopen the terminal or run: source ~/.bashrc${RESET}"

  if [ "$USE_ZENITY" -eq 1 ]; then
    local summary
    if [ "${#STATUS_LOG[@]}" -eq 0 ]; then
      summary="No BeatFetch files were found — nothing to remove."
    else
      summary="$(printf '%s\n' "${STATUS_LOG[@]}")"
    fi
    zenity --info --title="BeatFetch Uninstaller" \
      --text="BeatFetch has been uninstalled.

${summary}

Open a new terminal, or run: source ~/.bashrc" \
      --width=400 2>/dev/null || true
  fi
}

parse_args "$@"
ui_banner
setup_mode
prompt_confirm
remove_binary
remove_python_wrapper
remove_repo_stubs
clean_shell_path
finish_success
