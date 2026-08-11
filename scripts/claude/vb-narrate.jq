# Tag every transcript entry for the turn-narration pipeline.
#
# Run as: jq -c -f vb-narrate.jq <transcript.jsonl>
#
# Emits at most one *compact* JSON document per input entry:
#
#   {"b":1}        a real user prompt — the boundary a turn starts after
#   {"a":[...]}    assistant blocks, in order, already humanised
#   {"r":[...]}    tool results, carrying pass/fail and nothing else
#
# Compactness is load-bearing. The next stage is `awk`, which is line-oriented,
# and a reply containing newlines would otherwise split across lines and be cut
# in half by the boundary scan. Everything stays JSON-encoded until the very
# last step decodes it.
#
# Nothing here reads tool *output*. Exit codes, diffs and test tables are noise
# at the speech layer, and guessing at "N passed" per framework is wrong more
# often than right. Whether it broke is carried by is_error; if the failure
# mattered, Claude's own text block says so, and that is spoken verbatim.

# Last path segment. Absolute paths read aloud are unlistenable.
def base: if . == null or . == "" then "" else (tostring | split("/") | last) end;

# A pattern is only worth speaking when it is words. Regex read as speech
# ("caret backslash d plus dollar") is exactly the weirdness being avoided, so
# anything with metacharacters degrades to a generic phrase instead.
def sayable: if (. != null) and (tostring | test("^[A-Za-z0-9_ .-]{1,40}$"))
             then tostring else null end;

def tool_phrase:
  . as $b
  | (.input // {}) as $i
  | (($i.file_path // $i.notebook_path // $i.path) | base) as $f
  | if   $b.name == "Read"      then (if $f == "" then "Read a file" else "Read \($f)" end)
    elif $b.name == "Edit"      then (if $f == "" then "Made an edit" else "Edited \($f)" end)
    elif $b.name == "MultiEdit" then (if $f == "" then "Made several edits" else "Made several edits to \($f)" end)
    elif $b.name == "Write"     then (if $f == "" then "Wrote a file" else "Wrote \($f)" end)
    elif $b.name == "NotebookEdit" then (if $f == "" then "Edited a notebook" else "Edited the notebook \($f)" end)
    elif $b.name == "Bash"      then ($i.description // "Ran a command")
    elif $b.name == "BashOutput" then null          # plumbing, not narration
    elif $b.name == "KillShell" then "Stopped a background command"
    elif $b.name == "Grep"      then (($i.pattern | sayable) as $p
                                      | if $p then "Searched the code for \($p)"
                                        else "Searched the code" end)
    elif $b.name == "Glob"      then (($i.pattern | sayable) as $p
                                      | if $p then "Looked for files matching \($p)"
                                        else "Looked for matching files" end)
    # "the X agent" rather than "a X agent": the subagent type is a bare name
    # and picking a/an correctly for an arbitrary one is not worth the jq.
    elif $b.name == "Task" or $b.name == "Agent"
                                then "Handed off to the \($i.subagent_type // "helper") agent: \($i.description // "work on this")"
    elif $b.name == "WebFetch"  then "Read a page on the web"   # never speak the URL
    elif $b.name == "WebSearch" then "Searched the web for \($i.query // "something")"
    elif $b.name == "TodoWrite" or ($b.name | startswith("Task"))
                                then "Updated the task list"
    elif $b.name == "ExitPlanMode" then "Put together a plan"
    elif $b.name == "EnterPlanMode" then "Started planning"
    elif $b.name == "AskUserQuestion" then "Asked you a question"
    elif $b.name == "Skill"     then "Used the \($i.skill // "") skill"
    elif $b.name == "ToolSearch" then null          # plumbing, not narration
    elif ($b.name | startswith("mcp__"))
                                then ("Used " + ($b.name | split("__") | .[1:] | join(" ") | gsub("[-_]"; " ")))
    else "Used \($b.name)" end;

# A malformed or unexpected entry must never abort the stream — going silent is
# a worse failure than skipping one line.
try (

  if (.isSidechain == true) then empty            # subagent traffic is its own hook

  elif .type == "user" then
    ( (.message.content) as $c
    | if (.isMeta == true) then empty
      elif ($c | type) == "array" then
        # tool_result entries are the agent's own loop, not a new prompt. Treating
        # one as a turn boundary is the classic off-by-one that truncates a turn
        # to its last tool call.
        ( [ $c[]? | select(.type == "tool_result") ] as $tr
        | if ($tr | length) > 0
          then { r: [ $tr[] | { id: .tool_use_id, err: (.is_error == true) } ] }
          else { b: 1 } end )
      elif ($c | type) == "string" then
        # Command plumbing and injected reminders arrive as user strings but are
        # not the user speaking.
        ( if ($c | test("^<(local-command-stdout|local-command-stderr|command-message|command-name|command-args|system-reminder|user-prompt-submit-hook)"))
          then empty else { b: 1 } end )
      else empty end )

  elif .type == "assistant" then
    # "thinking" is deliberately absent: Claude Code stores it encrypted, so
    # .thinking is always the empty string locally and there is nothing to
    # render. What Claude tried and did is carried by the tool phrases instead.
    ( { a: [ .message.content[]?
             | if   .type == "text"
               then { k: "t", v: (.text // "") }
               elif .type == "tool_use"
               then ( tool_phrase as $p
                      | if $p == null or $p == "" then empty
                        else { k: "u", v: $p, id: (.id // ""), n: (.name // "") } end )
               else empty end ] }
    | select((.a | length) > 0) )

  else empty end

) catch empty
