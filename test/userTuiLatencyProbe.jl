# userTuiLatencyProbe.jl — the user's full-screen app must stay responsive.
#
# A 2 s ambient-monitor tick used to copy the whole 1 MiB tail and scan it
# while the user typed in micro/broot. This probe pins the behavior:
#   * micro enters the alternate screen;
#   * a keystroke reaches the PTY reader promptly;
#   * the monitor does NOT call its model while the USER owns that app.
#
# Run: julia --startup-file=no --project=. test/userTuiLatencyProbe.jl
using Flooty
using FlootyPTYLayer: startReplSession, closeSession!, userWrite, tagOut, inAltScreen, addOutputTap!

failures = String[]
function check(name, ok, detail = "")
    println(ok ? "PASS  " : "FAIL  ", name, isempty(detail) ? "" : "  [" * string(detail) * "]")
    ok || push!(failures, name)
end

file = tempname()
write(file, "hello\n")
sess = startReplSession(`micro $file`; waitPrompt = false)
try
    deadline = time() + 5.0
    while !inAltScreen(sess) && time() < deadline
        sleep(0.05)
    end
    check("micro enters the alternate screen", inAltScreen(sess))
    tagOut(sess.control)

    chunks = Ref(0)
    lastAt = Ref(0.0)
    addOutputTap!(sess) do _
        chunks[] += 1
        lastAt[] = time()
    end

    # The monitor is attached like every real tab. It must not spend a model
    # call (or a full-tail parse) while the user owns micro.
    calls = Ref(0)
    ok = startMonitor!(sess; cfg = MonitorConfig(pollS = 0.1),
                       completeFn = _ -> (calls[] += 1; "{\"decision\":\"observe\"}"))
    check("monitor attaches", ok)
    sleep(0.5)
    check("the monitor skips a user-owned full-screen app", calls[] == 0, calls[])

    lat = Float64[]
    for i in 1:5
        before = chunks[]
        t0 = time()
        userWrite(sess, "a")
        deadline = time() + 1.0
        while chunks[] == before && time() < deadline
            sleep(0.005)
        end
        elapsed = time() - t0
        push!(lat, elapsed)
        check("keystroke $i reaches the reader", chunks[] > before, round(elapsed; digits = 3))
    end
    check("keystroke latency stays interactive (max < 250 ms)", maximum(lat) < 0.25,
          round(maximum(lat); digits = 3))
    stopMonitor!(sess)
finally
    closeSession!(sess)
end

println()
if isempty(failures)
    println("USER_TUI_LATENCY_PROBE_OK")
else
    println("FAILED: ", join(failures, ", ")); exit(1)
end
