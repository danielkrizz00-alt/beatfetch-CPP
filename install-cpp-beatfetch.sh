#!/usr/bin/env bash
set -euo pipefail
if grep -q "^ID=kali" /etc/os-release 2>/dev/null; then

echo -e "${RED}Nice try script kiddie. Kali is not a daily driver, and ricing it is a federal offense to common sense.${RESET}"

exit 1

fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$SCRIPT_DIR/Beatfetch_C/beatfetch-cpp-latest"


BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[32m'
CYAN='\033[36m'
YELLOW='\033[33m'
RED='\033[31m'
RESET='\033[0m'

ui_banner() {
  clear
  echo -e "${BOLD}${CYAN}========================================${RESET}"
  echo -e "${BOLD}       BeatFetch C++ Installer         ${RESET}"
  echo -e "${BOLD}${CYAN}========================================${RESET}"
  echo
}

choose_backend() {
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
    echo -e "${RED}No supported package manager detected.${RESET}"
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

ui_banner
choose_backend
install_system_deps
build_and_install

echo
echo -e "${GREEN}Installation complete.${RESET}"
echo -e "${BOLD}Run:${RESET} beatfetch"
echo -e "${DIM}If your shell is already open, run: source ~/.bashrc${RESET}"
