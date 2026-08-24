#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# BeatFetch (C++) — all-in-one installer / uninstaller
#
# Fetches the source directly from GitHub (no need to have the
# repo checked out locally first), builds it, and installs it.
# Also handles removal via --uninstall.
#
#   Repo: https://github.com/danielkrizz00-alt/beatfetch-CPP
# ============================================================

REPO_URL="https://github.com/danielkrizz00-alt/beatfetch-CPP.git"
REPO_TARBALL_BASE="https://codeload.github.com/danielkrizz00-alt/beatfetch-CPP/tar.gz/refs/heads"
BRANCH="main"

SRC_DIR="$HOME/.local/share/beatfetch-cpp/src"
BIN_PATH="$HOME/.local/bin/beatfetch"
PATH_MARKER="# Added by BeatFetch C++ installer"
PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'

BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[32m'
CYAN='\033[36m'
YELLOW='\033[33m'
RED='\033[31m'
RESET='\033[0m'

USE_ZENITY=0
FORCE_MODE=""
ACTION="install"
LOG_FILE="$(mktemp /tmp/beatfetch-installer.XXXXXX.log)"
SUDO_KEEPALIVE_PID=""
STATUS_LOG=()

usage() {
  cat <<EOF
Usage: $(basename "$0") [--install|--uninstall] [--gui|--no-gui] [--branch <name>] [-h|--help]

  --install    Fetch, build, and install BeatFetch (default).
  --uninstall  Remove an installed BeatFetch.
  --gui        Force the zenity-based graphical UI (requires a display).
  --no-gui     Force the plain terminal UI, even in a graphical session.
  --branch     Git branch/ref to fetch (default: main).
  -h, --help   Show this help text.
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --install) ACTION="install" ;;
      --uninstall) ACTION="uninstall" ;;
      --gui) FORCE_MODE="gui" ;;
      --no-gui|--cli) FORCE_MODE="cli" ;;
      --branch) BRANCH="${2:-main}"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo -e "${RED}Unknown option: $1${RESET}"; usage; exit 1 ;;
    esac
    shift
  done
}

ui_banner() {
  clear
  local title="BeatFetch C++ Installer"
  [ "$ACTION" = "uninstall" ] && title="BeatFetch C++ Uninstaller"
  echo -e "${BOLD}${CYAN}========================================${RESET}"
  printf "${BOLD}%*s${RESET}\n" $(( (40 + ${#title}) / 2 )) "$title"
  echo -e "${BOLD}${CYAN}========================================${RESET}"
  echo
}

has_display() {
  [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]
}

ensure_zenity() {
  has_display || return 1

  if command -v zenity >/dev/null 2>&1; then
    return 0
  fi

  # Only offer to install zenity when doing a fresh install; uninstall
  # shouldn't need sudo or a package install of its own.
  [ "$ACTION" = "uninstall" ] && return 1

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

log_status() {
  STATUS_LOG+=("$1")
}

# ---------------- install path ----------------

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

  ( while true; do sudo -n -v 2>/dev/null; sleep 60; done ) &
  SUDO_KEEPALIVE_PID=$!
  trap '[ -n "$SUDO_KEEPALIVE_PID" ] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null; true' EXIT
}

fetch_source() {
  echo -e "${DIM}Fetching BeatFetch source (branch: ${BRANCH})...${RESET}"
  mkdir -p "$(dirname "$SRC_DIR")"
  rm -rf "$SRC_DIR"

  if command -v git >/dev/null 2>&1; then
    git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$SRC_DIR"
    return
  fi

  echo -e "${DIM}git not found, downloading a tarball instead...${RESET}"
  mkdir -p "$SRC_DIR"
  local tmp_tar
  tmp_tar="$(mktemp --suffix=.tar.gz)"
  curl -sL -o "$tmp_tar" "$REPO_TARBALL_BASE/$BRANCH"
  tar -xzf "$tmp_tar" -C "$SRC_DIR" --strip-components=1
  rm -f "$tmp_tar"
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
  echo -e "${DIM}Building BeatFetch from source...${RESET}"
  make -C "$SRC_DIR"

  mkdir -p "$HOME/.local/bin"
  cat > "$BIN_PATH" <<EOF
#!/usr/bin/env bash
exec "$SRC_DIR/beatfetch" --fetch-backend "$BACKEND" "\$@"
EOF
  chmod +x "$BIN_PATH"

  if ! grep -Fq "$PATH_MARKER" "$HOME/.bashrc" 2>/dev/null; then
    printf '\n%s\n%s\n' "$PATH_MARKER" "$PATH_LINE" >> "$HOME/.bashrc"
  fi
}

finish_install_success() {
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

# ---------------- uninstall path ----------------

prompt_uninstall_confirm() {
  if [ "$USE_ZENITY" -eq 1 ]; then
    zenity --question \
      --title="BeatFetch C++ Uninstaller" \
      --text="This will remove the installed BeatFetch command, its source checkout, and shell PATH entries.\n\nContinue?" \
      --width=360 \
      || { echo -e "${RED}Uninstall cancelled.${RESET}"; exit 0; }
    return
  fi

  echo -e "${YELLOW}This will remove the installed BeatFetch command, its source checkout, and shell PATH entries.${RESET}"
  local confirm
  read -rp "Continue? [y/N]: " confirm
  case "$confirm" in
    y|Y|yes|YES) return 0 ;;
    *) echo -e "${RED}Uninstall cancelled.${RESET}"; exit 0 ;;
  esac
}

remove_binary() {
  if [ -f "$BIN_PATH" ]; then
    rm -f "$BIN_PATH"
    echo -e "${GREEN}Removed user binary: $BIN_PATH${RESET}"
    log_status "Removed $BIN_PATH"
  else
    echo -e "${YELLOW}No user-level beatfetch binary found.${RESET}"
  fi
}

remove_source() {
  if [ -d "$SRC_DIR" ]; then
    rm -rf "$SRC_DIR"
    echo -e "${GREEN}Removed source checkout: $SRC_DIR${RESET}"
    log_status "Removed $SRC_DIR"
  fi
  # Clean up the parent dir if it's now empty.
  rmdir "$(dirname "$SRC_DIR")" 2>/dev/null || true
}

remove_legacy_leftovers() {
  # Covers files/dirs left behind by older versions of the installer.
  if [ -f "$HOME/.local/bin/beatfetch.py" ]; then
    rm -f "$HOME/.local/bin/beatfetch.py"
    log_status "Removed $HOME/.local/bin/beatfetch.py"
  fi
  for target in "$HOME/.local/share/beatfetch" "$HOME/.local/share/BeatFetch" "$HOME/.cache/beatfetch"; do
    if [ -d "$target" ]; then
      rm -rf "$target"
      echo -e "${GREEN}Removed leftover files in $target${RESET}"
      log_status "Removed $target"
    fi
  done
}

clean_shell_path() {
  if [ -f "$HOME/.bashrc" ] && grep -Fq "$PATH_MARKER" "$HOME/.bashrc"; then
    cp "$HOME/.bashrc" "$HOME/.bashrc.bak.beatfetch"
    grep -Fvx "$PATH_MARKER" "$HOME/.bashrc" | grep -Fv "$PATH_LINE" > "$HOME/.bashrc.tmp" || true
    mv "$HOME/.bashrc.tmp" "$HOME/.bashrc"
    echo -e "${GREEN}Removed PATH entries from ~/.bashrc${RESET}"
    log_status "Cleaned PATH entry from ~/.bashrc (backup: ~/.bashrc.bak.beatfetch)"
  fi
}

finish_uninstall_success() {
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
    zenity --info --title="BeatFetch C++ Uninstaller" \
      --text="BeatFetch has been uninstalled.

${summary}

Open a new terminal, or run: source ~/.bashrc" \
      --width=400 2>/dev/null || true
  fi
}

# ---------------- shared helpers ----------------

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

run_install() {
  choose_backend
  prime_sudo
  with_progress_dialog "Installing system dependencies..." install_system_deps
  with_progress_dialog "Fetching BeatFetch source..." fetch_source
  with_progress_dialog "Building BeatFetch..." build_and_install
  finish_install_success
}

run_uninstall() {
  prompt_uninstall_confirm
  remove_binary
  remove_source
  remove_legacy_leftovers
  clean_shell_path
  finish_uninstall_success
}

parse_args "$@"
ui_banner
setup_mode
case "$ACTION" in
  install) run_install ;;
  uninstall) run_uninstall ;;
esac
