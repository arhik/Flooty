# modelWaitMonitorProbe.jl — a driver waiting on its model is monitor-visible.
#
# The terminal is at a prompt during an LLM call, so prompt/busy sampling alone
# looks idle. The driver publishes model-wait start/end; the monitor emits one
# advice line/note after the threshold (never a stop).
#
# Run: julia --startup-file=no --project=. test/modelWaitMonitorProbe.jl
import FlootyPTYLayer
using Flooty
using FlootyPTYLayer: startReplSession, closeSession!, tagIn

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
    startMonitor!(sess;
        completeFn = _ -> "{\"decision\":\"observe\"}",
        onEvent = _ -> nothing,
        cfg = MonitorConfig(pollS = 0.1, interjectAfterS = 0.2))
    Flooty.setAgentModelWait!(sess, true)
    sleep(0.7)
    notes = takeMonitorNotes!(sess)
    check("the monitor notices a driver model wait",
          any(n -> occursin("waiting on the model", n), notes), notes)
    Flooty.setAgentModelWait!(sess, false)
    sleep(0.3)
    check("the wait flag clears without another note",
          !any(n -> occursin("waiting on the model", n), takeMonitorNotes!(sess)), "")
finally
    Flooty.setAgentModelWait!(sess, false)
    try stopMonitor!(sess) catch e; nothing end
    closeSession!(sess)
end

println()
if isempty(failures)
    println("MODEL_WAIT_MONITOR_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
