# monitorAfterStopProbe.jl — user intent is still watched after a run ends.
#
# Reported: when a run stops, user interaction was no longer
# captured by the monitoring agents. Episode 2 required `inputAgentEditor`, but
# after any run the control machine is `:user` (inputPtyOwns) — exactly when the
# user starts typing. The monitor now watches the user-owned prompt's pending
# line.
#
# Run: julia --startup-file=no --project=. test/monitorAfterStopProbe.jl
using Flooty
using FlootyPTYLayer: startReplSession, closeSession!, tagIn, tagOut, userWrite

failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = detail === "" || detail === nothing ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end

sess = startReplSession(`zsh -i`; waitPrompt = false)
calls = Ref(0)
try
    sleep(1.4)
    tagIn(sess.control; mode = :agent)
    startMonitor!(sess;
        completeFn = _ -> (calls[] += 1;
            "{\"decision\":\"insight\",\"title\":\"Intent\"," *
            "\"body\":\"the user is typing a command\"}"),
        onEvent = _ -> nothing,
        cfg = MonitorConfig(pollS = 0.2, intentPopupCooldownS = 0.0))
    # What the runner finally does when a run ends.
    tagOut(sess.control)
    userWrite(sess, "echo HI")          # typed, not submitted
    # Poll: the first monitor sample can be delayed by PTY startup; a fixed
    # 1.2 s wait raced it.
    for _ in 1:20
        calls[] > 0 && break
        sleep(0.2)
    end
    notes = takeMonitorNotes!(sess)
    check("user typing after a run is watched", calls[] > 0, calls[])
    check("…and the intent is queued",
          any(n -> occursin("typing", n), notes), notes)
finally
    try stopMonitor!(sess) catch e; nothing end
    closeSession!(sess)
end

println()
if isempty(failures)
    println("MONITOR_AFTER_STOP_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
