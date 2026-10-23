# monitorParseFailureProbe.jl — the monitor notices malformed driver replies.
#
# Live: the driver emitted unescaped-quote JSON eight turns in a row; the
# terminal never changed, so the PTY-only monitor looked healthy. The driver now
# publishes consecutive parse failures; the monitor surfaces the streak once.
#
# Run: julia --startup-file=no --project=. test/monitorParseFailureProbe.jl
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
    Flooty.noteAgentParseFailure!(sess,
        "{\"action\":\"send\",\"code\":\"grep -rn \"ALPHA_LO\\|X\" src/\"}")
    Flooty.noteAgentParseFailure!(sess,
        "{\"action\":\"send\",\"code\":\"grep -rn \"ALPHA_LO\\|X\" src/\"}")
    sleep(0.7)
    notes = takeMonitorNotes!(sess)
    check("the monitor notices consecutive malformed replies",
          any(n -> occursin("consecutive unparseable replies", n), notes), notes)
    check("…the note names the last reply",
          any(n -> occursin("grep", n), notes), notes)
    Flooty.clearAgentParseFailure!(sess)
    sleep(0.3)
    check("clearing the streak does not duplicate the note",
          !any(n -> occursin("consecutive unparseable", n), takeMonitorNotes!(sess)), "")
finally
    Flooty.clearAgentParseFailure!(sess)
    try stopMonitor!(sess) catch e; nothing end
    closeSession!(sess)
end

println()
if isempty(failures)
    println("MONITOR_PARSE_FAILURE_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
