# chatSwitchProbe.jl — switching sessions switches the CHAT SURFACE.
#
# Reported: "chat is not switching on session switch properly." The renderer
# keyed its cache on `activeTerminalId`, which a chat/browser tab does not
# change; terminal -> chat -> terminal reused the key and appended the chat
# tab's transcript to the terminal's (and vice versa).
#
# Run: julia --startup-file=no --project=. test/chatSwitchProbe.jl  (opens a window)
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

const MARKER = "MARKER_FROM_CHAT_TAB"
const TID = Ref("")

wv = L.launchTerminalUI(chatOnly = true)
later(f, s = 0.25) = Webviews.set_timeout(f, wv, s)

function finish()
    try Webviews.close(wv) catch e; L.requestStopEventLoop!(wv) end
    println()
    if isempty(failures)
        println("CHAT_SWITCH_PROBE_OK")
    else
        println("FAILED CHECKS: ", join(failures, ", "))
        exit(1)
    end
    return nothing
end

function report(then)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__cs__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        (function () {
            window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__cs__',
                text: JSON.stringify({
                    dom: document.getElementById('agentChatLog').textContent,
                    draft: (typeof assistCm !== 'undefined' && assistCm)
                        ? assistCm.getValue() : '',
                    activeChat: activeChatId,
                    activeBrowser: activeBrowserId,
                    activeTerm: activeTerminalId,
                    terminals: Object.keys(terminals)
                }) })).catch(function () {});
        })();
    """)
    tries = Ref(0)
    poll = function ()
        txt = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__cs__", ""), L.TERMINAL_BUFFER_LOCK)
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
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__cs_ready__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__cs_ready__',
            text: String(typeof createTerminal === 'function' && !!CHAT_SESSION_ID) }))
            .catch(function(){});
    """)
    later(function ()
        ok = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__cs_ready__", ""),
                  L.TERMINAL_BUFFER_LOCK) == "true"
        ok && return createTerminal()
        tries > 80 && (check("the page became ready", false, ""); return finish())
        waitReady(tries + 1)
    end, 0.2)
    return nothing
end

function createTerminal()
    L.Webviews.eval!(wv, "createTerminal({ name: 'parent' });")
    waitSession(0)
    return nothing
end

function waitSession(tries)
    ids = lock(() -> collect(keys(L.OWNERSHIP_SESSIONS)), L.OWNERSHIP_SESSIONS_LOCK)
    if isempty(ids)
        tries > 80 && (check("the terminal appeared", false, ""); return finish())
        return later(() -> waitSession(tries + 1), 0.2)
    end
    report() do txt
        m = match(r"\"terminals\":\[\"([^\"]+)\"\]", txt)
        if m === nothing
            check("the page knows the terminal", false, txt)
            return finish()
        end
        TID[] = m.captures[1]
        later(openChat, 0.3)
    end
    return nothing
end

function openChat()
    L.Webviews.eval!(wv, """
        flootyAddChatTab('chat-switch', 'child chat', CHAT_SESSION_ID,
                         terminals[$(repr(TID[]))].juliaId);
    """)
    later(pushMarker, 0.3)
    return nothing
end

function pushMarker()
    L.pushAgentEventToWindow(wv, L.AgentTextEvent("chat-switch", MARKER))
    later(verifyChat, 0.5)
    return nothing
end

function verifyChat()
    report() do txt
        check("the chat tab is active", occursin("\"activeChat\":\"chat-switch\"", txt), txt)
        check("the chat tab shows its message", occursin(MARKER, txt), first(txt, 300))
        L.Webviews.eval!(wv, "assistCm.setValue('DRAFT_FOR_CHAT');")
        L.Webviews.eval!(wv, "switchToTerminal($(repr(TID[])));")
        later(verifyTerminal, 0.5)
    end
    return nothing
end

function verifyTerminal()
    report() do txt
        check("the terminal is active", occursin("\"activeChat\":null", txt), txt)
        check("the terminal transcript does NOT contain the chat tab's message",
              !occursin(MARKER, txt), first(txt, 300))
        check("the terminal gets its OWN (empty) draft",
              occursin("\"draft\":\"\"", txt), first(txt, 300))
        L.Webviews.eval!(wv, "assistCm.setValue('DRAFT_FOR_TERM');")
        L.Webviews.eval!(wv, "activateChatTab('chat-switch');")
        later(verifyBack, 0.5)
    end
    return nothing
end

function verifyBack()
    report() do txt
        check("switching back restores the chat tab transcript",
              occursin(MARKER, txt), first(txt, 300))
        check("switching back restores the chat tab's draft",
              occursin("\"draft\":\"DRAFT_FOR_CHAT\"", txt), first(txt, 300))
        L.Webviews.eval!(wv, "switchToTerminal($(repr(TID[])));")
        later(verifyTerminalDraft, 0.5)
    end
    return nothing
end

function verifyTerminalDraft()
    report() do txt
        check("switching back restores the terminal's draft",
              occursin("\"draft\":\"DRAFT_FOR_TERM\"", txt), first(txt, 300))
        L.Webviews.eval!(wv, """
            flootyAddBrowserTab('browser-switch', 'browser', 'about:blank',
                                CHAT_SESSION_ID, null);
        """)
        later(pushBrowser, 0.3)
    end
    return nothing
end

function pushBrowser()
    L.pushAgentEventToWindow(wv, L.AgentTextEvent("browser-switch", "BROWSER_MARKER"))
    later(verifyBrowser, 0.5)
    return nothing
end

function verifyBrowser()
    report() do txt
        check("the browser tab is active",
              occursin("\"activeBrowser\":\"browser-switch\"", txt), txt)
        check("the browser tab shows its message",
              occursin("BROWSER_MARKER", txt), first(txt, 300))
        L.Webviews.eval!(wv, "switchToTerminal($(repr(TID[])));")
        later(verifyBrowserGone, 0.5)
    end
    return nothing
end

function verifyBrowserGone()
    report() do txt
        check("the terminal transcript does NOT contain the browser's message",
              !occursin("BROWSER_MARKER", txt), first(txt, 300))
        L.Webviews.eval!(wv, "activateBrowserTab('browser-switch');")
        later(verifyBrowserBack, 0.5)
    end
    return nothing
end

function verifyBrowserBack()
    report() do txt
        check("switching back restores the browser transcript",
              occursin("BROWSER_MARKER", txt), first(txt, 300))
        finish()
    end
    return nothing
end

later(() -> waitReady(0), 0.5)
Webviews.set_timeout(function (); println("watchdog"); finish() end, wv, 120.0)
L.runEventLoopAndTeardown!(wv)
