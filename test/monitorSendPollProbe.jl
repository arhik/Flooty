# monitorSendPollProbe.jl — the driver polls monitors DURING a send.
#
# Notes produced while the send is blocked become MONITOR NOTE context; an
# interrupt request stops this send (Ctrl+C) instead of waiting for it or for
# the next turn.
#
# Run: julia --startup-file=no --project=. test/monitorSendPollProbe.jl
using Flooty
using FlootyPTYLayer: startReplSession, closeSession!, tagIn, tailText,
    _tailAtIdlePrompt, promptSegment

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
    # ---- 1) a note raised during the send reaches the next model call ------
    replies = String["{\"action\":\"send\",\"code\":\"sleep 1\"}",
                     "{\"action\":\"done\",\"summary\":\"noted\"}"]
    i = Ref(0)
    seen = Ref("")
    res = runTerminalAgent!(sess, "wait and note";
        completeFn = msgs -> begin
            i[] += 1
            if i[] == 1
                @async begin
                    sleep(0.3)
                    pushMonitorNote!(sess, "MID-SEND")
                end
            end
            i[] == 2 && (seen[] = join([string(m.content) for m in msgs
                                        if m.role == "user" || m.role == "system"], "\n"))
            replies[min(i[], length(replies))]
        end, maxTurns = 4)
    check("a monitor note during a send reaches the next turn",
          occursin("MONITOR NOTE", seen[]) &&
          occursin("[chat] MID-SEND", seen[]), first(seen[], 300))
    check("…without interrupting that send", res.ok, res.summary)

    # ---- 2) an interrupt request aborts the running send ------------------
    replies2 = String["{\"action\":\"send\",\"code\":\"sleep 5\"}",
                      "{\"action\":\"done\",\"summary\":\"interrupted\"}"]
    j = Ref(0)
    seen2 = Ref("")
    t0 = time()
    res2 = runTerminalAgent!(sess, "long sleep";
        completeFn = msgs -> begin
            j[] += 1
            j[] == 2 && (seen2[] = join([string(m.content) for m in msgs
                                         if m.role == "user"], "\n"))
            if j[] == 1
                @async begin
                    sleep(0.3)
                    Flooty.requestMonitorInterrupt!(sess, "stuck for test")
                end
            end
            replies2[min(j[], length(replies2))]
        end, maxTurns = 4)
    elapsed = time() - t0
    tr = join(res2.transcript, "\n")
    check("a monitor interrupt aborts the send promptly",
          elapsed < 3.5, round(elapsed; digits = 2))
    check("…and the next model call sees MONITOR INTERRUPT",
          occursin("MONITOR INTERRUPT: stuck for test", seen2[]),
          first(seen2[], 260))
    check("…the transcript logs the interrupt request",
          occursin("[monitor] interrupt requested", tr), first(tr, 260))
    sleep(0.4)
    check("…the prompt is back",
          _tailAtIdlePrompt(promptSegment(sess)), repr(promptSegment(sess)))
    check("…and the run finishes", res2.ok, res2.summary)
finally
    try stopMonitor!(sess) catch e; nothing end
    closeSession!(sess)
end

println()
if isempty(failures)
    println("MONITOR_SEND_POLL_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
