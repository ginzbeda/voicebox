#!/usr/bin/env bash
# Shared helpers for the Claude Code ↔ Voicebox hooks. Sourced, never executed.
#
# Everything here runs on the hook path, which fires on every turn of every
# session, so the rules are: no unbounded waits, no network call that can hang a
# turn, and never a non-zero exit that could wedge Claude.

# Where the toggle and breaker live. Not in the repo — this is per-user state.
VB_STATE="${VOICEBOX_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/voicebox}"
VB_BASE="${VOICEBOX_URL:-http://127.0.0.1:17600}"
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
    response=$(curl -s --connect-timeout 1 -m 5 -X POST "$VB_BASE/speak" \
        -H 'Content-Type: application/json' \
        -H "X-Voicebox-Client-Id: $VB_CLIENT_ID" \
        --data "$body" 2>/dev/null)

    if [ -z "$response" ]; then
        vb_breaker_trip
        return 1
    fi
    vb_breaker_reset
    printf '%s' "$response" | jq -r '.id // empty' 2>/dev/null
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
