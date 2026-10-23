# sshChatMonitorProbe.jl — the CHAT monitor runs for an SSH terminal session.
#
# Chat is a rail on terminal sessions too. The pause trace must resolve the
# terminal's session id (not the root chat), call its monitor, and land in that
# terminal's Chat stream.
#
# Run: julia --startup-file=no --project=. test/sshChatMonitorProbe.jl  (opens a window)
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
    "{\"decision\":\"insight\",\"title\":\"Draft\",\"body\":\"the ssh user wants a parser\"}")

wv = L.launchTerminalUI(chatOnly = true)
later(f, s = 0.25) = Webviews.set_timeout(f, wv, s)
SID = Ref("")
TERM = Ref{Any}(nothing)

function finish()
    try Webviews.close(wv) catch e; L.requestStopEventLoop!(wv) end
    println()
    if isempty(failures)
        println("SSH_CHAT_MONITOR_PROBE_OK")
    else
        println("FAILED CHECKS: ", join(failures, ", "))
        exit(1)
    end
    return nothing
end

function report(then)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__scm__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        (function () {
            var info = null;
            Object.keys(terminals).forEach(function (k) {
                if (terminals[k].juliaId === "$(SID[])") info = terminals[k];
            });
            var root = chatTabs[CHAT_SESSION_ID] || CHAT_ONLY;
            window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__scm__',
                text: JSON.stringify({
                    sid: "$(SID[])",
                    active: activeTerminalId,
                    info: info ? { id: info.juliaId, chat: (info.chat||[]).length,
                                   monitor: (info.monitorChat || []).map(function (m) {
                                       return m.role + ':' + m.text; }) } : null,
                    rootMonitor: (root.monitorChat || []).map(function (m) {
                        return m.role + ':' + m.text; })
                }) })).catch(function(){});
        })();
    """)
    later(function ()
        txt = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__scm__", ""),
                  L.TERMINAL_BUFFER_LOCK)
        then(txt)
    end, 0.15)
    return nothing
end

function waitReady(n)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__scm_ready__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__scm_ready__',
            text: String(typeof createTerminal === 'function' && !!CHAT_SESSION_ID) }))
            .catch(function(){});
    """)
    later(function ()
        ok = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__scm_ready__", ""),
                  L.TERMINAL_BUFFER_LOCK) == "true"
        ok && return createSSH()
        n > 80 && (check("the page became ready", false, ""); return finish())
        waitReady(n + 1)
    end, 0.2)
    return nothing
end

function createSSH()
    L.Webviews.eval!(wv, """
        createTerminal({ name: 'ssh sim', kind: 'ssh', remote: 'u@h', sshCmd: 'zsh -i' });
    """)
    waitSession(0)
    return nothing
end

function waitSession(n)
    ids = lock(() -> collect(keys(L.OWNERSHIP_SESSIONS)), L.OWNERSHIP_SESSIONS_LOCK)
    if isempty(ids)
        n > 80 && (check("the SSH terminal appeared", false, ""); return finish())
        return later(() -> waitSession(n + 1), 0.2)
    end
    SID[] = ids[end]
    TERM[] = L.OWNERSHIP_SESSIONS[SID[]]
    ts = Flooty.sessionForId(SID[])
    check("the SSH session is a TerminalSession", ts isa Flooty.TerminalSession,
          string(typeof(ts)))
    # Let the shell reach a prompt; the pause trace also snapshots the terminal.
    later(waitPrompt, 1.0)
    return nothing
end

function waitPrompt(n = 0)
    if !L._tailAtIdlePrompt(L.tailText(TERM[].tail)) && n < 60
        return later(() -> waitPrompt(n + 1), 0.2)
    end
    check("the SSH shell reached a prompt", n < 60,
          repr(last(L._stripAnsi(L.tailText(TERM[].tail)), 100)))
    # Opening the Chat stream must announce its monitor even before a pause.
    L.Webviews.eval!(wv, "selectChatStream('monitor');")
    later(attachAndType, 0.6)
    return nothing
end

function attachAndType()
    report() do txt
        check("opening the SSH Chat stream attaches its monitor",
              occursin("user monitor attached", txt), first(txt, 300))
        # REAL page path: type in the active terminal's chat rail, wait 2 s.
        L.Webviews.eval!(wv, """
            assistCm.setValue('I want a parser');
        """)
        later(verify, 3.2)
    end
    return nothing
end

function verify(n = 0)
    report() do txt
        if calls[] == 0 && n < 40
            return verify(n + 1)
        end
        check("the SSH chat pause reaches its monitor", calls[] > 0, calls[])
        check("…and lands in the SSH terminal's Chat stream",
              occursin("the ssh user wants a parser", txt), first(txt, 400))
        check("…not in the root chat's monitor",
              !occursin("the ssh user wants a parser", txt) ||
              occursin("\"rootMonitor\":[]", txt), first(txt, 400))
        finish()
    end
    return nothing
end

later(() -> waitReady(0), 0.3)
Webviews.set_timeout(function (); println("watchdog"); finish() end, wv, 90.0)
L.runEventLoopAndTeardown!(wv)
