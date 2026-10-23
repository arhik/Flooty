# browserWindowProbe.jl — a BrowserSession opens REAL sites (github.com).
#
# The in-app panel is an iframe; GitHub sends X-Frame-Options and refuses it.
# BrowserSession now also opens a native WKWebView window (top-level, so no
# framing restrictions). This probe opens the session, navigates github.com,
# and reads the page title back through the window's init binding.
#
# Run: julia --startup-file=no --project=. test/browserWindowProbe.jl  (opens 2 windows)
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
const SID = Ref("")

function finish()
    L.closeAllBrowserWindows!()
    try Webviews.close(wv) catch e; L.requestStopEventLoop!(wv) end
    println()
    if isempty(failures)
        println("BROWSER_WINDOW_PROBE_OK")
    else
        println("FAILED CHECKS: ", join(failures, ", "))
        exit(1)
    end
    return nothing
end

function waitReady(tries)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__bw_ready__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__bw_ready__',
            text: String(typeof window.flootyAddBrowserTab === 'function' &&
                         !!CHAT_SESSION_ID) })).catch(function(){});
    """)
    later(function ()
        ok = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__bw_ready__", ""),
                  L.TERMINAL_BUFFER_LOCK) == "true"
        ok && return openSession()
        tries > 80 && (check("the page became ready", false, ""); return finish())
        waitReady(tries + 1)
    end, 0.2)
    return nothing
end

function openSession()
    sess = Flooty.launchBrowserSession!(url = "about:blank", name = "probe")
    SID[] = sess.id
    waitWindow(0)
    return nothing
end

function waitWindow(tries)
    if L.browserWindowOpen(SID[])
        return navigate()
    end
    tries > 60 && (check("the native browser window opened", false, ""); return finish())
    later(() -> waitWindow(tries + 1), 0.2)
    return nothing
end

function navigate()
    # Drive it the way the USER does: the URL bar → page → bound Julia handler
    # → native window (not the layer function directly).
    L.Webviews.eval!(wv, "browserNavigateActive('https://github.com');")
    waitTitle(0)
    return nothing
end

function waitAgentTitle(tries)
    info = L.browserWindowInfo(SID[])
    if occursin("Example Domain", info.title)
        check("the agent's navigate action reaches the native window",
              occursin("example.com", info.url), info)
        L.closeBrowserWindow!(SID[])
        check("closing the native window unregisters it", !L.browserWindowOpen(SID[]), "")
        return finish()
    end
    if tries >= 60
        check("the agent's navigate action reaches the native window", false, info)
        return finish()
    end
    later(() -> waitAgentTitle(tries + 1), 0.25)
    return nothing
end

function waitTitle(tries)
    info = L.browserWindowInfo(SID[])
    if occursin("GitHub", info.title)
        check("the native window is visible", info.shown, info)
        check("github.com loaded in the native window",
              occursin("GitHub", info.title) && occursin("github.com", info.url), info)
        # The AGENT's navigate action goes through AgentBrowserNavigateEvent.
        L.pushAgentEventToWindow(wv,
            L.AgentBrowserNavigateEvent(SID[], "https://example.com"))
        return waitAgentTitle(0)
    end
    if tries >= 80
        check("github.com loaded in the native window", false, info)
        return finish()
    end
    later(() -> waitTitle(tries + 1), 0.25)
    return nothing
end

later(() -> waitReady(0), 0.5)
Webviews.set_timeout(function (); println("watchdog"); finish() end, wv, 90.0)
L.runEventLoopAndTeardown!(wv)
