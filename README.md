# BeatFetch C++

BeatFetch is a Linux terminal dashboard that combines fetch system information,
MPRIS now-playing details, and a live audio spectrum from Cava.

## Requirements

- C++17 compiler and `make`
- One fetch backend: `fastfetch`, `hyfetch`, or `neofetch`
- `playerctl` and `cava` (optional dashboard panels)

## Install

From this directory, run:

```bash
./install-cpp-beatfetch.sh
```

The installer installs the executable under `~/.local/lib/beatfetch` and the
launcher under `~/.local/bin`. If needed, add `~/.local/bin` to your `PATH` or
reload `~/.bashrc`.

## Build manually

```bash
make -C Beatfetch_C/beatfetch-cpp-latest
Beatfetch_C/beatfetch-cpp-latest/beatfetch --help
```

Use `./uninstall-beatfetch.sh` to remove the installed executable, launcher,
and PATH block added by the installer. It does not remove source files or
system packages.
