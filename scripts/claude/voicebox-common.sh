#!/usr/bin/env bash
# Shared helpers for the Claude Code ↔ Voicebox hooks. Sourced, never executed.
#
# Everything here runs on the hook path, which fires on every turn of every
# session, so the rules are: no unbounded waits, no network call that can hang a
# turn, and never a non-zero exit that could wedge Claude.

# Where the toggle and breaker live. Not in the repo — this is per-user state.
VB_STATE="${VOICEBOX_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/voicebox}"

# Host and port are separate knobs so they match .mcp.json, which reads the same
# two variables. 17493 is the project default (package.json, mcp_shim's
# DEFAULT_PORT, Rust SERVER_PORT); a container or port-forward sets
# VOICEBOX_PORT. Never default to a deployment-specific port here — a stock
# desktop install would then point every hook at a dead socket, trip the circuit
# breaker on the first turn, and go quiet with no obvious cause.
VB_HOST="${VOICEBOX_HOST:-127.0.0.1}"
VB_PORT="${VOICEBOX_PORT:-17493}"
# VOICEBOX_URL still wins, for anything behind a path prefix or TLS.
VB_BASE="${VOICEBOX_URL:-http://${VB_HOST}:${VB_PORT}}"
VB_CLIENT_ID="${VOICEBOX_CLIENT_ID:-claude-code}"

# How long the breaker suppresses calls after a failure.
VB_BREAKER_SECONDS="${VOICEBOX_BREAKER_SECONDS:-60}"

vb_init_state() {
    mkdir -p "$VB_STATE" 2>/dev/null || true
}

# Speaking is opt-out: absent file means on, so a fresh install just works.
vb_enabled() {
    [ "$(cat "$VB_STATE/enabled" 2>/dev/null)" != "0" ]
}

vb_now() { date +%s; }

# The breaker is the difference between "Voicebox is down" costing 2ms a turn
# and costing a multi-second curl timeout on every turn. Without it, a stopped
# container makes every single response feel broken.
vb_breaker_open() {
    local until
    until=$(cat "$VB_STATE/down-until" 2>/dev/null) || return 1
    [ -n "$until" ] || return 1
    [ "$(vb_now)" -lt "$until" ] 2>/dev/null
}

vb_breaker_trip() {
    vb_init_state
    echo $(( $(vb_now) + VB_BREAKER_SECONDS )) > "$VB_STATE/down-until" 2>/dev/null || true
}

vb_breaker_reset() {
    rm -f "$VB_STATE/down-until" 2>/dev/null || true
}

# Strip markdown so TTS doesn't read punctuation soup, and drop code blocks
# entirely — a fenced diff read aloud is unusable and can run for minutes.
#
# An unterminated fence drops everything after it. That is deliberate: the
# alternative is reading a truncated code block aloud, and a reply whose fence
# never closes has nothing useful left to say anyway.
vb_clean_text() {
    sed -e '/^[[:space:]]*```/,/^[[:space:]]*```/d' \
        -e 's/!\[[^]]*\]([^)]*)//g' \
        -e 's/\[\([^]]*\)\]([^)]*)/\1/g' \
        -e 's|https\?://[^[:space:]]*||g' \
        -e 's/[`*_#>|]//g' \
        | tr '\n' ' ' | tr -s ' ' \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# Speak the text in $1 as this client. Echoes the generation id on success.
# Honours the breaker, and trips it when the backend is unreachable.
vb_speak() {
    local text="$1" body response
    [ -n "${text//[[:space:]]/}" ] || return 1
    vb_breaker_open && return 1

    body=$(jq -nc --arg t "$text" '{text:$t}') || return 1
    # POST /speak returns as soon as the row exists, so this never waits on TTS.
    # Judge health by status code, not by whether a body came back: an error
    # response is still a body, and treating it as success would reset the
    # breaker and pay a full round trip on every turn forever — the exact cost
    # the breaker exists to avoid. A 400 "No voice profile resolved" is the
    # common case here.
    response=$(curl -s --connect-timeout 1 -m 5 -w '\n%{http_code}' -X POST "$VB_BASE/speak" \
        -H 'Content-Type: application/json' \
        -H "X-Voicebox-Client-Id: $VB_CLIENT_ID" \
        --data "$body" 2>/dev/null)

    code=$(printf '%s' "$response" | tail -1)
    payload=$(printf '%s' "$response" | sed '$d')

    # No response at all, or a server-side fault: the backend is unusable, so
    # stop calling it for a while.
    if [ -z "$code" ] || [ "$code" = "000" ] || [ "$code" -ge 500 ] 2>/dev/null; then
        vb_breaker_trip
        return 1
    fi
    # A 4xx means the backend is alive but this request was wrong (no profile
    # bound, bad text). Do not trip the breaker — retrying later is pointless
    # but so is marking a healthy server down — just decline to speak.
    if [ "$code" -ge 400 ] 2>/dev/null; then
        return 1
    fi
    vb_breaker_reset
    printf '%s' "$payload" | jq -r '.id // empty' 2>/dev/null
}

# Rate-limit by name: true when the last event tagged $1 was over $2 seconds ago.
vb_rate_ok() {
    local name="$1" window="$2" stamp last
    stamp="$VB_STATE/rate-$name"
    last=$(cat "$stamp" 2>/dev/null || echo 0)
    [ $(( $(vb_now) - last )) -ge "$window" ] || return 1
    vb_init_state
    vb_now > "$stamp" 2>/dev/null || true
}
