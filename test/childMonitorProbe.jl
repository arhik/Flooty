# childMonitorProbe.jl — a split child's monitor reports into the parent arena.
#
# A child has its own monitor, but its pane has no tab/stream. Its terminal
# events were landing in the hidden child info. They now target the parent
# Terminal monitor stream while agent notes still go to the child driver.
#
# Run: julia --startup-file=no --project=. test/childMonitorProbe.jl  (opens a window)
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
PARENT = Ref{Any}(nothing)
CHILD = Ref{Any}(nothing)

function finish()
    try Webviews.close(wv) catch e; L.requestStopEventLoop!(wv) end
    println()
    if isempty(failures)
        println("CHILD_MONITOR_PROBE_OK")
    else
        println("FAILED CHECKS: ", join(failures, ", ")); exit(1)
    end
end
function report(then)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__cm__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        (function () {
            var info = null;
            for (var k in terminals)
                if (terminals[k].juliaId === "$(L.sessionIdFor(PARENT[]))") info = terminals[k];
            window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__cm__',
                text: JSON.stringify({
                    monitor: info ? (info.terminalMonitorChat || []).map(function (m) {
                        return m.role + ':' + m.text; }) : null
                }) })).catch(function(){});
        })();
    """)
    later(function ()
        then(lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__cm__", ""),
                  L.TERMINAL_BUFFER_LOCK))
    end, 0.15)
end
function waitReady(n)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__cm_ready__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__cm_ready__',
            text: String(typeof splitTerminal === 'function' && !!CHAT_SESSION_ID) }))
            .catch(function(){});
    """)
    later(function ()
        ok = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__cm_ready__", ""),
                  L.TERMINAL_BUFFER_LOCK) == "true"
        ok && return makeSplit()
        n > 80 && (check("page ready", false, ""); return finish())
        waitReady(n + 1)
    end, 0.2)
end
function makeSplit()
    L.Webviews.eval!(wv, "createTerminal({ name: 'parent' });")
    later(function ()
        ids = lock(() -> collect(keys(L.OWNERSHIP_SESSIONS)), L.OWNERSHIP_SESSIONS_LOCK)
        isempty(ids) && return later(makeSplit, 0.2)
        PARENT[] = L.OWNERSHIP_SESSIONS[ids[end]]
        L.Webviews.eval!(wv, "splitTerminal('vertical');")
        later(startChild, 0.5)
    end, 0.4)
end
function startChild(n = 0)
    CHILD[] = L.splitSession()
    if CHILD[] === nothing && n < 40
        return later(() -> startChild(n + 1), 0.2)
    end
    check("the split child exists", CHILD[] !== nothing)
    check("…and has a parent mapping", L.splitParentSession(CHILD[]) === PARENT[],
          L.splitParentSession(CHILD[]) === nothing ? "none" : "parent")
    sleep(0.3)
    L.tagIn(CHILD[].control; mode = :agent)
    stopMonitor!(CHILD[])
    startMonitor!(CHILD[];
        completeFn = _ -> "{\"decision\":\"insight\",\"title\":\"Child\"," *
                          "\"body\":\"child terminal ok\"}",
        cfg = MonitorConfig(pollS = 0.1, interjectAfterS = 30.0,
                            eventCooldownS = 0.0))
    sleep(0.3)
    L.userWrite(CHILD[], "echo CHILD_EVENT\n")
    for _ in 1:50
        report() do txt
            if occursin("child terminal ok", txt)
                check("the child monitor reports into the parent Terminal stream", true, txt)
                notes = takeMonitorNotes!(PARENT[])
                check("…and its insight reaches the parent driver's note channel",
                      any(n -> occursin("child terminal ok", n), notes), notes)
                finish()
            elseif n < 50
                return later(() -> verify(0), 0.15)
            else
                check("the child monitor reports into the parent Terminal stream", false, txt)
                finish()
            end
        end
        break
    end
    return nothing
end
function verify(n)
    report() do txt
        if occursin("child terminal ok", txt)
            check("the child monitor reports into the parent Terminal stream", true, txt)
            finish()
        elseif n < 50
            return later(() -> verify(n + 1), 0.1)
        else
            check("the child monitor reports into the parent Terminal stream", false, txt)
            finish()
        end
    end
end
later(() -> waitReady(0), 0.3)
Webviews.set_timeout(function (); println("watchdog"); finish() end, wv, 90.0)
L.runEventLoopAndTeardown!(wv)
