# monitorLongRunProbe.jl — the ambient monitor reacts to a REAL running command.
#
# Reported: "monitoring is still not reacting." Two causes:
#   * the monitor only watched `sess.pending` (sentinel evals), never a plain
#     PTY command sent by the agent or typed in the shell;
#   * the insight path called `now()` (Dates.DateTime) and subtracted a Float64,
#     so every model "insight" decision threw inside the monitor loop.
# A statement is now detected from the prompt state (not at an idle prompt,
# not a full-screen app), and the insight path uses `time()`.
#
# Run: julia --startup-file=no --project=. test/monitorLongRunProbe.jl
import FlootyPTYLayer
using Flooty
using FlootyPTYLayer: startReplSession, closeSession!, userWrite

failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = detail === "" || detail === nothing ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end

sess = startReplSession(`zsh -i`; waitPrompt = false)
calls = Ref(0)
events = Any[]
try
    sleep(1.4)
    startMonitor!(sess;
        completeFn = _ -> (calls[] += 1;
            "{\"decision\":\"insight\",\"title\":\"Long run\"," *
            "\"body\":\"the command is still running\"}"),
        onEvent = fb -> push!(events, fb),
        cfg = MonitorConfig(pollS = 0.1, interjectAfterS = 0.5))
    userWrite(sess, "sleep 4\n")
    # Poll: the first monitor sample can be delayed by PTY startup.
    for _ in 1:40
        calls[] > 0 && break
        sleep(0.1)
    end
    check("a running command reaches the monitor", calls[] > 0, calls[])
    check("the insight decision produces an event",
          any(fb -> occursin("still running", fb.body), events), length(events))
    notes = takeMonitorNotes!(sess)
    check("the insight is queued for the agent",
          any(n -> occursin("still running", n), notes), notes)
    check("…and the long-run fact is in the driver's note channel",
          any(n -> occursin("long run", n), notes), notes)
    # Let the long command return to the prompt (and the monitor reset its
    # episode) before probing a quick command.
    for _ in 1:60
        FlootyPTYLayer._tailAtIdlePrompt(FlootyPTYLayer.tailText(sess.tail)) && break
        sleep(0.1)
    end
    sleep(0.4)
    before = calls[]
    userWrite(sess, "echo quick\n")
    sleep(1.2)
    # A quick command is a terminal EVENT now (the Terminal monitor must reflect
    # real terminal activity), not another long-run episode.
    check("a prompt-returning command becomes a terminal event", calls[] > before,
          (before, calls[]))
finally
    try stopMonitor!(sess) catch e; nothing end
    closeSession!(sess)
end

println()
if isempty(failures)
    println("MONITOR_LONG_RUN_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
