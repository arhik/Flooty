# trajectoryStreamProbe.jl — the trajectory monitor has its own stream tab.
#
# Run: julia --startup-file=no --project=. test/trajectoryStreamProbe.jl  (opens a window)
import FlootyPTYLayer
import Webviews
using Flooty
const L = FlootyPTYLayer

failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = detail === "" || detail === nothing ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end
wv = L.launchTerminalUI(chatOnly = true)
later(f, s = 0.25) = Webviews.set_timeout(f, wv, s)
CALLS = Ref(0)
function finish()
    try Webviews.close(wv) catch e; L.requestStopEventLoop!(wv) end
    println()
    if isempty(failures)
        println("TRAJECTORY_STREAM_PROBE_OK")
    else
        println("FAILED CHECKS: ", join(failures, ", ")); exit(1)
    end
end
function report(then)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__tj__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        (function () {
            var info = chatTabs[CHAT_SESSION_ID] || CHAT_ONLY;
            var b = document.querySelector('#chatStreamTabs [data-stream="trajectory"]');
            window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__tj__',
                text: JSON.stringify({
                    tab: b ? !b.hidden : false,
                    log: (info.trajectoryMonitorChat || []).map(function (m) {
                        return m.role + ':' + m.text; })
                }) })).catch(function(){});
        })();
    """)
    later(function ()
        then(lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__tj__", ""),
                  L.TERMINAL_BUFFER_LOCK))
    end, 0.15)
end
function waitReady(n)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__tj_ready__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__tj_ready__',
            text: String(typeof handleAgentEvent === 'function' && !!CHAT_SESSION_ID) }))
            .catch(function(){});
    """)
    later(function ()
        ok = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__tj_ready__", ""),
                  L.TERMINAL_BUFFER_LOCK) == "true"
        ok && return feed()
        n > 80 && (check("page ready", false, ""); return finish())
        waitReady(n + 1)
    end, 0.2)
end
function feed()
    root = ensureRootChatSession!()
    startTrajectoryMonitor!(root;
        completeFn = _ -> (CALLS[] += 1;
            "{\"decision\":\"insight\",\"body\":\"trajectory insight\"}"),
        cfg = TrajectoryConfig(pollS = 0.1, cooldownS = 0.0))
    trajectoryTask!(root, "stream test")
    trajectoryToolCall!(root, "send", "same")
    trajectoryToolCall!(root, "send", "same")
    for _ in 1:50
        CALLS[] > 0 && break
        sleep(0.1)
    end
    later(function ()
        report() do txt
            check("the Trajectory tab appears", occursin("\"tab\":true", txt), txt)
            check("…with the monitor's own reasoning/insight",
                  occursin("trajectory insight", txt) &&
                  occursin("trajectory monitor attached", txt), txt)
            stopTrajectoryMonitor!(root)
            finish()
        end
    end, 0.5)
end
later(() -> waitReady(0), 0.3)
Webviews.set_timeout(function (); println("watchdog"); finish() end, wv, 60.0)
L.runEventLoopAndTeardown!(wv)
