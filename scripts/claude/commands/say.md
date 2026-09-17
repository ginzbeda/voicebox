---
description: Control Voicebox speech output — on/off/status/stop/list/test, pick a voice, or speak text aloud
argument-hint: "on | off | status | stop | list | test | profile <name> | <text to speak>"
allowed-tools: Bash(~/.claude/hooks/voicectl.sh:*)
---

Voicebox speech control. This governs speech **output** — Claude reading things
aloud. It is unrelated to `/voice`, which is Claude Code's built-in dictation
command for speech **input**.

Run `~/.claude/hooks/voicectl.sh` with the user's arguments, then report its
output verbatim.

The arguments are: $ARGUMENTS

Rules for invoking it:

- Pass the arguments as a **single, properly shell-quoted argument**, e.g.
  `~/.claude/hooks/voicectl.sh 'profile Morgan'`. The script splits the
  subcommand itself.
- The text is arbitrary user prose. It routinely contains apostrophes, quotes,
  `$`, backticks and semicolons — quote it so the shell cannot interpret any of
  it. Never paste it unquoted into a command line.
- Do not substitute your own `curl` calls, and do not summarise away any error
  text. If the backend is unreachable or no audio player is installed, that
  message is the actionable part.
