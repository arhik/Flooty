# thinkingWidthProbe.jl — reasoning occupies the chat pane's full width.
#
# Reported: "thinking in driver agent is not spanning the chat window" /
# "width is not occupying the available space." A flex item with
# align-items:flex-start shrinks to its content; max-width:100% only caps it.
# The thinking bubble now sets width:100%.
#
# Run: julia --startup-file=no --project=. test/thinkingWidthProbe.jl  (opens a window)
import FlootyPTYLayer
import Webviews
using Flooty
const L = FlootyPTYLayer

failures = String[]
check(name, ok, detail = "") = begin
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
        println("THINKING_WIDTH_PROBE_OK")
    else
        println("FAILED CHECKS: ", join(failures, ", "))
        exit(1)
    end
    return nothing
end

function report(then)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__tw__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        (function () {
            var el = document.getElementById('agentChatLog');
            var b = el.querySelector('.role-thinking .chat-bubble');
            var m = el.querySelector('.role-thinking');
            window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__tw__',
                text: JSON.stringify({
                    log: el.clientWidth,
                    row: m ? Math.round(m.getBoundingClientRect().width) : -1,
                    bubble: b ? Math.round(b.getBoundingClientRect().width) : -1,
                    text: b ? b.textContent : '',
                    ws: b ? getComputedStyle(b).whiteSpace : '',
                    pCount: b ? b.querySelectorAll('p').length : 0,
                    liCount: b ? b.querySelectorAll('li').length : 0,
                    html: b ? b.innerHTML : ''
                }) })).catch(function () {});
        })();
    """)
    tries = Ref(0)
    poll = function ()
        txt = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__tw__", ""), L.TERMINAL_BUFFER_LOCK)
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
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__tw_ready__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__tw_ready__',
            text: String(typeof window.flootyAddChatTab === 'function' &&
                         !!CHAT_SESSION_ID) })).catch(function(){});
    """)
    later(function ()
        ok = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__tw_ready__", ""),
                  L.TERMINAL_BUFFER_LOCK) == "true"
        ok && return pushThought()
        tries > 80 && (check("the page became ready", false, ""); return finish())
        waitReady(tries + 1)
    end, 0.2)
    return nothing
end

function pushThought()
    root = Flooty.ensureRootChatSession!()
    L.pushAgentEventToWindow(wv, L.AgentThinkingEvent(root.id,
        "First paragraph with *stars* and _underscores_.\n\n" *
        "- one\n- two\n\n```\ncode line\n```\n\nLast line."))
    later(verify, 0.5)
    return nothing
end

function verify()
    report() do txt
        if !occursin("\"bubble\":", txt)
            check("the thinking message rendered", false, txt)
            return finish()
        end
        m = match(r"\"log\":(\d+)", txt)
        b = match(r"\"bubble\":(\d+)", txt)
        ok = m !== nothing && b !== nothing &&
             parse(Int, b.captures[1]) >= parse(Int, m.captures[1]) - 26
        check("a short thinking occupies the chat pane's width", ok, txt)
        check("markdown blocks render as blocks (no pre-wrap newlines)",
              occursin("\"ws\":\"normal\"", txt) &&
              occursin("\"pCount\":", txt) && occursin("\"liCount\":2", txt),
              first(txt, 500))
        finish()
    end
    return nothing
end

later(() -> waitReady(0), 0.5)
Webviews.set_timeout(function (); println("watchdog"); finish() end, wv, 120.0)
L.runEventLoopAndTeardown!(wv)
