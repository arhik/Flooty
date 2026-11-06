# chatCoreProbe.jl — chat-only UI against a REAL FlootyCore backend.
#
# Opt-in: requires FLOOTY_CORE_URL pointing at a running Core. Verifies:
#   * an ordinary chat instruction is answered in the rail, without a terminal;
#   * an explicitly terminal instruction opens a session-backed terminal and
#     shows the human confirmation, not raw tool JSON.
#
# Run:
#   FLOOTY_CORE_URL=http://127.0.0.1:18081 julia --startup-file=no --project=. test/chatCoreProbe.jl
import FlootyPTYLayer
import Flooty
import Webviews

const L = FlootyPTYLayer
const R = Flooty
const URL = get(ENV, "FLOOTY_CORE_URL", "")

if isempty(URL)
    println("CHAT_CORE_PROBE_SKIP (set FLOOTY_CORE_URL)")
    exit(0)
end

const DIR = mktempdir()
failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = detail === "" || detail === nothing ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end

R.agentApp(sessionsDir = DIR, journalPath = joinpath(DIR, "journal.sqlite"))
wv = L.launchTerminalUI(chatOnly = true)
t0 = time()
say(m) = (println("[CORE] ", round(time() - t0; digits = 1), "s ", m); flush(stdout))

function rootTranscript()
    root = R.rootChatSession()
    root === nothing && return ""
    return join(R.conversationTranscript(R.conversationOf(root)), "\n---\n")
end

function sessionIds()
    lock(() -> collect(keys(L.OWNERSHIP_SESSIONS)), L.OWNERSHIP_SESSIONS_LOCK)
end

function finish()
    for id in sessionIds()
        s = L.OWNERSHIP_SESSIONS[id]
        try R.stopAgentRunner!(s) catch e; nothing end
        try R.stopMonitor!(s) catch e; nothing end
        try L.closeSession!(s) catch e; nothing end
    end
    R.disableJournalPersistence!()
    try Webviews.close(wv) catch e; L.requestStopEventLoop!(wv) end
    println()
    if isempty(failures)
        println("CHAT_CORE_PROBE_OK")
    else
        println("FAILED CHECKS: ", join(failures, ", "))
        exit(1)
    end
    return nothing
end

function waitFor(tag, predicate, then; timeout = 60.0)
    deadline = time() + timeout
    function poll()
        ok, detail = predicate()
        if ok
            return then(detail)
        end
        if time() > deadline
            check(tag, false, detail)
            return finish()
        end
        return Webviews.set_timeout(poll, wv, 0.3)
    end
    Webviews.set_timeout(poll, wv, 0.3)
    return nothing
end

function stepPlainChat()
    say("plain chat: print 1 and stop")
    R.chatOnlyTurn!(wv, "print 1 and stop")
    waitFor("the plain instruction was answered in chat",
            () -> begin
                tr = rootTranscript()
                answered = occursin(r"assistant:\s*\S", tr)
                (answered && isempty(sessionIds()), first(tr, 240))
            end,
            _ -> begin
                tr = rootTranscript()
                check("the plain instruction was answered in chat", true, first(tr, 240))
                check("…without opening a terminal", isempty(sessionIds()), sessionIds())
                check("…and without a terminal-tool confirmation",
                      !occursin("Opening a terminal", tr), first(tr, 240))
                stepTerminalChat()
            end)
end

function stepTerminalChat()
    say("terminal chat: open a terminal and run pwd")
    R.chatOnlyTurn!(wv, "Open a terminal and run pwd, then report the output.")
    waitFor("the terminal instruction opened a session",
            () -> begin
                ids = sessionIds()
                tr = rootTranscript()
                (!isempty(ids) && occursin("Opening a terminal", tr),
                 "sessions=" * repr(ids) * " root=" * first(tr, 240))
            end,
            _ -> begin
                ids = sessionIds()
                tr = rootTranscript()
                check("the terminal instruction opened a session", !isempty(ids), ids)
                check("…and the rail shows the confirmation",
                      occursin("Opening a terminal", tr), first(tr, 240))
                check("…not raw tool JSON", !occursin("\"action\":\"terminal\"", tr),
                      first(tr, 240))
                finish()
            end)
end

Webviews.set_timeout(stepPlainChat, wv, 4.0)
Webviews.set_timeout(function ()
    say("watchdog")
    finish()
end, wv, 150.0)
L.runEventLoopAndTeardown!(wv)
