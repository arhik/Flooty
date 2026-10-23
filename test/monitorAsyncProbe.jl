# monitorAsyncProbe.jl — a slow monitor model must not freeze the watcher.
#
# The terminal monitor samples every pollS; its model call used to run INSIDE
# that loop, so a slow insight call stopped all further observation. The call
# now runs in its own task while sampling continues.
#
# Run: julia --startup-file=no --project=. test/monitorAsyncProbe.jl
import FlootyPTYLayer
using Flooty
using FlootyPTYLayer: startReplSession, closeSession!, userWrite, tagIn

failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = detail === "" || detail === nothing ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end

sess = startReplSession(`zsh -i`; waitPrompt = false)
started = Channel{Bool}(1)
release = Channel{Bool}(1)
calls = Ref(0)
try
    sleep(1.4)
    tagIn(sess.control; mode = :agent)
    startMonitor!(sess;
        completeFn = _ -> begin
            calls[] += 1
            put!(started, true)
            take!(release)
            "{\"decision\":\"observe\"}"
        end,
        onEvent = _ -> nothing,
        cfg = MonitorConfig(pollS = 0.1, interjectAfterS = 0.3))
    st = Flooty.MONITOR_STATES[sess]
    userWrite(sess, "sleep 4\n")
    timed = timedwait(() -> calls[] > 0, 5.0)
    check("the long-run evaluation started", timed === :ok && calls[] == 1, calls[])
    t1 = st.ticks
    sleep(0.6)                       # model is still blocked here
    t2 = st.ticks
    check("the sampler kept ticking while the model was blocked",
          t2 > t1 + 2, (t1, t2))
    put!(release, true)
    sleep(0.2)
    check("the evaluation completed and the sampler is alive",
          !st.inflight && !istaskdone(st.task), (st.inflight, istaskdone(st.task)))
finally
    try put!(release, true) catch end
    try stopMonitor!(sess) catch e; nothing end
    closeSession!(sess)
end

println()
if isempty(failures)
    println("MONITOR_ASYNC_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
