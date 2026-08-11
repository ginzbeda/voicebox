#!/usr/bin/env bash
# Claude Code SubagentStop hook: announce that a background agent finished.
#
# Deliberately the most conservative of the three hooks. A single planning turn
# can fan out a dozen subagents, and playback is serialised, so an unthrottled
# version would queue minutes of speech and drown the response that follows.
# Hence: a short fixed phrase rather than the agent's output, and a wide rate
# limit window.
#
# Opt-in — set VOICEBOX_SPEAK_SUBAGENTS=1. Always exits 0.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./voicebox-common.sh
. "$HERE/voicebox-common.sh"

[ "${VOICEBOX_SPEAK_SUBAGENTS:-0}" = "1" ] || exit 0

VB_CLIENT_ID="${VOICEBOX_SUBAGENT_CLIENT_ID:-claude-code-notify}"
WINDOW="${VOICEBOX_SUBAGENT_WINDOW:-30}"
MAXCHARS="${VOICEBOX_SUBAGENT_MAXCHARS:-120}"

vb_enabled || exit 0
vb_breaker_open && exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat)

# Prefer a name if the payload carries one, so parallel agents are
# distinguishable; otherwise say something generic rather than nothing.
name=$(printf '%s' "$payload" \
       | jq -r '.subagent_type // .agent_type // .description // empty' 2>/dev/null)
if [ -n "$name" ]; then
    text="Subagent finished: $name"
else
    text="A subagent finished."
fi

text=$(printf '%s\n' "$text" | vb_clean_text | cut -c1-"$MAXCHARS")
vb_rate_ok subagent "$WINDOW" || exit 0

gid=$(vb_speak "$text") || exit 0
[ -n "$gid" ] || exit 0
setsid "$HERE/voicebox-play.sh" "$gid" >/dev/null 2>&1 < /dev/null &
exit 0
