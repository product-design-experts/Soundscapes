#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SYSTEMD_DIR="/etc/systemd/system"

UNITS=(
  "audiostream.service"
  "audiostream-camilladsp.service"
  "audiostream-whip.service"
  "audiostream-ivs-token-refresh.service"
  "audiostream-ivs-token-refresh.timer"
)

usage() {
  cat <<'USAGE'
Usage:
  ./manage_systemd.sh install
  ./manage_systemd.sh uninstall
  ./manage_systemd.sh status
  ./manage_systemd.sh start
  ./manage_systemd.sh stop
  ./manage_systemd.sh restart

Installs/uninstalls and manages system-level systemd units for the AudioStream stack.
USAGE
}

need_sudo() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      SUDO=(sudo)
    else
      echo "ERROR: must be root (sudo not found)." >&2
      exit 1
    fi
  else
    SUDO=()
  fi
}

verify_sources_exist() {
  local missing=0
  for unit in "${UNITS[@]}"; do
    if [[ ! -f "$SCRIPT_DIR/$unit" ]]; then
      echo "ERROR: missing unit file: $SCRIPT_DIR/$unit" >&2
      missing=1
    fi
  done
  if [[ "$missing" -ne 0 ]]; then
    exit 1
  fi
}

unit_debug() {
  local unit="$1"
  echo
  echo "===== DEBUG: $unit =====" >&2
  "${SUDO[@]}" systemctl --no-pager --full status "$unit" >&2 || true
  echo "----- journalctl -u $unit (last 200) -----" >&2
  "${SUDO[@]}" journalctl -u "$unit" --no-pager -n 200 >&2 || true
}

start_or_debug() {
  local unit="$1"
  if ! "${SUDO[@]}" systemctl start "$unit"; then
    echo "ERROR: failed to start $unit" >&2
    unit_debug "$unit"
    return 1
  fi
  return 0
}

start_stack() {
  need_sudo

  echo "Starting services + timer..."
  # Start in dependency order; if a later unit fails, keep earlier ones running.
  start_or_debug audiostream-ivs-token-refresh.timer || true
  start_or_debug audiostream-camilladsp.service
  start_or_debug audiostream-whip.service
  start_or_debug audiostream.service || true

  echo "Done."
}

stop_stack() {
  need_sudo

  echo "Stopping services + timer (if present)..."
  "${SUDO[@]}" systemctl stop audiostream.service 2>/dev/null || true
  "${SUDO[@]}" systemctl stop audiostream-whip.service 2>/dev/null || true
  "${SUDO[@]}" systemctl stop audiostream-camilladsp.service 2>/dev/null || true
  "${SUDO[@]}" systemctl stop audiostream-ivs-token-refresh.timer 2>/dev/null || true
  "${SUDO[@]}" systemctl stop audiostream-ivs-token-refresh.service 2>/dev/null || true

  echo "Done."
}

restart_stack() {
  stop_stack
  start_stack
}

install_units() {
  need_sudo
  verify_sources_exist

  echo "Installing units into $SYSTEMD_DIR ..."
  "${SUDO[@]}" mkdir -p "$SYSTEMD_DIR"

  for unit in "${UNITS[@]}"; do
    "${SUDO[@]}" install -m 0644 "$SCRIPT_DIR/$unit" "$SYSTEMD_DIR/$unit"
  done

  echo "Reloading systemd..."
  "${SUDO[@]}" systemctl daemon-reload

  echo "Clearing any latched unit failures (reset-failed)..."
  # One-shot units can remain in a failed state long after the underlying
  # issue has been fixed, which makes summaries noisy and can confuse installs.
  # Clearing failures is safe; it does not start/stop any units.
  "${SUDO[@]}" systemctl reset-failed "${UNITS[@]}" 2>/dev/null || true

  echo "Enabling services + timer..."
  "${SUDO[@]}" systemctl enable \
    audiostream.service \
    audiostream-camilladsp.service \
    audiostream-whip.service \
    audiostream-ivs-token-refresh.timer

  start_stack

  echo
  echo "Status summary:"
  for unit in "${UNITS[@]}"; do
    # The token refresh service is timer-driven; it is expected to be disabled.
    # Report the timer enablement instead to avoid false alarms.
    if [[ "$unit" == "audiostream-ivs-token-refresh.service" ]]; then
      printf "  %-38s enabled(timer)=%-10s active=%s\n" \
        "$unit" \
        "$("${SUDO[@]}" systemctl is-enabled audiostream-ivs-token-refresh.timer 2>/dev/null || echo no)" \
        "$("${SUDO[@]}" systemctl is-active "$unit" 2>/dev/null || echo inactive)"
      continue
    fi

    printf "  %-38s enabled=%-10s active=%s\n" \
      "$unit" \
      "$("${SUDO[@]}" systemctl is-enabled "$unit" 2>/dev/null || echo no)" \
      "$("${SUDO[@]}" systemctl is-active "$unit" 2>/dev/null || echo inactive)"
  done

  echo "Done. Useful commands:"
  echo "  systemctl status audiostream.service"
  echo "  journalctl -u audiostream-camilladsp.service -f"
  echo "  journalctl -u audiostream-whip.service -f"
}

uninstall_units() {
  need_sudo

  stop_stack

  echo "Disabling services + timer (if present)..."
  "${SUDO[@]}" systemctl disable audiostream.service 2>/dev/null || true
  "${SUDO[@]}" systemctl disable audiostream-whip.service 2>/dev/null || true
  "${SUDO[@]}" systemctl disable audiostream-camilladsp.service 2>/dev/null || true
  "${SUDO[@]}" systemctl disable audiostream-ivs-token-refresh.timer 2>/dev/null || true
  "${SUDO[@]}" systemctl disable audiostream-ivs-token-refresh.service 2>/dev/null || true

  echo "Removing unit files from $SYSTEMD_DIR (if present)..."
  for unit in "${UNITS[@]}"; do
    "${SUDO[@]}" rm -f "$SYSTEMD_DIR/$unit"
  done

  echo "Reloading systemd..."
  "${SUDO[@]}" systemctl daemon-reload

  echo "Done."
}

show_status() {
  # `systemctl status` does not require root, but some systems restrict details.
  # Use sudo if available so output is consistent.
  need_sudo

  echo "Units in $SYSTEMD_DIR:"
  for unit in "${UNITS[@]}"; do
    local path="$SYSTEMD_DIR/$unit"
    if [[ -f "$path" ]]; then
      echo "  present: $unit"
    else
      echo "  missing: $unit"
    fi
  done

  echo
  for unit in "${UNITS[@]}"; do
    echo "===== $unit ====="
    "${SUDO[@]}" systemctl is-enabled "$unit" 2>/dev/null || true
    "${SUDO[@]}" systemctl is-active "$unit" 2>/dev/null || true
    "${SUDO[@]}" systemctl --no-pager --full status "$unit" 2>/dev/null || true
    echo
  done
}

main() {
  if [[ $# -ne 1 ]]; then
    usage
    exit 2
  fi

  case "$1" in
    install)
      install_units
      ;;
    uninstall)
      uninstall_units
      ;;
    status)
      show_status
      ;;
    start)
      start_stack
      ;;
    stop)
      stop_stack
      ;;
    restart)
      restart_stack
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      echo "ERROR: unknown command: $1" >&2
      usage
      exit 2
      ;;
  esac
}

main "$@"
