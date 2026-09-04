#!/usr/bin/env bash
# Single entrypoint for running Voicebox on this machine. Thin dispatcher — the
# real implementation lives in deploy/quadlet/install.sh, so there is no logic
# duplicated here.
#
# Same shape as torrent-service.sh: up/down/restart/status are the everyday verbs,
# and `quadlet` drops through to the underlying script for anything finer.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUADLET="$SCRIPT_DIR/deploy/quadlet/install.sh"

usage() {
  cat <<'EOF'
usage: ./voicebox.sh <command> [args]

Stack lifecycle (systemd + Quadlet, rootless):
  up                 install the units, start the stack, wait for /health
  down               stop the stack (models, profiles and database survive)
  restart            down, then up
  status             unit states, pod/container, and the health endpoint
  logs [-f]          journal for the container unit

Advanced (see deploy/quadlet/README.md):
  quadlet <action>   install|start|stop|restart|status|logs|active|installed|uninstall

Notes:
  * `restart` is deliberately down-then-up. The pod uses exit-policy=stop, so a
    plain `systemctl --user restart voicebox.service` races its own dependency
    and fails — do not "simplify" it back.
  * The web UI and MCP endpoint are on http://127.0.0.1:17600 (loopback only;
    the API has no authentication).

  ./voicebox.sh up
  ./voicebox.sh status
  ./voicebox.sh logs -f
EOF
}

main() {
  local cmd="${1:-}"
  [ $# -gt 0 ] && shift

  case "$cmd" in
    up)      exec "$QUADLET" start "$@" ;;
    down)    exec "$QUADLET" stop "$@" ;;
    restart) exec "$QUADLET" restart "$@" ;;
    status)  exec "$QUADLET" status "$@" ;;
    logs)    exec "$QUADLET" logs "$@" ;;
    quadlet) exec "$QUADLET" "$@" ;;
    -h|--help|help|"")
      usage
      [ -z "$cmd" ] && exit 1
      exit 0
      ;;
    *)
      echo "unknown command: $cmd" >&2
      usage >&2
      exit 1
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
