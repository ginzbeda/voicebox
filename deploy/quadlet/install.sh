#!/usr/bin/env bash
# Manage the Voicebox Quadlet deployment: install the units into
# ~/.config/containers/systemd/ and start/stop the systemd-managed stack.
#
# Mirrors torrent-service/quadlet/install.sh, minus the templating — Voicebox's
# units carry no per-host values, so they are copied verbatim rather than rendered
# through envsubst from a .env.
#
#   ./deploy/quadlet/install.sh              install/refresh the units (default)
#   ./deploy/quadlet/install.sh start        install, then start and wait for health
#   ./deploy/quadlet/install.sh stop         stop the units (volumes survive)
#   ./deploy/quadlet/install.sh restart      stop, then start
#   ./deploy/quadlet/install.sh status       unit states + pod/container + health
#   ./deploy/quadlet/install.sh logs [-f]    journal for the container unit
#   ./deploy/quadlet/install.sh active       exit 0 if any unit is active
#   ./deploy/quadlet/install.sh installed    exit 0 if the units are installed here
#   ./deploy/quadlet/install.sh uninstall    stop, disable, and remove the units
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd"
HEALTH_URL="${VOICEBOX_HEALTH_URL:-http://127.0.0.1:17600/health}"
HEALTH_TIMEOUT="${VOICEBOX_HEALTH_TIMEOUT:-180}"

# Ordered shallowest-first: network, then pod, then the container that joins it.
# Stops walk this list in reverse.
SERVICES='voicebox-network voicebox-pod voicebox'

usage() {
  echo "usage: $0 [install|start|stop|restart|status|logs|active|installed|uninstall]" >&2
  exit 1
}

units() { find "$HERE" -maxdepth 1 -name 'voicebox.*' ! -name '*.md' -printf '%f\n' | sort; }

unit_active() { systemctl --user is-active --quiet "$1" 2>/dev/null; }

# This stack is ROOTLESS: the units live under the USER systemd manager and the
# images/volumes in USER podman storage. Under sudo, `systemctl --user` talks to
# root's manager and podman sees empty storage, so commands silently half-work.
drop_sudo() {
  [ "$(id -u)" -eq 0 ] || return 0
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    echo "==> running as root — re-executing as $SUDO_USER (this stack is rootless)..."
    exec sudo -u "$SUDO_USER" -H \
      env XDG_RUNTIME_DIR="/run/user/$(id -u "$SUDO_USER")" "$0" "$@"
  fi
  echo "!! this stack is rootless — run as your normal user, not root." >&2
  exit 1
}

cmd_active() {
  command -v systemctl >/dev/null 2>&1 || return 1
  local u
  for u in $SERVICES; do unit_active "$u.service" && return 0; done
  return 1
}

cmd_installed() {
  command -v systemctl >/dev/null 2>&1 || return 1
  [ -f "$DEST/voicebox.pod" ]
}

cmd_install() {
  mkdir -p "$DEST"
  local f
  for f in $(units); do
    install -m 0644 "$HERE/$f" "$DEST/$f"
  done
  systemctl --user daemon-reload
  echo "==> installed $(units | wc -l) units into $DEST"
}

# Poll the HTTP endpoint rather than trusting `is-active`. The unit reports active
# as soon as podman forks, so a container that dies during startup — an unreadable
# model cache, a bad image — still reads "active" for a while. Health is the only
# signal that says the server is actually serving.
wait_healthy() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if curl -fsS -m 5 "$HEALTH_URL" >/dev/null 2>&1; then
      echo "==> healthy: $HEALTH_URL"
      return 0
    fi
    # Bail out early if the unit gave up; no point waiting the full timeout.
    if ! unit_active voicebox.service; then
      echo "!! voicebox.service is no longer active — startup failed" >&2
      echo "   see: $0 logs" >&2
      return 1
    fi
    sleep 3
  done
  echo "!! not healthy after ${HEALTH_TIMEOUT}s: $HEALTH_URL" >&2
  echo "   see: $0 logs" >&2
  return 1
}

cmd_start() {
  cmd_install
  echo "==> starting voicebox..."
  # A previous crash leaves units "failed", which blocks a clean start.
  # shellcheck disable=SC2086
  systemctl --user reset-failed $SERVICES 2>/dev/null || true
  # Start only the container unit: quadlet generates the Requires=/After= that pull
  # the pod and network up in order. Starting all three by hand races that.
  systemctl --user start voicebox.service
  wait_healthy || return 1
  echo
  echo "auto-start on boot needs lingering:  loginctl enable-linger $USER"
}

cmd_stop() {
  echo "==> stopping voicebox..."
  # Reverse order, and NEVER `systemctl --user restart`. The pod is created with
  # exit-policy=stop, so when the container exits the pod tears itself down — a
  # plain restart then races its own dependency and lands in "failed" with
  # "A dependency job for voicebox.service failed". Stop then start is the only
  # sequence that works, which is why cmd_restart is not a one-liner.
  local rev='voicebox voicebox-pod voicebox-network'
  # shellcheck disable=SC2086
  systemctl --user stop $rev 2>/dev/null || true
  # shellcheck disable=SC2086
  systemctl --user reset-failed $SERVICES 2>/dev/null || true
  echo "==> done. restart with: $0 start"
}

cmd_status() {
  local s
  for s in $SERVICES; do
    printf '  %-18s %s\n' "$s" "$(systemctl --user is-active "$s" 2>/dev/null || true)"
  done
  podman pod ps --filter name=voicebox \
    --format '  pod {{.Name}}  {{.Status}}  ({{.NumberOfContainers}} ctrs)' 2>/dev/null || true
  podman ps --filter name=voicebox \
    --format '  {{.Names}}  {{.Status}}  {{.Ports}}' 2>/dev/null || true
  local health
  if health="$(curl -fsS -m 5 "$HEALTH_URL" 2>/dev/null)"; then
    printf '  %-18s %s\n' health "$health"
  else
    printf '  %-18s %s\n' health "unreachable ($HEALTH_URL)"
  fi
}

cmd_logs() { journalctl --user -u voicebox.service "$@"; }

cmd_uninstall() {
  # Stop and forget the units FIRST — removing the files alone would leave the
  # containers running with no supervisor able to stop them.
  # shellcheck disable=SC2086
  systemctl --user disable --now $SERVICES 2>/dev/null || true
  local f
  for f in $(units); do rm -f "$DEST/$f"; done
  systemctl --user daemon-reload
  echo "stopped, disabled, and removed units from $DEST"
  echo "note: volumes (models, profiles, database) were NOT touched."
}

main() {
  drop_sudo "$@"
  local cmd="${1:-install}"
  [ $# -gt 0 ] && shift
  case "$cmd" in
    install)               cmd_install; echo; echo "units installed. start with:  $0 start" ;;
    start)                 cmd_start ;;
    stop)                  cmd_stop ;;
    restart)               cmd_stop; cmd_start ;;
    status)                cmd_status ;;
    logs)                  cmd_logs "$@" ;;
    active)                cmd_active ;;
    installed)             cmd_installed ;;
    uninstall|--uninstall) cmd_uninstall ;;
    -h|--help|help)        usage ;;
    *)                     echo "unknown command: $cmd" >&2; usage ;;
  esac
}

main "$@"
