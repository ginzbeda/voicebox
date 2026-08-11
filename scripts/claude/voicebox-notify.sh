#!/usr/bin/env bash
# Claude Code Notification hook: say when Claude is waiting on you.
#
# This is where voice earns its keep — a permission prompt or an idle session is
# exactly the moment you have walked away from the screen.
#
# Uses a distinct client id so the binding can point it at a different, shorter
# voice than the one reading full responses. Rate-limited, because a burst of
# permission prompts must not queue a minute of speech.
#
# Always exits 0.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./voicebox-common.sh
. "$HERE/voicebox-common.sh"

VB_CLIENT_ID="${VOICEBOX_NOTIFY_CLIENT_ID:-claude-code-notify}"
WINDOW="${VOICEBOX_NOTIFY_WINDOW:-10}"

vb_enabled || exit 0
vb_breaker_open && exit 0
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat)
message=$(printf '%s' "$payload" | jq -r '.message // empty' 2>/dev/null)
[ -n "$message" ] || exit 0

message=$(printf '%s\n' "$message" | vb_clean_text | cut -c1-"${VOICEBOX_NOTIFY_MAXCHARS:-160}")
[ -n "${message//[[:space:]]/}" ] || exit 0

vb_rate_ok notify "$WINDOW" || exit 0

gid=$(vb_speak "$message") || exit 0
[ -n "$gid" ] || exit 0
setsid "$HERE/voicebox-play.sh" "$gid" >/dev/null 2>&1 < /dev/null &
exit 0
