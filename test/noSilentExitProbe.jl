# noSilentExitProbe.jl — every non-done harness exit produces a final report.
using Flooty
using FlootyPTYLayer: startReplSession, closeSession!

failures = String[]
function check(name, ok, detail = "")
    println(ok ? "PASS  " : "FAIL  ", name, isempty(detail) ? "" : "  [" * string(detail) * "]")
    ok || push!(failures, name)
end

sess = startReplSession(`zsh -i`; waitPrompt = false)
try
    sleep(1.2)
    r1 = Flooty.runAgentLoop!(sess, "llm failure";
        completeFn = _ -> error("fake provider down"), maxTurns = 3)
    t1 = join(r1.transcript, "\n")
    check("an LLM failure reports instead of exiting silently",
          occursin("[final]", t1) && occursin("LLM", r1.summary), r1.summary)

    r2 = Flooty.runAgentLoop!(sess, "turn budget";
        completeFn = _ -> "{\"action\":\"send\",\"code\":\"echo STILL_GOING\"}",
        maxTurns = 2)
    t2 = join(r2.transcript, "\n")
    check("turn-budget exhaustion reports instead of exiting silently",
          occursin("[final]", t2) && occursin("turn budget", r2.summary), r2.summary)
finally
    closeSession!(sess)
end
println()
if isempty(failures)
    println("NO_SILENT_EXIT_PROBE_OK")
else
    println("FAILED: ", join(failures, ", ")); exit(1)
end
