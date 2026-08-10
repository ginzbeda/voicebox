#!/usr/bin/env bash
# Play a Voicebox generation on this machine's speakers.
#
#   voicebox-play.sh <generation-id>
#
# Voicebox generates audio server-side but never plays it — playback belongs to
# whoever asked. The desktop app does this in Rust (tauri speak_monitor.rs); for
# a headless backend, or one in a container, nothing does, and agent speech is
# written to disk and silently discarded. This is the missing half.
#
# Poll the generation to completion, fetch the WAV, hand it to a real player.
# Runs detached from the hook that spawned it so a turn never waits on TTS.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./voicebox-common.sh
. "$HERE/voicebox-common.sh"

GID="${1:-}"
[ -n "$GID" ] || { echo "usage: voicebox-play.sh <generation-id>" >&2; exit 2; }

POLL_TIMEOUT="${VOICEBOX_POLL_TIMEOUT:-180}"
LOCK="$VB_STATE/play.lock"

vb_init_state

# ─── Player selection ──────────────────────────────────────────────────────
#
# Order matters and $PATH is not enough to decide. Under WSL without WSLg both
# ffplay and sox are installed and both fail at runtime ("ALSA: Couldn't open
# audio device"), so presence proves nothing — see scripts/check-wsl-audio.sh.
# paplay is listed first because a working PulseAudio socket is the normal way
# a Linux or WSLg box has sound at all.
vb_player_cmd() {
    if [ -n "${VOICEBOX_PLAYER:-}" ]; then
        printf '%s' "$VOICEBOX_PLAYER"
        return 0
    fi
    for candidate in "paplay" "pw-play" "aplay -q" "afplay" "ffplay -nodisp -autoexit -loglevel error" "play -q"; do
        if command -v "${candidate%% *}" >/dev/null 2>&1; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

# ─── Wait for the generation ───────────────────────────────────────────────
#
# GET /generate/{id}/status is SSE, and unlike /events/speak it emits bare
# `data:` frames with no `event:` line — parse on the data prefix alone. The
# stream closes once the generation settles, so this returns promptly rather
# than polling on a timer.
wait_for_generation() {
    local status
    status=$(timeout "$POLL_TIMEOUT" curl -sN --connect-timeout 2 \
                "$VB_BASE/generate/$GID/status" 2>/dev/null \
             | sed -n 's/^data: //p' \
             | grep -oE '"status"[[:space:]]*:[[:space:]]*"[a-z]+"' \
             | grep -oE '"[a-z]+"$' | tr -d '"' \
             | grep -vx generating | head -1)
    printf '%s' "${status:-timeout}"
}

status=$(wait_for_generation)
if [ "$status" != "completed" ]; then
    # failed / cancelled / timeout — nothing to play, and not worth a retry.
    exit 0
fi

# ─── Fetch and play ────────────────────────────────────────────────────────

tmp=$(mktemp -t "voicebox-$GID-XXXXXX.wav") || exit 0
cleanup() { rm -f "$tmp"; rmdir "$LOCK" 2>/dev/null || true; }
trap cleanup EXIT

# Note: /audio/{id} allows GET only — a HEAD probe returns 405.
code=$(curl -s --connect-timeout 2 -m 60 -o "$tmp" -w '%{http_code}' \
        "$VB_BASE/audio/$GID" 2>/dev/null)
[ "$code" = "200" ] && [ -s "$tmp" ] || exit 0

player=$(vb_player_cmd) || {
    echo "voicebox-play: no audio player available; run scripts/check-wsl-audio.sh" >&2
    exit 0
}

# Serialise playback. Two hooks firing close together would otherwise talk over
# each other, which is worse than being a second late. mkdir is the atomic
# primitive that exists everywhere, unlike flock.
for _ in $(seq 1 "${VOICEBOX_LOCK_WAIT:-120}"); do
    mkdir "$LOCK" 2>/dev/null && break
    # A lock left by a killed player would block every future utterance.
    if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +5 2>/dev/null)" ]; then
        rmdir "$LOCK" 2>/dev/null || true
    fi
    sleep 1
done

# shellcheck disable=SC2086 # player is an intentional argv template
err=$($player "$tmp" 2>&1)
rc=$?
# Exit codes lie here: ffplay returns 0 even when it cannot open the output
# device. Treat a device-open complaint on stderr as authoritative.
if [ "$rc" != 0 ] || printf '%s' "$err" | grep -qiE "couldn't open|could not open|cannot open|no such (audio )?device|no default|audio open failed"; then
    echo "voicebox-play: ${player%% *} failed: $(printf '%s' "$err" | tail -1)" >&2
fi
exit 0
