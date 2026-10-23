# trajectoryMonitorProbe.jl — a separate watcher for the DRIVER trajectory.
#
# Chat monitor = draft. Terminal monitor = PTY. This one sees turns/tool calls,
# repeated actions, failures, stalls and context, and writes an advisory note.
#
# Run: julia --startup-file=no --project=. test/trajectoryMonitorProbe.jl
using Flooty

failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = detail === "" || detail === nothing ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end

root = ensureRootChatSession!()
calls = Ref(0)
try
    startTrajectoryMonitor!(root;
        completeFn = _ -> (calls[] += 1;
            "{\"decision\":\"insight\",\"title\":\"Trajectory\"," *
            "\"body\":\"the driver is repeating the same send\"}"),
        cfg = TrajectoryConfig(pollS = 0.1, cooldownS = 0.0))
    trajectoryTask!(root, "edit the parser")
    trajectoryToolCall!(root, "send", "sed -i s/a/b/ file")
    trajectoryToolCall!(root, "send", "sed -i s/a/b/ file")   # identical
    trajectoryToolResult!(root, false, "sed: no such file")
    for _ in 1:40
        calls[] > 0 && break
        sleep(0.1)
    end
    notes = takeMonitorNotes!(root)
    check("repeated trajectory reaches its monitor", calls[] > 0, calls[])
    check("…and the insight is queued for the driver",
          any(n -> occursin("repeating", n) && occursin("[trajectory]", n), notes), notes)
finally
    stopTrajectoryMonitor!(root)
end

println()
if isempty(failures)
    println("TRAJECTORY_MONITOR_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
