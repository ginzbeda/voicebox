#!/usr/bin/env bash
# Control Voicebox speech for Claude Code. Backs the /say slash command.
#
#   voicectl.sh on | off | status | stop | list | test
#   voicectl.sh profile <name>
#   voicectl.sh <text to speak>
#
# The logic lives here rather than in the slash command's markdown because a
# slash command is a prompt: if the curl invocations live in prose, the model
# re-derives them every time and eventually gets one wrong. This is a fixed,
# testable surface it can only call.
#
# Note this controls Voicebox *output*. Claude Code's built-in /voice is the
# separate, unrelated command for speech *input*.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./voicebox-common.sh
. "$HERE/voicebox-common.sh"

usage() {
    cat <<'EOF'
usage: /say <subcommand>

  on              speak responses again
  off             stop speaking, and silence anything playing now
  status          toggle state, backend health, and the current voice
  stop            silence what is playing, leave speaking enabled
  list            available voice profiles
  profile <name>  bind this client to a voice
  test            end-to-end check
  <text>          speak this text now
EOF
}

require_jq() {
    command -v jq >/dev/null 2>&1 || { echo "jq is required"; exit 1; }
}

api() {
    # $1 method, $2 path, $3 optional body
    local method="$1" path="$2" body="${3:-}"
    if [ -n "$body" ]; then
        curl -s --connect-timeout 2 -m 10 -X "$method" "$VB_BASE$path" \
            -H 'Content-Type: application/json' \
            -H "X-Voicebox-Client-Id: $VB_CLIENT_ID" --data "$body"
    else
        curl -s --connect-timeout 2 -m 10 -X "$method" "$VB_BASE$path" \
            -H "X-Voicebox-Client-Id: $VB_CLIENT_ID"
    fi
}

stop_playback() {
    # The play script is detached, so signal it rather than tracking a pid.
    pkill -f "voicebox-play.sh" >/dev/null 2>&1 || true
    for p in paplay pw-play aplay afplay ffplay play; do
        pkill -x "$p" >/dev/null 2>&1 || true
    done
    rmdir "$VB_STATE/play.lock" 2>/dev/null || true
}

speak_now() {
    local text="$1" gid
    vb_breaker_reset          # explicit intent: retry even if the breaker is armed
    gid=$(vb_speak "$text")
    if [ -z "$gid" ]; then
        echo "Voicebox is not reachable at $VB_BASE"
        return 1
    fi
    setsid "$HERE/voicebox-play.sh" "$gid" >/dev/null 2>&1 < /dev/null &
    echo "Speaking as $VB_CLIENT_ID (generation $gid)"
}

cmd=${1:-status}
shift || true

vb_init_state
require_jq

case "$cmd" in
  on)
    echo 0 > /dev/null  # keep shellcheck happy about the branch shape
    rm -f "$VB_STATE/enabled"
    vb_breaker_reset
    echo "Speaking enabled."
    ;;

  off)
    echo 0 > "$VB_STATE/enabled"
    # The toggle alone only suppresses *future* speech; kill what is mid-sentence.
    stop_playback
    echo "Speaking disabled, and current playback stopped."
    ;;

  stop)
    stop_playback
    echo "Playback stopped. Speaking is still enabled."
    ;;

  status)
    if vb_enabled; then echo "speaking:  on"; else echo "speaking:  off"; fi
    if vb_breaker_open; then
        echo "backend:   marked down until $(cat "$VB_STATE/down-until" 2>/dev/null)"
    fi
    health=$(curl -s --connect-timeout 1 -m 3 "$VB_BASE/health" 2>/dev/null)
    if [ -n "$health" ]; then
        echo "backend:   up at $VB_BASE ($(printf '%s' "$health" | jq -r '.gpu_type // "cpu"'))"
    else
        echo "backend:   UNREACHABLE at $VB_BASE"
    fi
    binding=$(api GET /mcp/bindings | jq -r --arg c "$VB_CLIENT_ID" \
        '.items[]? | select(.client_id==$c) | "\(.profile_id // "none")\t\(.default_engine // "default")"' 2>/dev/null)
    if [ -n "$binding" ]; then
        pid=$(printf '%s' "$binding" | cut -f1)
        name=$(api GET /profiles | jq -r --arg id "$pid" '.[]? | select(.id==$id) | .name' 2>/dev/null)
        echo "client:    $VB_CLIENT_ID"
        echo "voice:     ${name:-unset} (engine $(printf '%s' "$binding" | cut -f2))"
    else
        echo "client:    $VB_CLIENT_ID (no binding — using the global default voice)"
    fi
    player=$(for c in paplay pw-play aplay afplay ffplay play; do
                 command -v "$c" >/dev/null 2>&1 && { echo "$c"; break; }
             done)
    # Being on $PATH proves nothing. Under WSL without WSLg, ffplay and sox are
    # both installed and both fail at runtime, so reporting "player: ffplay"
    # here would promise audio that never arrives.
    if [ -z "$player" ]; then
        echo "player:    NONE installed — run scripts/check-wsl-audio.sh"
    elif [ -z "${PULSE_SERVER:-}" ] && [ ! -S /mnt/wslg/PulseServer ] \
         && ! ls /dev/snd/pcm* >/dev/null 2>&1; then
        echo "player:    $player, but NO AUDIO DEVICE — run scripts/check-wsl-audio.sh"
    else
        echo "player:    $player"
    fi
    ;;

  list)
    profiles=$(api GET /profiles)
    [ -n "$profiles" ] || { echo "Voicebox is not reachable at $VB_BASE"; exit 1; }
    printf '%s' "$profiles" | jq -r '.[] | "\(.name)\t\(.voice_type)\t\(.default_engine // "-")"' \
        | column -t -s $'\t' 2>/dev/null || printf '%s' "$profiles" | jq -r '.[].name'
    ;;

  profile)
    want="${1:-}"
    [ -n "$want" ] || { echo "usage: /say profile <name>"; exit 2; }

    profiles=$(api GET /profiles)
    [ -n "$profiles" ] || { echo "Voicebox is not reachable at $VB_BASE"; exit 1; }

    matches=$(printf '%s' "$profiles" | jq -r --arg n "$want" \
        '[.[] | select((.name | ascii_downcase) == ($n | ascii_downcase))] | .[].id')
    count=$(printf '%s' "$matches" | grep -c . || true)
    if [ "$count" = 0 ]; then
        echo "No profile named '$want'. Available:"
        printf '%s' "$profiles" | jq -r '.[] | "  " + .name'
        exit 1
    fi
    if [ "$count" -gt 1 ]; then
        echo "'$want' is ambiguous — $count profiles share that name; use an id."
        exit 1
    fi
    pid=$(printf '%s' "$matches" | head -1)

    # PUT /mcp/bindings is a full replace: it assigns label, profile_id,
    # default_engine and default_personality unconditionally from the body.
    # Read the existing row first and merge, or setting a voice silently wipes
    # this client's engine and personality settings.
    existing=$(api GET /mcp/bindings | jq -c --arg c "$VB_CLIENT_ID" \
        '.items[]? | select(.client_id==$c)' 2>/dev/null)
    body=$(jq -nc \
        --arg client_id "$VB_CLIENT_ID" \
        --arg profile_id "$pid" \
        --argjson existing "${existing:-null}" '
        {
          client_id: $client_id,
          profile_id: $profile_id,
          label: ($existing.label // null),
          default_engine: ($existing.default_engine // null),
          default_personality: ($existing.default_personality // false)
        }')
    result=$(api PUT /mcp/bindings "$body")
    if printf '%s' "$result" | jq -e '.client_id' >/dev/null 2>&1; then
        echo "$VB_CLIENT_ID will now speak as '$want'."
    else
        echo "Failed to set the voice: ${result:-no response from $VB_BASE}"
        exit 1
    fi
    ;;

  test)
    started=$(vb_now)
    speak_now "Voicebox is connected to Claude Code." || exit 1
    echo "If you hear nothing within a few seconds, run scripts/check-wsl-audio.sh"
    echo "(request round-trip $(( $(vb_now) - started ))s)"
    ;;

  -h|--help|help)
    usage
    ;;

  *)
    # Anything else is text to speak. Explicit intent, so it ignores the toggle.
    text="$cmd $*"
    text=$(printf '%s\n' "$text" | vb_clean_text)
    [ -n "${text//[[:space:]]/}" ] || { usage; exit 2; }
    speak_now "$text" || exit 1
    ;;
esac
