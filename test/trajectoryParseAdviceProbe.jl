# trajectoryParseAdviceProbe.jl — parse failure gets an intention-aware alternative.
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
    Flooty.trajectoryTask!(sess, "port ShadowTerm to Julia")
    Flooty.trajectoryToolCall!(sess, "send", "grep -n 'test' src/terminal.jl | head -100")
    Flooty.startTrajectoryMonitor!(sess;
        cfg = TrajectoryConfig(pollS = 0.1, cooldownS = 0.1))
    sleep(0.2)
    for _ in 1:2
        Flooty.noteAgentParseFailure!(sess,
            "{\"action\":\"send\",\"code\":\"grep -n 'test \\\"' src/terminal.jl | head -100")
    end
    sleep(0.5)
    notes = takeMonitorNotes!(sess)
    joined = join(notes, "\n")
    check("the trajectory monitor sees the parse streak", occursin("unparseable replies x2", joined), joined)
    check("…mentions the last intent", occursin("Last intent: tool send", joined), joined)
    check("…suggests shortening/splitting the command", occursin("truncated", joined) &&
          occursin("split", joined), joined)
    check("…and mentions type for pagers", occursin("pager", joined), joined)
    stopTrajectoryMonitor!(sess)
finally
    closeSession!(sess)
end
println()
if isempty(failures)
    println("TRAJECTORY_PARSE_ADVICE_PROBE_OK")
else
    println("FAILED: ", join(failures, ", ")); exit(1)
end
