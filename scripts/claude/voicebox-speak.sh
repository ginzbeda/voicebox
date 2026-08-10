#!/usr/bin/env bash
# Claude Code Stop hook: speak the final response through Voicebox.
#
# Reads the hook payload on stdin, pulls the last assistant text block out of
# the session transcript, speaks it, and plays the result.
#
# Always exits 0. A Stop hook that fails must never wedge the turn, and there is
# no useful recovery here — if Voicebox is down the turn should still end.
#
# Tunables (env):
#   VOICEBOX_URL        default http://127.0.0.1:17600
#   VOICEBOX_CLIENT_ID  default claude-code
#   VOICEBOX_MAXCHARS   default 400
#   VOICEBOX_STATE_DIR  default ~/.local/state/voicebox
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./voicebox-common.sh
. "$HERE/voicebox-common.sh"

MAXCHARS="${VOICEBOX_MAXCHARS:-400}"

# Cheapest checks first — these run on every single turn.
vb_enabled || exit 0
vb_breaker_open && exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat)
transcript=$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null)
[ -n "$transcript" ] && [ -f "$transcript" ] || exit 0

# The transcript is JSONL, so jq reads it a document at a time and this stays
# cheap on long sessions — no slurping a session-length file into memory.
#
# Each assistant message is emitted as one *encoded* JSON string, so a reply
# containing newlines still occupies exactly one line here. That matters: with
# `jq -r` the reply's own newlines survive, and `tail -1` then picks the last
# line of the last message rather than the last message — silently speaking
# only the final line of every multi-line answer.
text=$(jq -c 'select(.type=="assistant")
              | [.message.content[]? | select(.type=="text") | .text]
              | join("\n")
              | select(length > 0)' "$transcript" 2>/dev/null \
       | tail -1 \
       | jq -r '.' 2>/dev/null)
[ -n "$text" ] || exit 0

text=$(printf '%s\n' "$text" | vb_clean_text)

# Voicebox generates in real time — an uncapped long answer produces minutes of
# speech and pins the GPU well past the end of the turn.
text=$(printf '%s' "$text" | cut -c1-"$MAXCHARS")
[ -n "${text//[[:space:]]/}" ] || exit 0

# Stop can fire more than once for a single logical turn; speaking the same
# paragraph twice is worse than staying quiet.
vb_init_state
hash=$(printf '%s' "$text" | cksum | cut -d' ' -f1)
[ "$hash" = "$(cat "$VB_STATE/last-spoken" 2>/dev/null)" ] && exit 0
printf '%s' "$hash" > "$VB_STATE/last-spoken" 2>/dev/null || true

gid=$(vb_speak "$text") || exit 0
[ -n "$gid" ] || exit 0

# Detach: generation plus playback takes seconds, and the turn must not wait.
setsid "$HERE/voicebox-play.sh" "$gid" >/dev/null 2>&1 < /dev/null &
exit 0
