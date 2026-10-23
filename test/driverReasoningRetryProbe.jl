# driverReasoningRetryProbe.jl — the DRIVER retries a reasoning-only reply.
#
# Live (SSH): the first turn emitted only <thinking>, so the harness logged an
# empty "[warn] unparseable model output (turn 1):" and spent the next turn
# re-deriving the same plan. The ChatSession driver already retried once; the
# terminal driver now does too.
#
# Run: julia --startup-file=no --project=. test/driverReasoningRetryProbe.jl
using Flooty
using FlootyPTYLayer: startReplSession, closeSession!, tagIn, tailText

failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = detail === "" || detail === nothing ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end

sess = startReplSession(`zsh -i`; waitPrompt = false)
calls = Ref(0)
seenRetryNote = Ref(false)
try
    sleep(1.4)
    tagIn(sess.control; mode = :agent)
    replies = String[
        "<thinking>I need to inspect the repository but I forgot the action.</thinking>",
        "{\"action\":\"send\",\"code\":\"echo DRIVER_RETRY_OK\"}",
        "{\"action\":\"done\",\"summary\":\"retried\"}",
    ]
    res = runTerminalAgent!(sess, "get familiar with the repo";
        completeFn = msgs -> begin
            calls[] += 1
            calls[] == 2 && (seenRetryNote[] =
                any(m -> m.role == "user" && occursin("previous reply contained reasoning",
                                                       string(m.content)), msgs))
            replies[min(calls[], length(replies))]
        end,
        maxTurns = 6)
    tr = join(res.transcript, "\n")
    check("a reasoning-only reply is retried in the same turn",
          occursin("[retry] reasoning-only reply", tr), first(tr, 220))
    check("…the retry sees the schema note", seenRetryNote[], "")
    check("…no empty unparseable warning is emitted",
          !occursin("[warn] unparseable model output", tr), "")
    check("…the retried action runs",
          occursin("DRIVER_RETRY_OK", tailText(sess.tail)), last(tailText(sess.tail), 160))
    check("…and the run finishes", res.ok, res.summary)
finally
    closeSession!(sess)
end

println()
if isempty(failures)
    println("DRIVER_REASONING_RETRY_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
