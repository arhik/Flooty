# contextStatusProbe.jl — the status bar shows a context-window meter.
#
# The agent loop already computes `contextUsage` each turn but only wrote it to
# the transcript. It is now an AgentContextUsageEvent routed to the owning tab,
# and the status bar renders a small bar + `ctx 12.3k / 100.0k (12%)` for the
# ACTIVE session.
#
# Run: julia --startup-file=no --project=. test/contextStatusProbe.jl  (opens a window)
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

function finish()
    try Webviews.close(wv) catch e; L.requestStopEventLoop!(wv) end
    println()
    if isempty(failures)
        println("CONTEXT_STATUS_PROBE_OK")
    else
        println("FAILED CHECKS: ", join(failures, ", "))
        exit(1)
    end
    return nothing
end

function meter(then)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__ctx__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        (function () {
            var el = document.getElementById('contextUsage');
            var fill = document.getElementById('contextUsageFill');
            var text = document.getElementById('contextUsageText');
            window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__ctx__',
                text: JSON.stringify({
                    hidden: !!(el && el.hidden),
                    text: text ? text.textContent : '',
                    width: fill ? fill.style.width : '',
                    cls: fill ? fill.className : '',
                    title: el ? el.title : ''
                }) })).catch(function(){});
        })();
    """)
    later(function ()
        txt = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__ctx__", ""),
                  L.TERMINAL_BUFFER_LOCK)
        then(txt)
    end, 0.1)
    return nothing
end

function waitReady(n)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__ctx_ready__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__ctx_ready__',
            text: String(typeof handleAgentEvent === 'function' && !!CHAT_SESSION_ID) }))
            .catch(function(){});
    """)
    later(function ()
        ready = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__ctx_ready__", ""),
                     L.TERMINAL_BUFFER_LOCK) == "true"
        ready && return publish()
        n > 80 && (check("the page became ready", false, ""); return finish())
        waitReady(n + 1)
    end, 0.2)
    return nothing
end

function publish()
    sid = Flooty.ensureRootChatSession!().id
    L.pushAgentEventToWindow(wv, L.AgentContextUsageEvent(sid, 12345, 100000))
    later(verifyNormal, 0.4)
    return nothing
end

function verifyNormal()
    meter() do txt
        check("the context meter is visible", occursin("\"hidden\":false", txt), txt)
        check("…with tokens / limit / percent",
              occursin("ctx 12.3k / 100.0k (12%)", txt), txt)
        check("…and a proportional fill bar", occursin("\"width\":\"12.3%\"", txt), txt)
        check("…and a tooltip with exact numbers",
              occursin("12345 / 100000", txt), txt)
        # Near the 85% compaction threshold the visual changes.
        sid = Flooty.ensureRootChatSession!().id
        L.pushAgentEventToWindow(wv, L.AgentContextUsageEvent(sid, 92000, 100000))
        later(verifyHot, 0.4)
    end
    return nothing
end

function verifyHot()
    meter() do txt
        check("high usage fills the bar to 92%", occursin("\"width\":\"92%\"", txt), txt)
        check("…and turns the meter hot", occursin("\"cls\":\"hot\"", txt), txt)
        check("…with 92% in the label", occursin("(92%)", txt), txt)
        finish()
    end
    return nothing
end

later(() -> waitReady(0), 0.3)
Webviews.set_timeout(function (); println("watchdog"); finish() end, wv, 60.0)
L.runEventLoopAndTeardown!(wv)
