# promptInputProbe.jl — leftover input at the prompt must be VISIBLE and fixable.
#
# Live: `type q` (meant for a pager) landed at the shell, leaving `q` on the input
# line. `atPrompt` went false (the line is no longer a bare prompt), every `send`
# was refused, and the agent waited ~30 turns and stopped as "no progress". Also,
# repeated `wait` actions were being SKIPPED as duplicates — the one action that
# could have let the pane settle.
#
# Pinned here:
#   * pendingInputLine() reads the text after the prompt glyph;
#   * the snapshot carries it as `input="…"` with the exact keys to clear/submit;
#   * a refused send NAMES it and tells the model Ctrl-U/Ctrl-C/Enter;
#   * repeated waits are executed, never skipped.
#
# Run: julia --startup-file=no --project=. test/promptInputProbe.jl
using Flooty
using FlootyPTYLayer: startReplSession, closeSession!, userWrite, tagIn, tailText,
    pendingInputLine

failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = detail === "" || detail === nothing ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end

sess = startReplSession(`zsh -i`; waitPrompt = false)
try
    sleep(1.4)
    tagIn(sess.control; mode = :agent)
    check("a bare prompt has no pending input", pendingInputLine(sess) == "",
          repr(pendingInputLine(sess)))

    userWrite(sess, "q")                 # a stray key, NOT submitted
    sleep(0.4)
    check("typed text at the prompt is detected", pendingInputLine(sess) == "q",
          repr(pendingInputLine(sess)))
    snap = agentSnapshot(sess)
    check("the snapshot exposes it", snap.inputLine == "q", repr(snap.inputLine))
    rendered = string(snap)
    check("…with the keys to clear or submit it",
          occursin("input=\"q\"", rendered) && occursin("Ctrl-U", rendered) &&
          occursin("Ctrl-C", rendered), first(rendered, 240))

    # A send while that text sits there CLEARS it (agent-owned pane) and runs.
    replies = String["{\"action\":\"send\",\"code\":\"echo AFTER_CLEAR\"}",
                     "{\"action\":\"done\",\"summary\":\"cleared\"}"]
    i = Ref(0)
    res = runTerminalAgent!(sess, "recover from leftover input";
                            completeFn = _ -> (i[] += 1; replies[min(i[], 2)]),
                            maxTurns = 4)
    tr = join(res.transcript, "\n")
    check("a send with leftover input clears the line first",
          occursin("cleared leftover input \"q\" before sending", tr), first(tr, 240))
    check("…and the command then runs",
          occursin("AFTER_CLEAR", tailText(sess.tail)), last(tailText(sess.tail), 140))
    check("…the line is empty afterwards", pendingInputLine(sess) == "",
          repr(pendingInputLine(sess)))
    check("the run finishes", res.ok, res.summary)

    # Repeated waits are the RECOVERY action: executed, not skipped.
    waits = String[repeat("{\"action\":\"wait\",\"seconds\":0.2}", 1),
                   repeat("{\"action\":\"wait\",\"seconds\":0.2}", 1),
                   "{\"action\":\"done\",\"summary\":\"waited\"}"]
    j = Ref(0)
    res2 = runTerminalAgent!(sess, "wait three times";
                             completeFn = _ -> (j[] += 1; waits[min(j[], 3)]),
                             maxTurns = 5)
    tr2 = join(res2.transcript, "\n")
    check("repeated waits are not skipped", !occursin("identical wait action", tr2),
          first(tr2, 160))
    check("…and the run finishes", res2.ok, res2.summary)

    # OSC-133 bookkeeping/echoed bells are not typed input.
    userWrite(sess, "\a\a")
    sleep(0.3)
    check("BEL-only input is not pending text", pendingInputLine(sess) == "",
          repr(pendingInputLine(sess)))
finally
    closeSession!(sess)
end

println()
if isempty(failures)
    println("PROMPT_INPUT_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
