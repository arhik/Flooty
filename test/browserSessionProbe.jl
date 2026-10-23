# browserSessionProbe.jl — a first-class BROWSER session.
#
#   * the session has its own browser tab/panel and chat rail;
#   * the assist box drives it; a navigate action moves the panel iframe;
#   * the session URL follows the page and the rail nests under Chat.
#
# Run: julia --startup-file=no --project=. test/browserSessionProbe.jl  (opens a window)
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
BROWSER_COMPLETE[] = _ -> begin
    calls[] += 1
    calls[] == 1 ? "{\"action\":\"navigate\",\"url\":\"https://example.com\"}" :
                   "{\"reply\":\"example is open\"}"
end

wv = L.launchTerminalUI(chatOnly = true)
later(f, s = 0.25) = Webviews.set_timeout(f, wv, s)
const SESS = Ref{Any}(nothing)

function finish()
    try Webviews.close(wv) catch e; L.requestStopEventLoop!(wv) end
    println()
    if isempty(failures)
        println("BROWSER_SESSION_PROBE_OK")
    else
        println("FAILED CHECKS: ", join(failures, ", "))
        exit(1)
    end
    return nothing
end

function pageReport(then)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__br__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        (function () {
            var ws = document.querySelector('.workspace');
            var panel = document.getElementById('browserPanel');
            var frame = document.getElementById('browserFrame');
            var url = document.getElementById('browserUrl');
            window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__br__',
                text: JSON.stringify({
                    sessions: Object.keys(browserTabs),
                    active: activeBrowserId,
                    focus: ws.classList.contains('browser-focus'),
                    panelHidden: panel ? !!panel.hidden : null,
                    frame: frame ? frame.getAttribute('src') : null,
                    url: url ? url.value : null,
                    chat: (browserTabs[activeBrowserId] || {}).chat || [],
                    rail: Array.from(document.querySelectorAll('#terminal-tabs .root-icon, #childTabs .child-tab'))
                        .map(function (t) { return { text: t.textContent.trim(),
                            cls: t.className }; })
                }) })).catch(function () {});
        })();
    """)
    tries = Ref(0)
    poll = function ()
        txt = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__br__", ""), L.TERMINAL_BUFFER_LOCK)
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
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__br_ready__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__br_ready__',
            text: String(typeof window.flootyAddBrowserTab === 'function' &&
                         typeof submitAssist === 'function') })).catch(function(){});
    """)
    later(function ()
        ok = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__br_ready__", ""),
                  L.TERMINAL_BUFFER_LOCK) == "true"
        ok && return createBrowser()
        tries > 80 && (check("the page became ready", false, ""); return finish())
        waitReady(tries + 1)
    end, 0.2)
    return nothing
end

function createBrowser()
    SESS[] = Flooty.launchBrowserSession!("";
        url = "about:blank", name = "Browser")
    check("a BrowserSession was created", SESS[] isa Flooty.BrowserSession,
          string(typeof(SESS[])))
    check("…a ROOT browser session", SESS[].parent === nothing,
          string(SESS[].parent))
    later(() -> waitPanel(0), 0.3)
    return nothing
end

function waitPanel(tries)
    pageReport() do txt
        if occursin(SESS[].id, txt) || tries > 40
            check("the browser tab is present", occursin(SESS[].id, txt), first(txt, 240))
            check("…and active with the browser panel visible",
                  occursin("\"focus\":true", txt) &&
                  occursin("\"panelHidden\":false", txt), first(txt, 300))
            check("…with a URL bar",
                  occursin("\"url\":\"about:blank\"", txt), first(txt, 300))
            check("…as an active ROOT icon",
                  occursin("root-icon active", txt), first(txt, 360))
            L.Webviews.eval!(wv,
                "assistCm.setValue(\"go to example.com\"); submitAssist();")
            later(() -> waitNavigate(0), 0.5)
            return nothing
        end
        later(() -> waitPanel(tries + 1), 0.15)
        return nothing
    end
    return nothing
end

function waitNavigate(tries)
    if SESS[].url == "https://example.com" || tries > 80
        check("the driver's navigate action moved the session URL",
              SESS[].url == "https://example.com", SESS[].url)
        # The page event is async; wait for the iframe to follow.
        waitFrame(0)
        return nothing
    end
    later(() -> waitNavigate(tries + 1), 0.15)
    return nothing
end

function waitFrame(tries)
    pageReport() do txt
        if occursin("browser failed", txt) || occursin("https://example.com", txt) || tries > 40
            check("…and the browser iframe", occursin("https://example.com", txt),
                  first(txt, 600))
            L.Webviews.eval!(wv,
                "assistCm.setValue(\"is it open?\"); submitAssist();")
            later(() -> waitReply(0), 0.5)
            return nothing
        end
        later(() -> waitFrame(tries + 1), 0.15)
        return nothing
    end
    return nothing
end

function waitReply(tries)
    tr = join(Flooty.conversationTranscript(
        Flooty.conversationFor(SESS[].id)), "\n")
    if occursin("example is open", tr) || tries > 80
        check("the browser chat rail got the reply",
              occursin("example is open", tr), first(tr, 240))
        check("…and the rail has the user's instruction",
              occursin("go to example.com", tr), "")
        finish()
        return nothing
    end
    later(() -> waitReply(tries + 1), 0.15)
    return nothing
end

later(() -> waitReady(0), 0.5)
Webviews.set_timeout(function (); println("watchdog"); finish() end, wv, 120.0)
L.runEventLoopAndTeardown!(wv)
