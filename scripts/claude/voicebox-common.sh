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

# How much of a turn gets spoken. See vb_verbosity below for the levels.
# `full` is the default because the point of narration is to follow what the
# session is doing without watching it — a terse final sentence tells you it
# finished, not what it found. `/say verbosity turn` or `final` dials it back.
VB_VERBOSITY_DEFAULT="full"

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

# How much of a turn to speak. Env wins, then the file written by
# `/say verbosity`, then the built-in default.
#
#   final  the last text block only — what shipped before turn narration
#   turn   every text block, plus one sentence accounting for the tool work
#   full   text and tool phrases interleaved, in the order they happened
vb_verbosity() {
    local level="${VOICEBOX_VERBOSITY:-}"
    [ -n "$level" ] || level=$(cat "$VB_STATE/verbosity" 2>/dev/null)
    case "$level" in
        final|turn|full) printf '%s' "$level" ;;
        *) printf '%s' "$VB_VERBOSITY_DEFAULT" ;;
    esac
}

# Everything that survives markdown cleaning but still reads as machine noise.
#
# POSIX awk, not sed: vb_clean_text already carries one GNU-only construct
# (`https\?://`) that misbehaves under BSD sed, and macOS is a supported target
# — afplay is in the player list. Adding more GNU-isms would deepen that bug,
# while awk behaves identically on both.
vb_scrub_tokens() {
    awk '{
        n = split($0, w, " "); out = ""
        for (i = 1; i <= n; i++) {
            t = w[i]
            if (t == "") continue
            # CLI flags. Tested before the path rewrite so --file=/a/b/c.ts is
            # dropped whole rather than surfacing as "c.ts".
            if (t ~ /^--?[A-Za-z0-9]/) continue
            # Hashes and object ids. Written as an explicit run because POSIX
            # awk gives no interval-expression guarantee.
            if (t ~ /^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]+[.,:;]?$/) continue
            if (t ~ /[{}<>|&$]/) continue                  # JSON and shell operators
            # Path -> basename. A directory written with a trailing slash has
            # no basename, and dropping it left sentences like "has no at all";
            # fall back to the last named segment instead.
            was_path = 0
            if (t ~ /\//) {
                was_path = 1
                whole = t
                sub(/^.*\//, "", t)
                if (t == "") {
                    sub(/\/+$/, "", whole)
                    sub(/^.*\//, "", whole)
                    t = whole
                }
            }
            # A basename that is only digits carries nothing on its own and
            # lands next to whatever number follows. "/mnt/m/.Trashes/502 =
            # 246 GB" was spoken as "502 246 GB" — two unrelated figures fused
            # into one meaningless quantity. Bare numbers that were never part
            # of a path are kept; those are the real measurements.
            if (was_path && t ~ /^[0-9]+$/) continue
            # A leading dot is an attribute reference (.thinking, .message)
            # that has lost its backticks. Left alone it later gets glued to
            # the previous word, so "encrypted — .thinking is empty" is spoken
            # as "encrypted.thinking is empty".
            if (t ~ /^\.[A-Za-z]/) { sub(/^\./, "", t) }
            if (t == "") continue
            if (length(t) > 28 && t !~ /[aeiouAEIOU]/) continue   # identifier soup
            if (t ~ /^[^A-Za-z0-9]+$/) continue            # punctuation islands
            out = (out == "" ? t : out " " t)
        }
        print out
    }'
}

# Cleaning for narration. vb_clean_text is deliberately left alone — /say and
# the notify hook speak prose the user wrote, where stripping paths and flags
# would destroy the message.
#
# The inline-code pass has to run first: vb_clean_text deletes backticks
# without deleting what is between them, so by the time it has run an inline
# span is indistinguishable from prose and gets spoken as code.
#
# Short spans keep their contents. They are nearly always a bare identifier
# standing in as the subject of the sentence — "`bun` isn't installed" — and
# deleting them outright produced decapitated sentences ("isn't installed")
# that are far more confusing to hear than the identifier would have been.
# Long spans are real code and still go. What survives is filtered again by
# vb_scrub_tokens, which drops the paths, flags and hashes anyway.
#
# Fenced blocks have to go before the span passes, not after. A fence is three
# backticks, so the span patterns happily chew two of them and leave a stray
# third — which stops vb_clean_text's fence matcher from recognising the block
# at all, and the code it was supposed to drop gets spoken.
#
# Table rows go entirely. vb_clean_text strips the pipes but keeps the cells,
# which turns a comparison table into a run of unattached values — "earlier now
# PID 7032 21944 VRAM 2293 MB 3378 MB" — that is worse than silence. A table is
# a shape, and the shape is what carries the meaning.
#
# Snake_case is split rather than left to vb_clean_text, which strips
# underscores as markdown emphasis and so turns resolve_profile into the
# unpronounceable "resolveprofile". Identifiers are common in narration —
# function and flag names are half of what a session talks about — and they
# read naturally once the underscore becomes a space. Twice, because the
# pattern consumes the character on each side and a_b_c needs a second pass.
vb_clean_verbose() {
    sed -e '/^[[:space:]]*```/,/^[[:space:]]*```/d' \
        -e '/|[^|]*|/d' \
        -e 's/`\([^`]\{1,32\}\)`/\1/g' \
        -e 's/`[^`]*`/ /g' \
        -e 's/\([A-Za-z0-9]\)_\([A-Za-z0-9]\)/\1 \2/g' \
        -e 's/\([A-Za-z0-9]\)_\([A-Za-z0-9]\)/\1 \2/g' | vb_clean_text | vb_scrub_tokens \
        | sed -e 's/  */ /g' \
              -e 's/ \([,.;:!?]\)\([[:space:]]\)/\1\2/g' \
              -e 's/ \([,.;:!?]\)$/\1/' \
              -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# Split one long line into utterance-sized chunks, one JSON-encoded chunk per
# line. Encoding keeps a multi-sentence chunk on a single line for the narrator
# loop, which reads line by line.
#
# The sentence split only breaks on terminator + space + capital, so
# `voicebox-speak.sh` and `v1.2` are not mistaken for sentence ends. A single
# sentence longer than $1 is emitted over-length rather than cut: a clause
# severed mid-word sounds far worse than a long one.
vb_chunk() {
    local max="${1:-350}"
    sed -e 's/\([.!?]\)  *\([A-Z0-9]\)/\1\n\2/g' \
      | awk -v max="$max" '
          {
            s = $0
            if (s == "") next
            if (buf != "" && length(buf) + 1 + length(s) > max) { print buf; buf = "" }
            buf = (buf == "" ? s : buf " " s)
          }
          END { if (buf != "") print buf }' \
      | jq -R -c '.'
}

# Flush generation. Every utterance carries the epoch it was queued under;
# anything that finds the epoch moved on drops itself instead of speaking into
# a world the user has already silenced.
#
# A counter rather than a kill: an utterance can be queued, generating, or
# waiting on the play lock, and only the queued ones have a process to signal.
vb_epoch() {
    local n
    n=$(cat "$VB_STATE/epoch" 2>/dev/null)
    case "$n" in
        ''|*[!0-9]*) printf '0' ;;
        *) printf '%s' "$n" ;;
    esac
}

vb_epoch_bump() {
    vb_init_state
    printf '%s' "$(( $(vb_epoch) + 1 ))" > "$VB_STATE/epoch" 2>/dev/null || true
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
