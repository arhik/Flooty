# closeActiveProbe.jl — Ctrl+Shift+W closes the ACTIVE session.
#
# The old handler closed `activeTerminalId` unconditionally. Chat/browser tabs
# did not clear that pointer, so the shortcut killed a stale terminal tab while
# a chat tab was focused. It now closes the active chat, split, or terminal.
#
# Run: julia --startup-file=no --project=. test/closeActiveProbe.jl  (opens a window)
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
ROOT = Ref{Any}(nothing)
CHILD = Ref{Any}(nothing)
TERM = Ref("")

function finish()
    try Webviews.close(wv) catch e; L.requestStopEventLoop!(wv) end
    println()
    if isempty(failures)
        println("CLOSE_ACTIVE_PROBE_OK")
    else
        println("FAILED CHECKS: ", join(failures, ", "))
        exit(1)
    end
    return nothing
end

function waitReady(n)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__ca_ready__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__ca_ready__',
            text: String(typeof closeActiveSession === 'function' && !!CHAT_SESSION_ID) }))
            .catch(function(){});
    """)
    later(function ()
        ok = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__ca_ready__", ""),
                  L.TERMINAL_BUFFER_LOCK) == "true"
        ok && return createTerminal()
        n > 80 && (check("the page became ready", false, ""); return finish())
        waitReady(n + 1)
    end, 0.2)
    return nothing
end

function createTerminal()
    ROOT[] = ensureRootChatSession!()
    L.Webviews.eval!(wv, "createTerminal({ name: 'only' });")
    waitTerminal(0)
    return nothing
end

function waitTerminal(n)
    ids = lock(() -> collect(keys(L.OWNERSHIP_SESSIONS)), L.OWNERSHIP_SESSIONS_LOCK)
    if isempty(ids) && n < 60
        return later(() -> waitTerminal(n + 1), 0.2)
    end
    check("the terminal exists", !isempty(ids), ids)
    TERM[] = isempty(ids) ? "" : ids[end]
    CHILD[] = launchChildChat!(ROOT[].id; name = "active-chat")
    later(function ()
        report() do txt
            check("the child chat is active", occursin("\"activeChat\":\"$(CHILD[].id)\"", txt), txt)
            check("…and no stale terminal is active", occursin("\"activeTerm\":null", txt), txt)
            dispatchClose()
            later(verifyChatClosed, 0.8)
        end
    end, 0.4)
    return nothing
end

function report(then)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__ca__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        (function () {
            window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__ca__',
                text: JSON.stringify({
                    terms: Object.keys(terminals).length,
                    activeTerm: activeTerminalId,
                    activeChat: activeChatId,
                    child: !!chatTabs["$(CHILD[].id)"]
                }) })).catch(function(){});
        })();
    """)
    later(function ()
        txt = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__ca__", ""), L.TERMINAL_BUFFER_LOCK)
        then(txt)
    end, 0.15)
    return nothing
end

function dispatchClose()
    L.Webviews.eval!(wv, """
        document.dispatchEvent(new KeyboardEvent('keydown',
            { key: 'W', code: 'KeyW', ctrlKey: true, shiftKey: true, bubbles: true }));
    """)
end

function verifyChatClosed()
    report() do txt
        check("the active chat closed", !occursin("\"child\":true", txt), txt)
        check("…without closing the terminal", occursin("\"terms\":1", txt), txt)
        check("…and the chat left the session tree", sessionForId(CHILD[].id) === nothing,
              CHILD[].id)
        # Primary root chat is active now; the same shortcut is a no-op.
        dispatchClose()
        later(verifyRootNoop, 0.4)
    end
    return nothing
end

function verifyRootNoop()
    report() do txt
        check("Ctrl+Shift+W on the permanent root chat is a no-op",
              occursin("\"terms\":1", txt) &&
              occursin("\"activeChat\":\"$(ROOT[].id)\"", txt), txt)
        # Focus the terminal and close exactly it.
        L.Webviews.eval!(wv, """
            var target = null;
            for (var k in terminals)
                if (terminals[k].juliaId === "$(TERM[])") target = k;
            if (target) switchToTerminal(target);
        """)
        later(verifyTerminalClosed, 0.3)
    end
    return nothing
end

function verifyTerminalClosed()
    dispatchClose()
    later(function ()
        check("the active terminal closed",
              sessionForId(TERM[]) === nothing, TERM[])
        check("…and its page tab is gone",
              isempty(lock(() -> collect(keys(L.OWNERSHIP_SESSIONS)),
                           L.OWNERSHIP_SESSIONS_LOCK)),
              "")
        finish()
    end, 0.5)
    return nothing
end

later(() -> waitReady(0), 0.3)
Webviews.set_timeout(function (); println("watchdog"); finish() end, wv, 120.0)
L.runEventLoopAndTeardown!(wv)
