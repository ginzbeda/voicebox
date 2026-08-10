---
description: Control Voicebox speech output — on/off/status/stop/list/test, pick a voice, or speak text aloud
argument-hint: "on | off | status | stop | list | test | profile <name> | <text to speak>"
allowed-tools: Bash(~/.claude/hooks/voicectl.sh:*)
---

Voicebox speech control. This governs speech **output** — Claude reading things
aloud. It is unrelated to `/voice`, which is Claude Code's built-in dictation
command for speech **input**.

!`~/.claude/hooks/voicectl.sh $ARGUMENTS`

Report the command output above to the user verbatim. Do not re-run it, do not
substitute your own `curl` calls, and do not summarise away any error text —
if the backend is unreachable or no audio player is installed, that message is
the actionable part.
