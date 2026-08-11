# Turn the tagged rows of one turn into the text to speak.
#
# Run as: jq -s -r --arg mode <final|turn|full> -f vb-render.jq
#
# Input is the slurped output of vb-narrate.jq for a single turn (the boundary
# scan has already run), so slurping is bounded by one turn rather than by the
# session — the reason the two stages are split.
#
# Modes:
#   final  what shipped before this change: the last text block only.
#   turn   every text block, plus one sentence accounting for the tool work.
#   full   text and tool phrases interleaved in the order they happened —
#          literally everything Claude said, tried and did this turn.

# Line structure is deliberately preserved here. The cleaners downstream are
# line-oriented — fenced code blocks and markdown tables are recognised by what
# a line starts with and how it is punctuated — so flattening the reply to a
# single line first would silently disable both, and the code and table cells
# they exist to drop would be spoken. vb_clean_text collapses to one line at the
# very end, once there is nothing left that needs the structure.
def squash: gsub("[ \t]+"; " ") | gsub("(?m)^ +| +$"; "") | sub("^\n+"; "") | sub("\n+$"; "");

# Speech needs a beat between clauses. Only add a stop where there isn't one,
# or every tool phrase following a sentence gains a stray "..".
def stopped: squash | if . == "" then "" elif test("[.!?:;,][\"')\\]]*$") then . else . + "." end;

def plural($n; $one; $many): if $n == 1 then "1 \($one)" else "\($n) \($many)" end;

. as $rows
| ( [ $rows[]? | select(has("r")) | .r[]? | select(.err == true) | .id ]
    | map({ (.): true }) | add // {} ) as $failed
| ( [ $rows[]? | select(has("r")) | .r[]? | select(.err == true) ] | length ) as $failures
| [ $rows[]? | select(has("a")) | .a[]? ] as $blocks
| [ $blocks[] | select(.k == "t") | .v | squash | select(. != "") ] as $texts
| [ $blocks[] | select(.k == "u") ] as $tools

# ── the tool-work sentence, used by `turn` ────────────────────────────────
| ( [ ( [ $tools[] | select(.n == "Read") ] | length ) as $reads
    | ( [ $tools[] | select(.n == "Edit" or .n == "MultiEdit" or .n == "Write" or .n == "NotebookEdit") ] | length ) as $edits
    | ( [ $tools[] | select(.n == "Bash") ] | length ) as $cmds
    | ( [ $tools[] | select(.n == "Grep" or .n == "Glob" or .n == "WebSearch") ] | length ) as $finds
    | ( [ $tools[] | select(.n == "Task" or .n == "Agent") ] | length ) as $agents
    | ( if $reads  > 0 then "read \(plural($reads; "file"; "files"))" else empty end ),
      ( if $cmds   > 0 then "ran \(plural($cmds; "command"; "commands"))" else empty end ),
      ( if $edits  > 0 then "made \(plural($edits; "edit"; "edits"))" else empty end ),
      ( if $finds  > 0 then "ran \(plural($finds; "search"; "searches"))" else empty end ),
      ( if $agents > 0 then "sent out \(plural($agents; "agent"; "agents"))" else empty end )
    ] ) as $parts
| ( if ($parts | length) == 0 then ""
    elif ($parts | length) == 1 then "Along the way I \($parts[0])."
    else "Along the way I \($parts[0:-1] | join(", ")) and \($parts[-1])."
    end ) as $summary
| ( if $failures > 0 then " \(plural($failures; "step"; "steps")) failed." else "" end ) as $failnote

# ── mode dispatch ─────────────────────────────────────────────────────────
| if $mode == "final" then
    ( $texts | last // "" )

  elif $mode == "turn" then
    ( [ $texts[] | stopped ]
      + (if $summary == "" then [] else [ $summary + $failnote ] end)
      | join("\n") )

  else
    # full: preserve order. A tool that came back an error says so on the spot,
    # which is where it is useful — right next to what was being attempted.
    ( [ $blocks[]
        | if .k == "t" then (.v | squash)
          else (.v | squash) + (if $failed[.id] then ", but that failed" else "" end)
          end
        | select(. != "") ]
      # Collapse only *consecutive identical* phrases. Anything more aggressive
      # would drop exactly the detail this mode exists to speak.
      | reduce .[] as $p ([]; if (length > 0) and (.[-1] == $p) then . else . + [$p] end)
      | map(stopped)
      | join("\n") )
  end
| squash
