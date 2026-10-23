# sshChooserProbe.jl — the SSH chooser actually prompts and creates the session.
#
# Reported: "Lets work on SSH session. It does nothing right now." WKWebView's
# UI delegate (Webviews) does not implement runJavaScriptTextInputPanelWithPrompt,
# so window.prompt returned nothing and chooseSession('ssh') exited. The chooser
# now uses an in-page promise dialog.
#
# Run: julia --startup-file=no --project=. test/sshChooserProbe.jl  (opens a window)
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
const SESS = Ref{Any}(nothing)

function finish()
    s = SESS[]
    s === nothing || (try L.closeSession!(s) catch e; nothing end)
    try Webviews.close(wv) catch e; L.requestStopEventLoop!(wv) end
    println()
    if isempty(failures)
        println("SSH_CHOOSER_PROBE_OK")
    else
        println("FAILED CHECKS: ", join(failures, ", "))
        exit(1)
    end
    return nothing
end

function pageReport(then)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__sc__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        (function () {
            var d = document.getElementById('promptDialog');
            window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__sc__',
                text: JSON.stringify({
                    promptVisible: d ? !d.hidden : null,
                    title: (document.getElementById('promptTitle') || {}).textContent || '',
                    terms: Object.keys(terminals).map(function (k) {
                        return (terminals[k] || {}).name || ''; })
                }) })).catch(function () {});
        })();
    """)
    tries = Ref(0)
    poll = function ()
        txt = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__sc__", ""), L.TERMINAL_BUFFER_LOCK)
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
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__sc_ready__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__sc_ready__',
            text: String(typeof openSessionChooser === 'function' &&
                         typeof flootyPrompt === 'function' &&
                         !!CHAT_SESSION_ID) })).catch(function(){});
    """)
    later(function ()
        ok = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__sc_ready__", ""),
                  L.TERMINAL_BUFFER_LOCK) == "true"
        ok && return openChooser()
        tries > 80 && (check("the page became ready", false, ""); return finish())
        waitReady(tries + 1)
    end, 0.2)
    return nothing
end

function openChooser()
    L.Webviews.eval!(wv, "openSessionChooser('root');")
    later(function ()
        L.Webviews.eval!(wv,
            "document.querySelector('#sessionChooser [data-session-kind=\"ssh\"]').click();")
        later(checkPrompt, 0.4)
    end, 0.3)
    return nothing
end

function checkPrompt()
    pageReport() do txt
        check("the SSH chooser opens an in-page prompt",
              occursin("\"promptVisible\":true", txt), txt)
        check("…labelled for an SSH target",
              occursin("SSH target", txt), txt)
        # Type the target and confirm (the real path the user takes).
        L.Webviews.eval!(wv, """
            (function () {
                var input = document.getElementById('promptInput');
                input.value = '127.0.0.1';
                input.dispatchEvent(new KeyboardEvent('keydown',
                    { key: 'Enter', bubbles: true }));
            })();
        """)
        waitSession(0)
    end
    return nothing
end

function waitSession(tries)
    ids = lock(() -> collect(keys(L.OWNERSHIP_SESSIONS)), L.OWNERSHIP_SESSIONS_LOCK)
    if isempty(ids)
        tries > 80 && (check("the SSH terminal was created", false, ""); return finish())
        return later(() -> waitSession(tries + 1), 0.2)
    end
    sid = ids[end]
    SESS[] = L.OWNERSHIP_SESSIONS[sid]
    ts = Flooty.sessionForId(sid)
    check("the SSH terminal was created", ts !== nothing, sid)
    check("…kind=:ssh", ts isa Flooty.TerminalSession && ts.kind === :ssh,
          string(ts isa Flooty.TerminalSession ? ts.kind : "?"))
    check("…remote=127.0.0.1",
          ts isa Flooty.TerminalSession && ts.remote == "127.0.0.1",
          string(ts isa Flooty.TerminalSession ? ts.remote : "?"))
    pageReport() do txt
        check("…with a tab named for the target",
              occursin("ssh 127.0.0.1", txt), first(txt, 200))
        finish()
    end
    return nothing
end

later(() -> waitReady(0), 0.5)
Webviews.set_timeout(function (); println("watchdog"); finish() end, wv, 120.0)
L.runEventLoopAndTeardown!(wv)
