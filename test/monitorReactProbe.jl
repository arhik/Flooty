# monitorReactProbe.jl — a real PTY command produces a VISIBLE monitor reaction.
#
# Reported: "monitoring is still not reacting." This drives the UI path: the
# session's ambient monitor is given a deterministic insight completion, a
# `sleep` command runs in the terminal, and the page must receive the monitor
# insight (Monitor stream + popup bridge) after the long-run threshold.
#
# Run: julia --startup-file=no --project=. test/monitorReactProbe.jl  (opens a window)
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
        println("MONITOR_REACT_PROBE_OK")
    else
        println("FAILED CHECKS: ", join(failures, ", "))
        exit(1)
    end
    return nothing
end

function report(then)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__mr__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        (function () {
            var info = terminals[activeTerminalId] || {};
            window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__mr__',
                text: JSON.stringify({
                    monitor: (info.monitorChat || []).map(function (m) {
                        return m.role + ':' + m.text; }),
                    terminalMonitor: (info.terminalMonitorChat || []).map(function (m) {
                        return m.role + ':' + m.text; }),
                    popups: (info.popups || []).map(function (p) {
                        return p.title + ':' + p.body; })
                }) })).catch(function () {});
        })();
    """)
    tries = Ref(0)
    poll = function ()
        txt = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__mr__", ""), L.TERMINAL_BUFFER_LOCK)
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
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__mr_ready__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__mr_ready__',
            text: String(typeof createTerminal === 'function') })).catch(function(){});
    """)
    later(function ()
        ok = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__mr_ready__", ""),
                  L.TERMINAL_BUFFER_LOCK) == "true"
        ok && return createTerminal()
        tries > 80 && (check("the page became ready", false, ""); return finish())
        waitReady(tries + 1)
    end, 0.2)
    return nothing
end

function createTerminal()
    L.Webviews.eval!(wv, "createTerminal({ name: 'monitor' });")
    waitSession(0)
    return nothing
end

function waitSession(tries)
    sess = lock(() -> isempty(L.OWNERSHIP_SESSIONS) ? nothing :
                     first(values(L.OWNERSHIP_SESSIONS)), L.OWNERSHIP_SESSIONS_LOCK)
    if sess === nothing
        tries > 80 && (check("the terminal appeared", false, ""); return finish())
        return later(() -> waitSession(tries + 1), 0.2)
    end
    runCommand(sess)
    return nothing
end

function runCommand(sess)
    st = lock(() -> get(Flooty.MONITOR_STATES, sess, nothing),
              Flooty.MONITOR_STATES_LOCK)
    if st === nothing
        check("the session has a monitor", false, "")
        return finish()
    end
    st.completeFn = _ -> "{\"decision\":\"insight\",\"title\":\"Still running\"," *
                         "\"body\":\"the command is still running\"}"
    st.cfg.interjectAfterS = 0.5
    L.userWrite(sess, "sleep 6\n")
    later(() -> verify(0), 1.2)
    return nothing
end

function verify(tries)
    report() do txt
        if occursin("still running", txt) || tries >= 20
            check("the monitor insight reaches the Terminal monitor stream",
                  occursin("the command is still running", txt), first(txt, 400))
            check("the monitor insight reaches the popup bridge",
                  occursin("Still running", txt), first(txt, 400))
            return finish()
        end
        later(() -> verify(tries + 1), 0.25)
    end
    return nothing
end

later(() -> waitReady(0), 0.5)
Webviews.set_timeout(function (); println("watchdog"); finish() end, wv, 150.0)
L.runEventLoopAndTeardown!(wv)
