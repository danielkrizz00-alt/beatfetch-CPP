#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$SCRIPT_DIR/Beatfetch_C/beatfetch-cpp-latest"

BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[32m'
CYAN='\033[36m'
YELLOW='\033[33m'
RED='\033[31m'
RESET='\033[0m'

USE_ZENITY=0
FORCE_MODE=""
LOG_FILE="$(mktemp /tmp/beatfetch-install.XXXXXX.log)"
SUDO_KEEPALIVE_PID=""

usage() {
  cat <<EOF
Usage: $(basename "$0") [--gui|--no-gui] [-h|--help]

  --gui      Force the zenity-based graphical installer (requires a display).
  --no-gui   Force the plain terminal installer, even in a graphical session.
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
  echo -e "${BOLD}       BeatFetch C++ Installer         ${RESET}"
  echo -e "${BOLD}${CYAN}========================================${RESET}"
  echo
}

has_display() {
  [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]
}

ensure_zenity() {
  # Only bother trying if we're actually in a graphical session.
  has_display || return 1

  if command -v zenity >/dev/null 2>&1; then
    return 0
  fi

  echo -e "${DIM}Graphical session detected but zenity isn't installed. Installing it...${RESET}"
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update && sudo apt-get install -y zenity
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y zenity
  elif command -v pacman >/dev/null 2>&1; then
    sudo pacman -Sy --noconfirm zenity
  elif command -v zypper >/dev/null 2>&1; then
    sudo zypper install -y zenity
  fi

  command -v zenity >/dev/null 2>&1
}

setup_mode() {
  case "$FORCE_MODE" in
    gui)
      if ensure_zenity; then
        USE_ZENITY=1
      else
        echo -e "${YELLOW}zenity isn't available (no display, or install failed); falling back to terminal prompts.${RESET}"
        USE_ZENITY=0
      fi
      ;;
    cli)
      USE_ZENITY=0
      ;;
    *)
      if ensure_zenity; then
        USE_ZENITY=1
        echo -e "${DIM}Graphical session detected — using zenity dialogs. Pass --no-gui to use the terminal instead.${RESET}"
      else
        USE_ZENITY=0
      fi
      ;;
  esac
}

zerror() {
  echo -e "${RED}$1${RESET}" >&2
  if [ "$USE_ZENITY" -eq 1 ]; then
    zenity --error --title="BeatFetch C++ Installer" --text="$1" --width=360 2>/dev/null || true
  fi
}

choose_backend() {
  if [ "$USE_ZENITY" -eq 1 ]; then
    local selection
    selection="$(zenity --list \
      --title="BeatFetch C++ Installer" \
      --text="Choose a fetch backend:" \
      --radiolist --hide-header \
      --column="Pick" --column="Backend" \
      TRUE  fastfetch \
      FALSE hyfetch \
      FALSE neofetch \
      --width=360 --height=260)" || { zerror "Installation cancelled."; exit 1; }

    case "$selection" in
      fastfetch|hyfetch|neofetch) BACKEND="$selection" ;;
      *) zerror "No backend selected."; exit 1 ;;
    esac
    echo -e "${DIM}Backend selected: ${BACKEND}${RESET}"
    return
  fi

  local choice
  while true; do
    echo -e "${YELLOW}Choose a fetch backend:${RESET}"
    echo "  1) fastfetch"
    echo "  2) hyfetch"
    echo "  3) neofetch"
    read -rp "Select [1-3, default 1]: " choice
    choice="${choice:-1}"
    case "$choice" in
      1) BACKEND="fastfetch"; break ;;
      2) BACKEND="hyfetch"; break ;;
      3) BACKEND="neofetch"; break ;;
      *) echo -e "${RED}Invalid choice.${RESET}" ;;
    esac
  done
}

prime_sudo() {
  if [ "$USE_ZENITY" -eq 1 ]; then
    local pass
    pass="$(zenity --password --title="BeatFetch C++ Installer" --text="Administrator password is needed to install dependencies:")" \
      || { zerror "Installation cancelled."; exit 1; }
    if ! printf '%s\n' "$pass" | sudo -S -v 2>/dev/null; then
      unset pass
      zerror "Incorrect password."
      exit 1
    fi
    unset pass
  else
    sudo -v
  fi

  # Keep the sudo timestamp alive in the background so later steps
  # (running under a progress dialog) don't need to prompt again.
  ( while true; do sudo -n -v 2>/dev/null; sleep 60; done ) &
  SUDO_KEEPALIVE_PID=$!
  trap '[ -n "$SUDO_KEEPALIVE_PID" ] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null; true' EXIT
}

install_system_deps() {
  if command -v apt-get >/dev/null 2>&1; then
    echo -e "${DIM}Detected apt-get. Installing build tools and runtime dependencies...${RESET}"
    sudo apt-get update
    sudo apt-get install -y build-essential curl git
    case "$BACKEND" in
      fastfetch)
        if apt-cache show fastfetch >/dev/null 2>&1; then sudo apt-get install -y fastfetch; else
          tmp_deb="$(mktemp --suffix=.deb)"
          curl -sL -o "$tmp_deb" "https://github.com/fastfetch-cli/fastfetch/releases/latest/download/fastfetch-linux-amd64.deb"
          sudo dpkg -i "$tmp_deb" || sudo apt-get install -f -y
          rm -f "$tmp_deb"
        fi
        ;;
      hyfetch)
        sudo apt-get install -y python3-pip python3-rich
        python3 -m pip install --user --break-system-packages hyfetch prompt-toolkit
        ;;
      neofetch)
        sudo apt-get install -y neofetch
        ;;
    esac
    sudo apt-get install -y playerctl cava
  elif command -v dnf >/dev/null 2>&1; then
    echo -e "${DIM}Detected dnf. Installing build tools and runtime dependencies...${RESET}"
    sudo dnf install -y gcc-c++ make curl git
    case "$BACKEND" in
      fastfetch) sudo dnf install -y fastfetch ;;
      hyfetch)
        sudo dnf install -y python3-pip python3-rich
        python3 -m pip install --user --break-system-packages hyfetch prompt-toolkit
        ;;
      neofetch) sudo dnf install -y neofetch ;;
    esac
    sudo dnf install -y playerctl cava
  elif command -v pacman >/dev/null 2>&1; then
    echo -e "${DIM}Detected pacman. Installing build tools and runtime dependencies...${RESET}"
    sudo pacman -Sy --noconfirm base-devel curl git
    case "$BACKEND" in
      fastfetch) sudo pacman -Sy --noconfirm fastfetch ;;
      hyfetch)
        sudo pacman -Sy --noconfirm python-pip python-rich
        python3 -m pip install --user --break-system-packages hyfetch prompt-toolkit
        ;;
      neofetch) sudo pacman -Sy --noconfirm neofetch ;;
    esac
    sudo pacman -Sy --noconfirm playerctl cava
  elif command -v zypper >/dev/null 2>&1; then
    echo -e "${DIM}Detected zypper. Installing build tools and runtime dependencies...${RESET}"
    sudo zypper install -y gcc-c++ make curl git
    case "$BACKEND" in
      fastfetch) sudo zypper install -y fastfetch ;;
      hyfetch)
        sudo zypper install -y python3-pip python3-rich
        python3 -m pip install --user --break-system-packages hyfetch prompt-toolkit
        ;;
      neofetch) sudo zypper install -y neofetch ;;
    esac
    sudo zypper install -y playerctl cava
  else
    zerror "No supported package manager detected."
    exit 1
  fi
}

build_and_install() {
  echo -e "${DIM}Building the latest C++ BeatFetch source...${RESET}"
  make -C "$APP_DIR"
  mkdir -p "$HOME/.local/bin"
  cat > "$HOME/.local/bin/beatfetch" <<EOF
#!/usr/bin/env bash
exec "$APP_DIR/beatfetch" --fetch-backend "$BACKEND" "\$@"
EOF
  chmod +x "$HOME/.local/bin/beatfetch"

  PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
  if ! grep -Fq "$PATH_LINE" "$HOME/.bashrc" 2>/dev/null; then
    printf '\n# Added by BeatFetch C++ installer\n%s\n' "$PATH_LINE" >> "$HOME/.bashrc"
  fi
}

# Runs a step function; if zenity is active, shows a pulsating progress
# dialog while it runs. Output is always still tee'd to the terminal
# and to LOG_FILE, and the dialog is torn down once the step finishes.
with_progress_dialog() {
  local text="$1" fn="$2" zpid="" status

  if [ "$USE_ZENITY" -eq 1 ]; then
    zenity --progress --title="BeatFetch C++ Installer" --text="$text" \
      --pulsate --no-cancel --auto-close 2>/dev/null &
    zpid=$!
  fi

  set +e
  "$fn" 2>&1 | tee -a "$LOG_FILE"
  status=${PIPESTATUS[0]}
  set -e

  if [ -n "$zpid" ]; then
    kill "$zpid" 2>/dev/null || true
    wait "$zpid" 2>/dev/null || true
  fi

  if [ "$status" -ne 0 ]; then
    zerror "Step failed: $text (see $LOG_FILE for details)"
    exit "$status"
  fi
}

finish_success() {
  echo
  echo -e "${GREEN}Installation complete.${RESET}"
  echo -e "${BOLD}Run:${RESET} beatfetch"
  echo -e "${DIM}If your shell is already open, run: source ~/.bashrc${RESET}"

  if [ "$USE_ZENITY" -eq 1 ]; then
    zenity --info --title="BeatFetch C++ Installer" \
      --text="Installation complete.\n\nOpen a new terminal and run <b>beatfetch</b>, or run:\nsource ~/.bashrc" \
      --width=360 2>/dev/null || true
  fi
}

parse_args "$@"
ui_banner
setup_mode
choose_backend
prime_sudo
with_progress_dialog "Installing system dependencies..." install_system_deps
with_progress_dialog "Building BeatFetch..." build_and_install
finish_success
