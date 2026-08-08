#!/usr/bin/env bash
#
# BeatFetch C++ Installer
#
# Builds and installs the BeatFetch C++ system-info/now-playing fetch tool,
# a chosen fetch backend (fastfetch / hyfetch / neofetch), and the optional
# media helpers (playerctl, cava).
#
# Supports: Debian/Ubuntu (apt), Fedora/RHEL (dnf/yum), Arch (pacman),
#           openSUSE (zypper), Alpine (apk), Void (xbps), Gentoo (emerge),
#           FreeBSD (pkg), macOS (brew).
#
# Run `./install.sh --help` for usage.

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Metadata & paths
# ---------------------------------------------------------------------------
SCRIPT_VERSION="2.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$SCRIPT_DIR/Beatfetch_C/beatfetch-cpp-latest"
LOG_FILE="${TMPDIR:-/tmp}/beatfetch-install-$$.log"
: > "$LOG_FILE" 2>/dev/null || LOG_FILE="/dev/null"

# ---------------------------------------------------------------------------
# Defaults (overridable via flags or environment variables)
# ---------------------------------------------------------------------------
BACKEND="${BEATFETCH_BACKEND:-}"
INSTALL_PREFIX="${BEATFETCH_PREFIX:-$HOME/.local/bin}"
ASSUME_YES="${BEATFETCH_YES:-false}"
SKIP_DEPS=false
MINIMAL=false
FORCE=false
DRY_RUN=false
DO_UNINSTALL=false
VERBOSE=false
NO_COLOR="${NO_COLOR:-false}"
JOBS="$( (command -v nproc >/dev/null 2>&1 && nproc) || (command -v sysctl >/dev/null 2>&1 && sysctl -n hw.ncpu) || echo 2 )"
UPDATED_INDEX=false

# ---------------------------------------------------------------------------
# Colors (disabled automatically for non-tty output or NO_COLOR)
# ---------------------------------------------------------------------------
setup_colors() {
  if [[ -t 1 ]] && [[ "$NO_COLOR" != "true" ]]; then
    BOLD='\033[1m'; DIM='\033[2m'; GREEN='\033[32m'; CYAN='\033[36m'
    YELLOW='\033[33m'; RED='\033[31m'; RESET='\033[0m'
  else
    BOLD=''; DIM=''; GREEN=''; CYAN=''; YELLOW=''; RED=''; RESET=''
  fi
}
setup_colors

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log()       { printf '%s\n' "$*" >> "$LOG_FILE" 2>/dev/null || true; }
log_info()  { echo -e "${CYAN}[*]${RESET} $*";  log "[INFO] $*"; }
log_ok()    { echo -e "${GREEN}[+]${RESET} $*"; log "[ OK ] $*"; }
log_warn()  { echo -e "${YELLOW}[!]${RESET} $*" >&2; log "[WARN] $*"; }
log_err()   { echo -e "${RED}[x]${RESET} $*" >&2;    log "[ERR ] $*"; }
log_debug() { [[ "$VERBOSE" == "true" ]] && echo -e "${DIM}[.] $*${RESET}"; log "[DBG ] $*"; }

on_error() {
  local line=$1
  log_err "Installation failed at line $line. See log: $LOG_FILE"
  exit 1
}
trap 'on_error $LINENO' ERR
trap 'rm -rf "${TMP_DL:-}" 2>/dev/null || true' EXIT

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
# run <cmd...>  -- honors --dry-run, logs every command executed
run() {
  log_debug "+ $*"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${DIM}[dry-run] $*${RESET}"
    return 0
  fi
  "$@"
}

is_tty()      { [[ -t 0 ]]; }
have()        { command -v "$1" >/dev/null 2>&1; }
lower()       { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

confirm() {
  local prompt="$1"
  [[ "$ASSUME_YES" == "true" ]] && return 0
  if ! is_tty; then
    log_debug "Non-interactive shell, assuming yes for: $prompt"
    return 0
  fi
  local reply
  read -rp "$(echo -e "${YELLOW}${prompt} [Y/n]: ${RESET}")" reply
  reply="$(lower "${reply:-y}")"
  [[ "$reply" == "y" || "$reply" == "yes" ]]
}

# sudo_run <cmd...> -- skips sudo if already root or if the package manager
# (e.g. brew) refuses to run as root.
sudo_run() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    run "$@"
  elif have sudo; then
    if [[ "$DRY_RUN" == "true" ]]; then
      echo -e "${DIM}[dry-run] sudo $*${RESET}"
    else
      log_debug "+ sudo $*"
      sudo "$@"
    fi
  else
    log_err "This step needs root privileges and 'sudo' isn't available. Re-run as root or install sudo."
    exit 1
  fi
}

fetch_url() {
  # fetch_url <url> <dest>
  local url="$1" dest="$2"
  if have curl; then
    curl -fsSL --retry 3 --retry-delay 2 -o "$dest" "$url"
  elif have wget; then
    wget -q --tries=3 -O "$dest" "$url"
  else
    log_err "Neither curl nor wget is available to download $url"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
${BOLD}BeatFetch C++ Installer${RESET} v${SCRIPT_VERSION}

Usage: $(basename "$0") [options]

  -b, --backend NAME     Fetch backend: fastfetch | hyfetch | neofetch
  -p, --prefix PATH      Install location for the beatfetch binary (default: $HOME/.local/bin)
  -j, --jobs N            Parallel build jobs (default: detected CPU count)
  -y, --yes               Assume "yes" to prompts / non-interactive mode
      --minimal            Skip optional extras (playerctl, cava)
      --skip-deps          Don't install system packages, just build & link
      --force              Reinstall/rebuild even if already present
      --dry-run            Print what would happen without changing anything
      --uninstall          Remove the installed binary and PATH entries
      --no-color           Disable colored output
  -v, --verbose            Verbose/debug logging
  -h, --help               Show this help and exit
      --version             Show installer version and exit

Environment overrides: BEATFETCH_BACKEND, BEATFETCH_PREFIX, BEATFETCH_YES, NO_COLOR
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -b|--backend)       BACKEND="$2"; shift 2 ;;
      --backend=*)        BACKEND="${1#*=}"; shift ;;
      -p|--prefix)        INSTALL_PREFIX="$2"; shift 2 ;;
      --prefix=*)         INSTALL_PREFIX="${1#*=}"; shift ;;
      -j|--jobs)          JOBS="$2"; shift 2 ;;
      --jobs=*)           JOBS="${1#*=}"; shift ;;
      -y|--yes)           ASSUME_YES=true; shift ;;
      --minimal)          MINIMAL=true; shift ;;
      --skip-deps)        SKIP_DEPS=true; shift ;;
      --force)            FORCE=true; shift ;;
      --dry-run)          DRY_RUN=true; shift ;;
      --uninstall)        DO_UNINSTALL=true; shift ;;
      --no-color)         NO_COLOR=true; setup_colors; shift ;;
      -v|--verbose)       VERBOSE=true; shift ;;
      -h|--help)          usage; exit 0 ;;
      --version)          echo "$SCRIPT_VERSION"; exit 0 ;;
      *) log_err "Unknown option: $1"; usage; exit 1 ;;
    esac
  done

  if [[ -n "$BACKEND" ]]; then
    BACKEND="$(lower "$BACKEND")"
    case "$BACKEND" in
      fastfetch|hyfetch|neofetch) : ;;
      *) log_err "Invalid backend '$BACKEND' (expected fastfetch, hyfetch, or neofetch)"; exit 1 ;;
    esac
  fi
}

# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------
ui_banner() {
  [[ -t 1 ]] && clear
  echo -e "${BOLD}${CYAN}========================================${RESET}"
  echo -e "${BOLD}       BeatFetch C++ Installer         ${RESET}"
  echo -e "${DIM}                v${SCRIPT_VERSION}${RESET}"
  echo -e "${BOLD}${CYAN}========================================${RESET}"
  echo
}

choose_backend() {
  if [[ -n "$BACKEND" ]]; then
    log_info "Using backend: $BACKEND"
    return
  fi
  if ! is_tty; then
    BACKEND="fastfetch"
    log_warn "Non-interactive session, defaulting backend to '$BACKEND' (use --backend to override)."
    return
  fi
  local choice
  while true; do
    echo -e "${YELLOW}Choose a fetch backend:${RESET}"
    echo "  1) fastfetch  (fast, native, recommended)"
    echo "  2) hyfetch    (python, colorful themes)"
    echo "  3) neofetch   (classic, unmaintained upstream)"
    read -rp "Select [1-3, default 1]: " choice
    choice="${choice:-1}"
    case "$choice" in
      1) BACKEND="fastfetch"; break ;;
      2) BACKEND="hyfetch"; break ;;
      3) BACKEND="neofetch"; break ;;
      *) log_err "Invalid choice." ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# OS / package manager / architecture detection
# ---------------------------------------------------------------------------
PKG_MANAGER=""
OS_FAMILY=""

detect_os() {
  case "$(uname -s)" in
    Linux)
      if have apt-get;  then PKG_MANAGER="apt"
      elif have dnf;    then PKG_MANAGER="dnf"
      elif have yum;    then PKG_MANAGER="yum"
      elif have pacman; then PKG_MANAGER="pacman"
      elif have zypper; then PKG_MANAGER="zypper"
      elif have apk;    then PKG_MANAGER="apk"
      elif have xbps-install; then PKG_MANAGER="xbps"
      elif have emerge; then PKG_MANAGER="emerge"
      else
        log_err "No supported package manager detected on this Linux system."
        exit 1
      fi
      OS_FAMILY="linux"
      ;;
    Darwin)
      if ! have brew; then
        log_err "Homebrew is required on macOS. Install it from https://brew.sh and re-run."
        exit 1
      fi
      PKG_MANAGER="brew"
      OS_FAMILY="darwin"
      ;;
    FreeBSD)
      PKG_MANAGER="pkg"
      OS_FAMILY="bsd"
      ;;
    *)
      log_err "Unsupported operating system: $(uname -s)"
      exit 1
      ;;
  esac
  log_info "Detected package manager: $PKG_MANAGER"
}

ARCH=""
FF_ARCH=""
detect_arch() {
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64|amd64)   FF_ARCH="amd64" ;;
    aarch64|arm64)  FF_ARCH="aarch64" ;;
    armv7l|armv7)   FF_ARCH="armv7" ;;
    *)              FF_ARCH="" ;;
  esac
  log_debug "Architecture: $ARCH (fastfetch arch tag: ${FF_ARCH:-unknown})"
}

# ---------------------------------------------------------------------------
# Package name mapping (kept as case statements for maximum shell portability
# -- this must also run under macOS's stock bash 3.2, which lacks assoc arrays)
# ---------------------------------------------------------------------------
pkg_build_tools() {
  case "$PKG_MANAGER" in
    apt)             echo "build-essential curl git" ;;
    dnf|yum)         echo "gcc-c++ make curl git" ;;
    pacman)          echo "base-devel curl git" ;;
    zypper)          echo "gcc-c++ make curl git" ;;
    apk)             echo "build-base curl git" ;;
    xbps)            echo "base-devel curl git" ;;
    emerge)          echo "curl git" ;; # toolchain is part of @system on Gentoo
    pkg)             echo "curl git gmake" ;;
    brew)            echo "curl git" ;; # Xcode CLT provides the compiler
    *)               echo "" ;;
  esac
}

pkg_extra_tools() {
  # playerctl + cava. Skipped entirely in --minimal mode by the caller.
  case "$PKG_MANAGER" in
    apt)             echo "playerctl cava" ;;
    dnf|yum)         echo "playerctl cava" ;;
    pacman)          echo "playerctl cava" ;;
    zypper)          echo "playerctl cava" ;;
    apk)             echo "playerctl cava" ;;
    xbps)            echo "playerctl cava" ;;
    emerge)          echo "media-sound/cava" ;; # playerctl not in main tree everywhere
    pkg)             echo "playerctl cava" ;;
    brew)            echo "cava" ;; # playerctl relies on Linux MPRIS/D-Bus, skipped on macOS
    *)               echo "" ;;
  esac
}

pkg_native_backend() {
  # Returns the native package name for $BACKEND, or empty if this package
  # manager doesn't carry it (triggers a source/binary fallback instead).
  case "$BACKEND" in
    fastfetch)
      case "$PKG_MANAGER" in
        apt|dnf|yum|pacman|zypper|apk|xbps|brew) echo "fastfetch" ;;
        *) echo "" ;;
      esac
      ;;
    neofetch)
      case "$PKG_MANAGER" in
        apt|dnf|yum|pacman|zypper|apk|xbps|emerge|pkg|brew) echo "neofetch" ;;
        *) echo "" ;;
      esac
      ;;
    hyfetch)
      echo "" # always installed via pip, see install_hyfetch
      ;;
  esac
}

pkg_python() {
  case "$PKG_MANAGER" in
    apt)     echo "python3-pip" ;;
    dnf|yum) echo "python3-pip" ;;
    pacman)  echo "python-pip" ;;
    zypper)  echo "python3-pip" ;;
    apk)     echo "py3-pip" ;;
    xbps)    echo "python3-pip" ;;
    emerge)  echo "dev-python/pip" ;;
    pkg)     echo "py311-pip" ;;
    brew)    echo "" ;; # brew's python3 already includes pip
    *)       echo "" ;;
  esac
}

# ---------------------------------------------------------------------------
# Generic package manager dispatch
# ---------------------------------------------------------------------------
pkg_update_index() {
  [[ "$UPDATED_INDEX" == "true" ]] && return 0
  log_info "Refreshing package index..."
  case "$PKG_MANAGER" in
    apt)     sudo_run apt-get update ;;
    dnf)     sudo_run dnf check-update || true ;;
    yum)     sudo_run yum check-update || true ;;
    pacman)  sudo_run pacman -Sy --noconfirm ;;
    zypper)  sudo_run zypper --non-interactive refresh ;;
    apk)     sudo_run apk update ;;
    xbps)    sudo_run xbps-install -S ;;
    emerge)  sudo_run emerge --sync --quiet || true ;;
    pkg)     sudo_run pkg update ;;
    brew)    run brew update ;;
  esac
  UPDATED_INDEX=true
}

pkg_install() {
  # pkg_install <space-separated package list>
  # Word-splitting of $pkgs below is intentional: each mapping function
  # returns a space-separated list that must expand to multiple arguments.
  local pkgs="$*"
  [[ -z "${pkgs// /}" ]] && return 0
  log_info "Installing: $pkgs"
  # shellcheck disable=SC2086
  case "$PKG_MANAGER" in
    apt)     sudo_run apt-get install -y --no-install-recommends $pkgs ;;
    dnf)     sudo_run dnf install -y $pkgs ;;
    yum)     sudo_run yum install -y $pkgs ;;
    pacman)  sudo_run pacman -S --noconfirm --needed $pkgs ;;
    zypper)  sudo_run zypper --non-interactive install $pkgs ;;
    apk)     sudo_run apk add --no-cache $pkgs ;;
    xbps)    sudo_run xbps-install -y $pkgs ;;
    emerge)  sudo_run emerge --quiet --noreplace $pkgs ;;
    pkg)     sudo_run pkg install -y $pkgs ;;
    brew)    run brew install $pkgs ;;
  esac
}

# ---------------------------------------------------------------------------
# Backend installation (native package first, portable fallback second)
# ---------------------------------------------------------------------------
install_fastfetch_fallback() {
  log_warn "No native fastfetch package for $PKG_MANAGER; downloading a prebuilt release instead."
  if [[ -z "$FF_ARCH" ]]; then
    log_err "No prebuilt fastfetch release available for architecture '$ARCH'. Install it manually."
    return 1
  fi

  local asset url
  case "$PKG_MANAGER" in
    apt)
      asset="fastfetch-linux-${FF_ARCH}.deb"
      url="https://github.com/fastfetch-cli/fastfetch/releases/latest/download/${asset}"
      TMP_DL="$(mktemp --suffix=.deb 2>/dev/null || mktemp)"
      run fetch_url "$url" "$TMP_DL"
      sudo_run dpkg -i "$TMP_DL" || sudo_run apt-get install -f -y
      ;;
    dnf|yum|zypper)
      asset="fastfetch-linux-${FF_ARCH}.rpm"
      url="https://github.com/fastfetch-cli/fastfetch/releases/latest/download/${asset}"
      TMP_DL="$(mktemp --suffix=.rpm 2>/dev/null || mktemp)"
      run fetch_url "$url" "$TMP_DL"
      sudo_run rpm -Uvh --replacepkgs "$TMP_DL"
      ;;
    *)
      # Generic archive fallback: unpack the standalone binary straight into
      # the install prefix. Works anywhere tar is available.
      asset="fastfetch-linux-${FF_ARCH}.tar.gz"
      url="https://github.com/fastfetch-cli/fastfetch/releases/latest/download/${asset}"
      TMP_DL="$(mktemp -d 2>/dev/null || mktemp -d -t beatfetch)"
      run fetch_url "$url" "$TMP_DL/fastfetch.tar.gz"
      run tar -xzf "$TMP_DL/fastfetch.tar.gz" -C "$TMP_DL"
      mkdir -p "$INSTALL_PREFIX"
      run cp "$(find "$TMP_DL" -type f -name fastfetch | head -n1)" "$INSTALL_PREFIX/fastfetch"
      run chmod +x "$INSTALL_PREFIX/fastfetch"
      ;;
  esac
}

install_neofetch_fallback() {
  log_warn "No native neofetch package for $PKG_MANAGER; fetching the upstream script instead."
  mkdir -p "$INSTALL_PREFIX"
  run fetch_url "https://raw.githubusercontent.com/dylanaraps/neofetch/master/neofetch" "$INSTALL_PREFIX/neofetch"
  run chmod +x "$INSTALL_PREFIX/neofetch"
}

install_hyfetch() {
  local py_pkg pip_bin
  py_pkg="$(pkg_python)"
  [[ -n "$py_pkg" ]] && pkg_install "$py_pkg"

  pip_bin="pip3"; have pip3 || pip_bin="pip"
  if ! have "$pip_bin"; then
    log_err "pip is not available after installing dependencies; cannot install hyfetch."
    return 1
  fi
  log_info "Installing hyfetch via $pip_bin..."
  run "$pip_bin" install --user --break-system-packages hyfetch prompt-toolkit 2>/dev/null \
    || run "$pip_bin" install --user hyfetch prompt-toolkit
}

install_backend() {
  if have "$BACKEND" && [[ "$FORCE" != "true" ]]; then
    log_ok "$BACKEND is already installed, skipping (use --force to reinstall)."
    return
  fi

  case "$BACKEND" in
    hyfetch)
      install_hyfetch
      ;;
    fastfetch|neofetch)
      local native
      native="$(pkg_native_backend)"
      if [[ -n "$native" ]]; then
        pkg_install "$native"
      fi
      if ! have "$BACKEND"; then
        [[ "$BACKEND" == "fastfetch" ]] && install_fastfetch_fallback
        [[ "$BACKEND" == "neofetch" ]] && install_neofetch_fallback
      fi
      ;;
  esac

  if have "$BACKEND"; then
    log_ok "$BACKEND installed."
  else
    log_warn "$BACKEND could not be verified on PATH; beatfetch may not find it until PATH is refreshed."
  fi
}

install_extra_tools() {
  if [[ "$MINIMAL" == "true" ]]; then
    log_info "Skipping playerctl/cava (--minimal)."
    return
  fi
  local extras
  extras="$(pkg_extra_tools)"
  if [[ "$OS_FAMILY" == "darwin" ]]; then
    log_warn "playerctl depends on Linux MPRIS/D-Bus and isn't available on macOS; skipping it."
  fi
  pkg_install "$extras"
}

install_system_deps() {
  if [[ "$SKIP_DEPS" == "true" ]]; then
    log_info "Skipping system dependency installation (--skip-deps)."
    return
  fi
  pkg_update_index
  pkg_install "$(pkg_build_tools)"
  install_backend
  install_extra_tools
}

# ---------------------------------------------------------------------------
# Build & wire up the beatfetch binary
# ---------------------------------------------------------------------------
build_and_install() {
  if [[ ! -d "$APP_DIR" ]]; then
    log_err "Source directory not found: $APP_DIR"
    exit 1
  fi
  if [[ ! -f "$APP_DIR/Makefile" ]]; then
    log_err "No Makefile found in $APP_DIR"
    exit 1
  fi

  if [[ -d "$APP_DIR/.git" ]] && have git; then
    log_info "Syncing latest source..."
    run git -C "$APP_DIR" pull --ff-only 2>/dev/null || log_warn "Could not fast-forward source repo, building what's on disk."
  fi

  log_info "Building beatfetch (make -j${JOBS})..."
  run make -C "$APP_DIR" -j"$JOBS"

  if [[ ! -x "$APP_DIR/beatfetch" ]]; then
    log_err "Build finished but $APP_DIR/beatfetch was not produced."
    exit 1
  fi

  local wrapper="$INSTALL_PREFIX/beatfetch"
  log_info "Installing launcher to $wrapper"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${DIM}[dry-run] write launcher to $wrapper (backend: $BACKEND)${RESET}"
    return
  fi
  mkdir -p "$INSTALL_PREFIX"
  cat > "$wrapper" <<WRAPPER
#!/usr/bin/env bash
exec "$APP_DIR/beatfetch" --fetch-backend "\${BEATFETCH_BACKEND_OVERRIDE:-$BACKEND}" "\$@"
WRAPPER
  chmod +x "$wrapper"
}

# ---------------------------------------------------------------------------
# Shell PATH wiring (bash, zsh, fish; login and interactive rc files)
# ---------------------------------------------------------------------------
PATH_MARKER="# Added by BeatFetch C++ installer"

rc_files_for_shell() {
  local shell_name
  shell_name="$(basename "${SHELL:-bash}")"
  case "$shell_name" in
    zsh)  echo "$HOME/.zshrc" ;;
    fish) echo "$HOME/.config/fish/config.fish" ;;
    *)
      if [[ "$OS_FAMILY" == "darwin" ]]; then
        echo "$HOME/.bash_profile $HOME/.bashrc"
      else
        echo "$HOME/.bashrc"
      fi
      ;;
  esac
}

update_shell_rc() {
  local shell_name line rc
  shell_name="$(basename "${SHELL:-bash}")"
  if [[ "$shell_name" == "fish" ]]; then
    line="fish_add_path $INSTALL_PREFIX"
  else
    line="export PATH=\"$INSTALL_PREFIX:\$PATH\""
  fi

  for rc in $(rc_files_for_shell); do
    if grep -Fq "$PATH_MARKER" "$rc" 2>/dev/null; then
      log_debug "$rc already configured."
      continue
    fi
    log_info "Updating PATH in $rc"
    if [[ "$DRY_RUN" == "true" ]]; then
      echo -e "${DIM}[dry-run] append PATH block to $rc${RESET}"
      continue
    fi
    mkdir -p "$(dirname "$rc")" 2>/dev/null || true
    { printf '\n%s\n%s\n' "$PATH_MARKER" "$line"; } >> "$rc" 2>/dev/null \
      || log_warn "Could not update $rc (check permissions)."
  done
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
self_test() {
  local bin="$INSTALL_PREFIX/beatfetch"
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Dry run: skipping self-test."
    return
  fi
  if PATH="$INSTALL_PREFIX:$PATH" "$bin" --version >/dev/null 2>&1 \
     || PATH="$INSTALL_PREFIX:$PATH" "$bin" --help >/dev/null 2>&1; then
    log_ok "beatfetch runs successfully."
  else
    log_warn "beatfetch was installed but a smoke test invocation didn't exit cleanly. Try running it manually."
  fi
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
uninstall() {
  confirm "Remove beatfetch from $INSTALL_PREFIX and clean up PATH entries?" || {
    log_info "Aborted."
    exit 0
  }
  log_info "Uninstalling beatfetch from $INSTALL_PREFIX"
  run rm -f "$INSTALL_PREFIX/beatfetch"

  local rc
  for rc in $(rc_files_for_shell); do
    [[ -f "$rc" ]] || continue
    if grep -Fq "$PATH_MARKER" "$rc" 2>/dev/null; then
      log_info "Removing PATH entry from $rc"
      if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${DIM}[dry-run] remove PATH block from $rc${RESET}"
      else
        # Drop the marker line plus the export/fish_add_path line right
        # after it. Plain awk keeps this portable across GNU/BSD/busybox.
        awk -v marker="$PATH_MARKER" '
          $0 == marker { skip = 2; next }
          skip > 0 { skip--; next }
          { print }
        ' "$rc" > "$rc.tmp" && mv "$rc.tmp" "$rc"
      fi
    fi
  done

  log_ok "beatfetch removed. System packages (backend, playerctl, cava) were left in place since other tools may use them."
  log_info "Remove them manually with your package manager if you no longer need them."
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary() {
  echo
  log_ok "Installation complete."
  echo -e "${BOLD}Run:${RESET} beatfetch"
  echo -e "${DIM}If your shell is already open, run: source ~/.bashrc (or open a new terminal)${RESET}"
  echo -e "${DIM}Log file: $LOG_FILE${RESET}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  detect_os
  detect_arch

  if [[ "$DO_UNINSTALL" == "true" ]]; then
    uninstall
    exit 0
  fi

  ui_banner
  choose_backend
  install_system_deps
  build_and_install
  update_shell_rc
  self_test
  print_summary
}

main "$@"
