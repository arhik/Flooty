# monitorBootProbe.jl — boot/login is not a command.
#
# Reported: on an SSH session the driver chat showed the monitor reasoning
# about a "running command" before ANY command was run. SSH login (and a REPL
# boot) has no prompt yet, so `atPrompt == false`; the monitor treated that as
# a long-running statement and asked its model about it. Until the session has
# seen its first prompt there is nothing to watch.
#
# Run: julia --startup-file=no --project=. test/monitorBootProbe.jl
using Flooty
using FlootyPTYLayer: startReplSession, closeSession!, userWrite

failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = detail === "" || detail === nothing ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end

# A shell whose prompt appears late, like an SSH login banner.
sess = startReplSession(Cmd(["sh", "-c", "sleep 1.2; exec zsh -i"]); waitPrompt = false)
calls = Ref(0)
try
    startMonitor!(sess;
        completeFn = _ -> (calls[] += 1;
            "{\"decision\":\"insight\",\"title\":\"Run\"," *
            "\"body\":\"a command is running\"}"),
        onEvent = _ -> nothing,
        cfg = MonitorConfig(pollS = 0.1, interjectAfterS = 0.3,
                            intentPopupCooldownS = 0.0))
    sleep(0.8)                         # well past interjectAfterS, still booting
    state = Flooty.MONITOR_STATES[sess]
    check("no prompt seen yet", !state.seenPrompt)
    check("boot is not a long run", calls[] == 0, calls[])
    check("…and queues no note", isempty(takeMonitorNotes!(sess)))

    # Wait for the real prompt; it marks the session ready exactly once.
    for _ in 1:50
        state.seenPrompt && break
        sleep(0.1)
    end
    check("first prompt marks the session ready", state.seenPrompt)

    # A real command now IS watched.
    userWrite(sess, "sleep 3\n")
    for _ in 1:60
        calls[] > 0 && break
        sleep(0.1)
    end
    notes = takeMonitorNotes!(sess)
    check("a real run reaches the monitor", calls[] > 0,
          (calls[], state.busySince, state.seenPrompt, state.busyNotified))
    check("…and its insight is queued", !isempty(notes), notes)
finally
    try stopMonitor!(sess) catch e; nothing end
    closeSession!(sess)
end

println()
if isempty(failures)
    println("MONITOR_BOOT_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
