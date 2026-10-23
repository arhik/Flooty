# terminalContextProbe.jl — only the FIRST terminal adopts the chat thread.
#
# Reported: a new terminal carried the main chat session context, so an `ssh`
# task resumed an earlier "launch julia repl" instruction. The hook used to seed
# EVERY session from the root chat. Now the first terminal adopts the thread
# once; later terminals start clean.
#
# Run: julia --startup-file=no --project=. test/terminalContextProbe.jl  (opens a window)
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

CHAT_COMPLETE[] = _ -> "pong"

wv = L.launchTerminalUI(chatOnly = true)
later(f, s = 0.25) = Webviews.set_timeout(f, wv, s)
const SESSIONS = Any[]

function finish()
    for s in SESSIONS
        try Flooty.stopAgentRunner!(s) catch e; nothing end
        try Flooty.stopMonitor!(s) catch e; nothing end
        try L.closeSession!(s) catch e; nothing end
    end
    try Webviews.close(wv) catch e; L.requestStopEventLoop!(wv) end
    println()
    if isempty(failures)
        println("TERMINAL_CONTEXT_PROBE_OK")
    else
        println("FAILED CHECKS: ", join(failures, ", "))
        exit(1)
    end
    return nothing
end

ids() = lock(() -> collect(keys(L.OWNERSHIP_SESSIONS)), L.OWNERSHIP_SESSIONS_LOCK)

function waitReady(tries)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__tc_ready__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__tc_ready__',
            text: String(typeof createTerminal === 'function' &&
                         typeof window.flootyTerminalBufferReport === 'function') })).catch(function(){});
    """)
    later(function ()
        txt = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__tc_ready__", ""),
                   L.TERMINAL_BUFFER_LOCK)
        if txt == "true"
            return run()
        end
        tries > 80 && (check("the page became ready", false, txt); return finish())
        waitReady(tries + 1)
    end, 0.2)
    return nothing
end

function run()
    Flooty.chatOnlyTurn!(wv, "hi")
    waitReply(0)
    return nothing
end

function waitReply(tries)
    root = Flooty.rootChatSession()
    tr = join(Flooty.conversationTranscript(Flooty.conversationOf(root)), "\n")
    if occursin("pong", tr)
        L.Webviews.eval!(wv, "createTerminal({ name: \"first\" });")
        return waitSessions(1, 0, :first)
    end
    tries > 80 && (check("the chat reply landed", false, first(tr, 160)); return finish())
    later(() -> waitReply(tries + 1), 0.15)
    return nothing
end

function waitSessions(want, tries, stage)
    have = ids()
    if length(have) >= want
        if stage === :first
            sess = L.OWNERSHIP_SESSIONS[have[end]]
            push!(SESSIONS, sess)
            tr = join(Flooty.conversationTranscript(
                Flooty.conversationFor(sess)), "\n")
            check("the FIRST terminal adopts the chat thread",
                  occursin("hi", tr) && occursin("pong", tr), first(tr, 160))
            L.Webviews.eval!(wv, "createTerminal({ name: \"second\" });")
            return waitSessions(2, 0, :second)
        else
            first_id = L.sessionIdFor(SESSIONS[1])
            newids = filter(id -> id != first_id, have)
            sess = L.OWNERSHIP_SESSIONS[newids[end]]
            push!(SESSIONS, sess)
            tr = join(Flooty.conversationTranscript(
                Flooty.conversationFor(sess)), "\n")
            check("a LATER terminal does NOT inherit the chat thread",
                  !occursin("hi", tr) && !occursin("pong", tr),
                  isempty(tr) ? "(empty)" : first(tr, 160))
            return finish()
        end
    end
    tries > 80 && (check("the terminals appeared", false, have); return finish())
    later(() -> waitSessions(want, tries + 1, stage), 0.2)
    return nothing
end

later(() -> waitReady(0), 0.5)
Webviews.set_timeout(function (); println("watchdog"); finish() end, wv, 120.0)
L.runEventLoopAndTeardown!(wv)
