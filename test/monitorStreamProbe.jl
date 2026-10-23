# monitorStreamProbe.jl — the Monitor tab gets the monitor's OWN voice even
# when the model replies with reasoning only / no structured insight.
#
# Reported: "Monitor tab is empty; no monitoring messages." The chat monitor
# discarded thinking-only replies and observe decisions. It now forwards its
# reasoning and an observe line to the monitor stream.
#
# Run: julia --startup-file=no --project=. test/monitorStreamProbe.jl  (opens a window)
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

CHAT_MONITOR_COMPLETE[] = _ -> "<thinking>monitor reasoning only</thinking>"

wv = L.launchTerminalUI(chatOnly = true)
later(f, s = 0.25) = Webviews.set_timeout(f, wv, s)

function finish()
    try Webviews.close(wv) catch e; L.requestStopEventLoop!(wv) end
    println()
    if isempty(failures)
        println("MONITOR_STREAM_PROBE_OK")
    else
        println("FAILED CHECKS: ", join(failures, ", "))
        exit(1)
    end
    return nothing
end

function pageReport(then)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__ms__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        (function () {
            var info = chatTabs[CHAT_SESSION_ID] || CHAT_ONLY;
            window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__ms__',
                text: JSON.stringify({
                    monitor: (info.monitorChat || []).map(function (m) {
                        return m.role + ':' + m.text; }),
                    unread: info.monitorUnread || 0
                }) })).catch(function () {});
        })();
    """)
    tries = Ref(0)
    poll = function ()
        txt = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__ms__", ""), L.TERMINAL_BUFFER_LOCK)
        if isempty(txt) && tries[] < 40
            tries[] += 1
            return later(poll, 0.1)
        end
        then(txt)
    end
    later(poll, 0.1)
    return nothing
end

function waitReady(tries)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__ms_ready__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__ms_ready__',
            text: String(typeof window.flootyAddChatTab === 'function' &&
                         !!CHAT_SESSION_ID) })).catch(function(){});
    """)
    later(function ()
        ok = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__ms_ready__", ""),
                  L.TERMINAL_BUFFER_LOCK) == "true"
        ok && return trace()
        tries > 80 && (check("the page became ready", false, ""); return finish())
        waitReady(tries + 1)
    end, 0.2)
    return nothing
end

function trace()
    root = Flooty.ensureRootChatSession!()
    Flooty.chatInteractionTrace!(root.id, "pause", "run the parser tests", 3.0)
    later(verify, 0.8)
    return nothing
end

function verify()
    pageReport() do txt
        check("the monitor's reasoning reaches the Monitor stream",
              occursin("monitor reasoning only", txt), first(txt, 300))
        check("…and an observe decision is visible",
              occursin("observe", txt), first(txt, 300))
        check("…the monitor stream is not empty",
              !occursin("\"monitor\":[]", txt), first(txt, 300))
        # The chat monitor is a STANDING watcher (one task per session), not a
        # one-shot completion launched by the pause.
        root = Flooty.ensureRootChatSession!()
        m = Flooty.chatMonitorFor(root.id)
        check("…and runs as a standing task",
              m.task !== nothing && !istaskdone(m.task),
              m.task === nothing ? "no task" : string(istaskdone(m.task)))
        Flooty.stopChatMonitor!(root.id)
        finish()
    end
    return nothing
end

later(() -> waitReady(0), 0.5)
Webviews.set_timeout(function (); println("watchdog"); finish() end, wv, 120.0)
L.runEventLoopAndTeardown!(wv)
