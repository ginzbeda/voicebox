#!/usr/bin/env bash
# Speak the rest of a turn's chunks, in order.
#
#   voicebox-narrate.sh <first-generation-id> <chunkfile> <epoch>
#
# The Stop hook has already requested the first chunk and passes its generation
# id here; <chunkfile> holds the remaining chunks, one JSON-encoded chunk per
# line, in the order they should be heard. Runs detached from the hook.
#
# Why this exists rather than firing every chunk at once: voicebox-play.sh
# serialises with a mkdir lock, but a mutex is not a queue. N instances racing
# mkdir in a retry loop acquire it in arbitrary order, so chunk four can easily
# be spoken before chunk two. Serialised playback is not ordered narration.
#
# So each chunk is generated and played to completion before the next is even
# requested. Beyond ordering that buys three things: the GPU sees one generation
# at a time instead of a burst, a mid-narration `/say stop` takes effect at the
# next chunk boundary, and nothing is generated for a narration the user has
# already silenced.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./voicebox-common.sh
. "$HERE/voicebox-common.sh"

GID="${1:-}"
CHUNKS="${2:-}"
EPOCH="${3:-0}"

cleanup() { [ -n "$CHUNKS" ] && rm -f "$CHUNKS"; return 0; }
trap cleanup EXIT

# Synchronous, and that is the entire point — this call is what orders the
# narration. Returning means the chunk has finished playing.
[ -n "$GID" ] && "$HERE/voicebox-play.sh" "$GID" "$EPOCH"

[ -n "$CHUNKS" ] && [ -f "$CHUNKS" ] || exit 0

while IFS= read -r line; do
    [ -n "$line" ] || continue

    # Re-checked every chunk rather than once up front: the user can silence a
    # narration halfway through, and the chunks that have not been spoken yet
    # are exactly what they were silencing.
    [ "$(vb_epoch)" = "$EPOCH" ] || break
    vb_enabled || break

    text=$(printf '%s' "$line" | jq -r '.' 2>/dev/null)
    [ -n "${text//[[:space:]]/}" ] || continue

    # A backend that dies mid-narration abandons the remainder rather than
    # retrying once per chunk — break, not continue.
    gid=$(vb_speak "$text") || break
    [ -n "$gid" ] || break

    "$HERE/voicebox-play.sh" "$gid" "$EPOCH"
done < "$CHUNKS"

exit 0
