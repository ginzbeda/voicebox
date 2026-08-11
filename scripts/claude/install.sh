#!/usr/bin/env bash
# Install the Voicebox ↔ Claude Code integration for the current user.
#
#   scripts/claude/install.sh [--merge] [--uninstall]
#
# Claude Code reads hooks and slash commands from ~/.claude, which is outside
# this repo, so they cannot simply be committed into place. This symlinks them
# instead, so the repo stays the source of truth and `git pull` updates the
# installed copy.
#
# Without --merge it prints the settings.json block for you to paste. With
# --merge it edits ~/.claude/settings.json in place using jq, after taking a
# timestamped backup.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
HOOKS_DIR="$CLAUDE_DIR/hooks"
COMMANDS_DIR="$CLAUDE_DIR/commands"
SETTINGS="$CLAUDE_DIR/settings.json"

MERGE=0
UNINSTALL=0
for arg in "$@"; do
    case "$arg" in
        --merge) MERGE=1 ;;
        --uninstall) UNINSTALL=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

HOOK_SCRIPTS=(voicebox-common.sh voicebox-play.sh voicebox-speak.sh voicebox-notify.sh voicebox-subagent.sh voicectl.sh)

if [ "$UNINSTALL" = 1 ]; then
    for name in "${HOOK_SCRIPTS[@]}"; do
        [ -L "$HOOKS_DIR/$name" ] && rm -f "$HOOKS_DIR/$name" && echo "removed $HOOKS_DIR/$name"
    done
    [ -L "$COMMANDS_DIR/say.md" ] && rm -f "$COMMANDS_DIR/say.md" && echo "removed $COMMANDS_DIR/say.md"
    echo "Hook entries in $SETTINGS were left alone — remove them by hand."
    exit 0
fi

mkdir -p "$HOOKS_DIR" "$COMMANDS_DIR"

for name in "${HOOK_SCRIPTS[@]}"; do
    [ -f "$HERE/$name" ] || continue
    # A real file already there is someone's own work — refuse rather than clobber.
    if [ -e "$HOOKS_DIR/$name" ] && [ ! -L "$HOOKS_DIR/$name" ]; then
        echo "! $HOOKS_DIR/$name exists and is not a symlink — leaving it alone" >&2
        continue
    fi
    ln -sfn "$HERE/$name" "$HOOKS_DIR/$name"
    echo "linked $HOOKS_DIR/$name"
done

if [ -f "$HERE/commands/say.md" ]; then
    if [ -e "$COMMANDS_DIR/say.md" ] && [ ! -L "$COMMANDS_DIR/say.md" ]; then
        echo "! $COMMANDS_DIR/say.md exists and is not a symlink — leaving it alone" >&2
    else
        ln -sfn "$HERE/commands/say.md" "$COMMANDS_DIR/say.md"
        echo "linked $COMMANDS_DIR/say.md"
    fi
fi

hooks_json() {
    cat <<EOF
{
  "Stop": [
    { "hooks": [ { "type": "command", "command": "$HOOKS_DIR/voicebox-speak.sh", "async": true, "timeout": 20 } ] }
  ],
  "Notification": [
    { "hooks": [ { "type": "command", "command": "$HOOKS_DIR/voicebox-notify.sh", "async": true, "timeout": 20 } ] }
  ],
  "SubagentStop": [
    { "hooks": [ { "type": "command", "command": "$HOOKS_DIR/voicebox-subagent.sh", "async": true, "timeout": 20 } ] }
  ]
}
EOF
}

if [ "$MERGE" = 1 ]; then
    command -v jq >/dev/null 2>&1 || { echo "jq is required for --merge" >&2; exit 1; }
    [ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
    backup="$SETTINGS.bak-$(date +%Y%m%d-%H%M%S)"
    cp "$SETTINGS" "$backup"

    # Append rather than replace: other tools own entries under the same events,
    # and clobbering someone's existing Stop hook would be a rude surprise.
    merged=$(jq --argjson add "$(hooks_json)" '
        .hooks = ((.hooks // {}) as $h
          | reduce ($add | keys_unsorted[]) as $event ($h;
              .[$event] = (((.[$event] // []) + $add[$event])
                | unique_by(.hooks[0].command))))
    ' "$SETTINGS")
    printf '%s\n' "$merged" > "$SETTINGS"
    echo "merged hook entries into $SETTINGS (backup: $backup)"
else
    cat <<EOF

Add this to the "hooks" object in $SETTINGS
(or re-run with --merge to have it done for you):

$(hooks_json)
EOF
fi

cat <<EOF

Next:
  # Only if the backend is not on the default 127.0.0.1:17493. The hooks read
  # the same VOICEBOX_HOST / VOICEBOX_PORT that .mcp.json does, so set these
  # where your shell will see them (~/.bashrc, ~/.zshenv) - a hook launched by
  # Claude Code does not inherit a variable exported in one terminal.
  export VOICEBOX_PORT=17600        # e.g. Docker publishing container 17493 on host 17600

  ~/.claude/hooks/voicectl.sh test  # end-to-end check
  ./scripts/check-wsl-audio.sh      # if you hear nothing
EOF
