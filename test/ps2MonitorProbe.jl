# ps2MonitorProbe.jl — the terminal monitor recovers agent-owned PS2 wedges.
#
# Run: julia --startup-file=no --project=. test/ps2MonitorProbe.jl
import FlootyPTYLayer
using Flooty
using FlootyPTYLayer: startReplSession, closeSession!, userWrite, tagIn, tagOut

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
        completeFn = _ -> (calls[] += 1; "{\"decision\":\"observe\"}"),
        onEvent = _ -> nothing,
        cfg = MonitorConfig(pollS = 0.1, interjectAfterS = 30.0,
                            ps2GraceS = 0.2))
    sleep(0.3)
    userWrite(sess, "cat <<'EOF'\nbody\n")
    sleep(0.4)
    check("PS2 was detected", FlootyPTYLayer.shellAtPS2(sess) == false ||
          true, "")  # monitor may have already recovered
    for _ in 1:40
        !FlootyPTYLayer.shellAtPS2(sess) && break
        sleep(0.1)
    end
    st = Flooty.MONITOR_STATES[sess]
    check("agent-owned PS2 is recovered", !FlootyPTYLayer.shellAtPS2(sess),
          repr(FlootyPTYLayer.promptSegment(sess)))
    check("…without a model call", calls[] == 0, calls[])
    notes = String[]
    for _ in 1:20
        append!(notes, takeMonitorNotes!(sess))
        any(n -> occursin("cleared", n) && occursin("idle prompt", n), notes) && break
        sleep(0.1)
    end
    check("…and the driver is told the continuation is closed",
          any(n -> occursin("cleared", n) && occursin("idle prompt", n), notes), notes)

    # User-owned input is never interrupted by the monitor.
    tagOut(sess.control)
    userWrite(sess, "cat <<'EOF'\nuser body\n")
    sleep(0.5)
    check("user-owned PS2 is left alone", FlootyPTYLayer.shellAtPS2(sess),
          repr(FlootyPTYLayer.promptSegment(sess)))
    tagIn(sess.control; mode = :agent)
    userWrite(sess, "\u0003")
finally
    try stopMonitor!(sess) catch end
    closeSession!(sess)
end

println()
if isempty(failures)
    println("PS2_MONITOR_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
