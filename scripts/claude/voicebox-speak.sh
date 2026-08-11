#!/usr/bin/env bash
# Claude Code Stop hook: narrate the finished turn through Voicebox.
#
# Reads the hook payload on stdin, reconstructs what the session said, tried and
# did since the user's last prompt, and hands it to the narrator to be spoken in
# order.
#
# Always exits 0. A Stop hook that fails must never wedge the turn, and there is
# no useful recovery here — if Voicebox is down the turn should still end.
#
# Tunables (env):
#   VOICEBOX_URL             default http://127.0.0.1:17493
#   VOICEBOX_CLIENT_ID       default claude-code
#   VOICEBOX_VERBOSITY       final | turn | full   (default full)
#   VOICEBOX_MAXCHARS        default 400   — cap for `final` only
#   VOICEBOX_TURN_MAXCHARS   default 2000  — total budget for turn/full
#   VOICEBOX_CHUNK_CHARS     default 350   — target utterance length
#   VOICEBOX_MAX_CHUNKS      default 8     — utterances per turn
#   VOICEBOX_FLUSH_ON_NEW_TURN  default 1  — supersede a lagging narration
#   VOICEBOX_DRY_RUN         print the narration, speak nothing
#   VOICEBOX_STATE_DIR       default ~/.local/state/voicebox
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./voicebox-common.sh
. "$HERE/voicebox-common.sh"

MAXCHARS="${VOICEBOX_MAXCHARS:-400}"
TURN_MAXCHARS="${VOICEBOX_TURN_MAXCHARS:-2000}"
CHUNK_CHARS="${VOICEBOX_CHUNK_CHARS:-350}"
MAX_CHUNKS="${VOICEBOX_MAX_CHUNKS:-8}"
DRY_RUN="${VOICEBOX_DRY_RUN:-0}"

# Cheapest checks first — these run on every single turn.
[ "$DRY_RUN" = "1" ] || vb_enabled || exit 0
[ "$DRY_RUN" = "1" ] || ! vb_breaker_open || exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat)
transcript=$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null)
[ -n "$transcript" ] && [ -f "$transcript" ] || exit 0

# Scope repeat-suppression to the session. A single global marker means two
# concurrent sessions ending a turn with the same short reply ("Done.") would
# silence the second one. Fall back to the transcript path when no session id
# is present, which is still per-session.
session=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$session" ] || session="$transcript"
session_key=$(printf '%s' "$session" | cksum | cut -d' ' -f1)

VERBOSITY=$(vb_verbosity)

# ─── Build the narration ───────────────────────────────────────────────────
#
# Stage 1 tags every entry, one compact JSON document per line. Stage 2 keeps
# only what follows the last turn boundary. Both stream, so memory is bounded by
# a turn rather than by the session — a distinction that matters on transcripts
# that run to thousands of entries.
#
# Compactness is what makes the awk scan safe: a reply containing newlines still
# occupies exactly one line here, so the boundary scan cannot cut a reply in
# half. The text is only decoded in stage 3.
#
# Only the tail is parsed. A long-running session's transcript reaches tens of
# megabytes, and jq over all of it costs seconds on every single turn — for a
# turn that is, by definition, at the end of the file. Bounded by lines rather
# than bytes on purpose: `tail -c` would hand jq a truncated first line, and a
# parse error stops the stream rather than skipping the line.
TAIL_LINES="${VOICEBOX_TRANSCRIPT_TAIL:-4000}"
tagged=$(tail -n "$TAIL_LINES" "$transcript" 2>/dev/null \
         | jq -c -f "$HERE/vb-narrate.jq" 2>/dev/null)
[ -n "$tagged" ] || exit 0

turn=$(printf '%s\n' "$tagged" | awk '
    /^\{"b":/ { n = 0; next }
    { buf[++n] = $0 }
    END { for (i = 1; i <= n; i++) print buf[i] }')

# A transcript whose schema drifted — Claude Code's JSONL is not a public
# contract — must degrade to speaking something rather than to silence.
[ -n "$turn" ] || turn="$tagged"

text=$(printf '%s\n' "$turn" \
       | jq -s -r --arg mode "$VERBOSITY" -f "$HERE/vb-render.jq" 2>/dev/null)
[ -n "$text" ] || exit 0

if [ "$VERBOSITY" = "final" ]; then
    text=$(printf '%s\n' "$text" | vb_clean_text | cut -c1-"$MAXCHARS")
else
    text=$(printf '%s\n' "$text" | vb_clean_verbose)
    # Voicebox generates in real time — an uncapped turn produces minutes of
    # speech and pins the GPU well past the end of the turn. Trim back to the
    # last sentence end so the budget never lands mid-word.
    if [ "${#text}" -gt "$TURN_MAXCHARS" ]; then
        text=$(printf '%s' "$text" | cut -c1-"$TURN_MAXCHARS" \
               | sed -e 's/\(.*[.!?]\).*/\1/')
    fi
fi
[ -n "${text//[[:space:]]/}" ] || exit 0

# ─── Dedup ─────────────────────────────────────────────────────────────────
#
# Stop can fire more than once for a single logical turn; speaking the same
# narration twice is worse than staying quiet. Hash the assembled narration
# rather than a single chunk — per-chunk hashing would let a re-fired hook
# replay half a turn.
#
# This has to happen *before* the epoch bump below. Bumping first meant a
# duplicate Stop firing flushed the narration still being spoken and then exited
# here, turning working speech into silence.
vb_init_state
marker="$VB_STATE/last-spoken-$session_key"
hash=$(printf '%s' "$text" | cksum | cut -d' ' -f1)
if [ "$hash" = "$(cat "$marker" 2>/dev/null)" ] && [ "$DRY_RUN" != "1" ]; then
    exit 0
fi

# ─── Chunk ─────────────────────────────────────────────────────────────────

chunks=$(printf '%s\n' "$text" | vb_chunk "$CHUNK_CHARS" | head -n "$MAX_CHUNKS")
[ -n "$chunks" ] || exit 0

if [ "$DRY_RUN" = "1" ]; then
    # The development loop: inspect what a real transcript would produce
    # without spending a GPU-minute or making a sound.
    printf '%s\n' "$chunks" | jq -r '.'
    exit 0
fi

# ─── Hand off to the narrator ──────────────────────────────────────────────
#
# A new turn's narration supersedes one still being spoken from the previous
# turn; otherwise a slow backlog talks over work the user has already moved past.
if [ "${VOICEBOX_FLUSH_ON_NEW_TURN:-1}" = "1" ] && [ "$VERBOSITY" != "final" ]; then
    vb_epoch_bump
fi
epoch=$(vb_epoch)

# The first chunk is requested here rather than in the narrator, and the rest
# are not. That split is deliberate:
#
#   - POST /speak returns as soon as the row exists, so this costs the turn one
#     bounded request — exactly what it cost before turn narration existed.
#   - The circuit breaker only arms on a call that actually happened. Deferring
#     every request to a detached process meant a dead backend was discovered
#     after the hook had already exited, so the breaker never armed in time to
#     save the next turn.
#   - The dedup marker can be written on success rather than on intent, which
#     is what lets a turn that failed while Voicebox was down be spoken later.
first=$(printf '%s\n' "$chunks" | head -1 | jq -r '.' 2>/dev/null)
[ -n "${first//[[:space:]]/}" ] || exit 0

gid=$(vb_speak "$first") || exit 0
[ -n "$gid" ] || exit 0

printf '%s' "$hash" > "$marker" 2>/dev/null || true

rest=$(printf '%s\n' "$chunks" | tail -n +2)
chunkfile=$(mktemp "$VB_STATE/chunks-$session_key-XXXXXX") || chunkfile=""
[ -n "$chunkfile" ] && printf '%s\n' "$rest" > "$chunkfile"

# Detach: playing the first chunk and generating the rest takes seconds to
# minutes, and the turn must not wait.
setsid "$HERE/voicebox-narrate.sh" "$gid" "$chunkfile" "$epoch" \
    >/dev/null 2>&1 < /dev/null &
exit 0
