# chatMonitorPauseProbe.jl — the ROOT chat's pause actually reaches its monitor.
#
# The root chat's page info is CHAT_ONLY with juliaId:null. `reportChatInteraction`
# derived the session id from info.juliaId only, so every root-chat pause returned
# early: the Chat monitor tab stayed empty. This drives the REAL page path (type,
# wait for the 2 s pause timer) and asserts the monitor saw it.
#
# Run: julia --startup-file=no --project=. test/chatMonitorPauseProbe.jl  (opens a window)
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

calls = Ref(0)
CHAT_MONITOR_COMPLETE[] = _ -> (calls[] += 1;
    "{\"decision\":\"insight\",\"title\":\"Draft\",\"body\":\"the user wants a parser\"}")

wv = L.launchTerminalUI(chatOnly = true)
later(f, s = 0.25) = Webviews.set_timeout(f, wv, s)

function finish()
    try Webviews.close(wv) catch e; L.requestStopEventLoop!(wv) end
    println()
    if isempty(failures)
        println("CHAT_MONITOR_PAUSE_PROBE_OK")
    else
        println("FAILED CHECKS: ", join(failures, ", "))
        exit(1)
    end
    return nothing
end

function report(then)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__cmp__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        (function () {
            var info = chatTabs[CHAT_SESSION_ID] || CHAT_ONLY;
            window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__cmp__',
                text: JSON.stringify({
                    sid: CHAT_SESSION_ID,
                    value: assistCm ? assistCm.getValue() : null,
                    hasAssist: window.__hasAssist || 'unset',
                    setOk: window.__setOk || '',
                    setErr: window.__setErr || '',
                    traceCalls: window.__traceCalls || 0,
                    inputSeen: window.__inputSeen || 0,
                    chatOnly: info === CHAT_ONLY,
                    monitor: (info.monitorChat || []).map(function (m) {
                        return m.role + ':' + m.text; })
                }) })).catch(function () {});
        })();
    """)
    later(function ()
        txt = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__cmp__", ""),
                  L.TERMINAL_BUFFER_LOCK)
        then(txt)
    end, 0.15)
    return nothing
end

function poll(n)
    report() do txt
        if calls[] == 0 && n < 40
            return poll(n + 1)
        end
        check("the root chat's pause reaches its monitor", calls[] > 0, calls[])
        check("…and the Chat monitor stream is not empty",
              occursin("the user wants a parser", txt), first(txt, 300))
        check("…with an attachment line", occursin("monitor attached", txt),
              first(txt, 300))
        finish()
    end
    return nothing
end

function typeDraft()
    # A real input event: this starts the page's 2 s pause timer. The server
    # then reports idle_ms=2000 to the production `chatInteractionTrace!`.
    L.Webviews.eval!(wv, """
        window.__traceCalls = 0;
        window.__inputSeen = 0;
        if (typeof reportChatInteraction === 'function') {
            var _r = reportChatInteraction;
            reportChatInteraction = function (k) {
                window.__traceCalls++;
                return _r(k);
            };
        }
        window.__hasAssist = (typeof assistCm);
        try {
            assistCm.on('input', function () { window.__inputSeen++; });
            assistCm.setValue('I want a parser');
            window.__setOk = assistCm.getValue();
        } catch (e) { window.__setErr = String(e); }
    """)
    later(() -> poll(0), 3.2)
    return nothing
end

function waitReady(n)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__cmp_ready__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__cmp_ready__',
            text: String(typeof assistCm) })).catch(function(){});
    """)
    later(function ()
        ready = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__cmp_ready__", ""),
                     L.TERMINAL_BUFFER_LOCK) == "object"
        ready && return typeDraft()
        n > 100 && (check("the page became ready", false, n); return finish())
        waitReady(n + 1)
    end, 0.2)
    return nothing
end

later(() -> waitReady(0), 0.3)
Webviews.set_timeout(function (); println("watchdog"); finish() end, wv, 90.0)
L.runEventLoopAndTeardown!(wv)
