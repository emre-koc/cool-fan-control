#!/bin/bash
# Cool Fan Control — root hardware validation (Milestone 0)
# Usage:
#   sudo scripts/hardware-test.sh read                # dump fans + temps + battery keys
#   sudo scripts/hardware-test.sh read TC0P TG0P      # specific keys
#   sudo scripts/hardware-test.sh write <rpm>         # manual mode at clamped rpm; auto-restored on exit
#   sudo scripts/hardware-test.sh restore             # back to Apple automatic control
#
# Safety: F0Tg is clamped to [F0Mn, F0Mx], and a trap ALWAYS restores F0Md=0 (auto)
# on exit — even on error or Ctrl-C.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$(mktemp -d)"
BIN="$BIN_DIR/smc_probe"
cc -O2 -o "$BIN" "$DIR/smc_probe.c" -framework IOKit -framework CoreFoundation

fan_val() { "$BIN" read "$1" | awk '{print $NF}'; }

restore_auto() { "$BIN" writeui8 F0Md 0 >/dev/null 2>&1 || true; }

case "${1:-read}" in
  read)
    shift || true
    if (( $# == 0 )); then
      "$BIN" read
    else
      "$BIN" read "$@"
    fi
    ;;
  write)
    rpm="${2:-}"
    [[ "$rpm" =~ ^[0-9]+$ ]] || { echo "usage: write <rpm>"; exit 1; }
    mn="$(fan_val F0Mn)"; mx="$(fan_val F0Mx)"
    [[ "$mn" =~ ^[0-9]+$ && "$mx" =~ ^[0-9]+$ ]] || { echo "could not read fan limits (fanless Mac?)"; exit 1; }
    trap restore_auto EXIT INT TERM
    (( rpm > mx )) && rpm=$mx
    (( rpm < mn )) && rpm=$mn
    echo "F0Mn=$mn F0Mx=$mx -> F0Tg=$rpm (manual mode, auto-restored on exit)"
    "$BIN" writeui8 F0Md 1
    "$BIN" writerpm F0Tg "$rpm"
    sleep 3
    echo "actual:"; "$BIN" read F0Ac F0Md
    ;;
  restore)
    restore_auto
    echo "auto restored:"; "$BIN" read F0Md F0Ac
    ;;
  *)
    echo "usage: $0 read|write <rpm>|restore"; exit 2 ;;
esac
