# terminalSessionProbe.jl — the session TREE: a terminal is a CHILD of the root
# chat session, has terminal+chat interfaces, a chat monitor, parent traces and a
# steering channel; closing it unlinks it.
#
# Run: julia --startup-file=no --project=. test/terminalSessionProbe.jl  (opens a window)
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

CHAT_MONITOR_SEEN = Ref("")
Flooty.CHAT_MONITOR_COMPLETE[] = messages -> begin
    CHAT_MONITOR_SEEN[] = join([String(something(m.content, "")) for m in messages], "\n")
    return "{\"decision\":\"insight\",\"body\":\"the user wants the parser\"}"
end

wv = L.launchTerminalUI(chatOnly = true)
later(f, s = 0.25) = Webviews.set_timeout(f, wv, s)
const ROOT = Ref{Any}(nothing)
const TERM = Ref("")
const REPL = Ref{Any}(nothing)

function finish()
    try Webviews.close(wv) catch e; L.requestStopEventLoop!(wv) end
    println()
    if isempty(failures)
        println("TERMINAL_SESSION_PROBE_OK")
    else
        println("FAILED CHECKS: ", join(failures, ", "))
        exit(1)
    end
    return nothing
end

function run()
    ROOT[] = ensureRootChatSession!()
    L.Webviews.eval!(wv, "createTerminal({ name: \"agent\" });")
    later(waitSession, 1.5)
    return nothing
end

function waitSession(tries = 0)
    ids = lock(() -> collect(keys(L.OWNERSHIP_SESSIONS)), L.OWNERSHIP_SESSIONS_LOCK)
    if isempty(ids)
        tries > 80 && (check("the terminal session registered", false, ""); return finish())
        return later(() -> waitSession(tries + 1), 0.25)
    end
    TERM[] = ids[end]
    REPL[] = L.OWNERSHIP_SESSIONS[TERM[]]
    later(stepTree, 0.3)
    return nothing
end

function stepTree()
    ts = sessionForId(TERM[])
    check("the terminal is a TerminalSession", ts isa TerminalSession,
          ts === nothing ? "nothing" : string(typeof(ts)))
    check("…its parent is the root chat session", ts.parent == ROOT[].id,
          (ts.parent, ROOT[].id))
    check("…and the root lists it as a child", TERM[] in ROOT[].children,
          ROOT[].children)
    check("…with terminal + chat interfaces and the split layout",
          ts.interfaces == Symbol[:terminal, :chat] && ts.layout === :split,
          (ts.interfaces, ts.layout))

    # CHAT monitor of the terminal session -> note to THAT driver + parent trace.
    chatInteractionTrace!(TERM[], "pause", "parse the file", 3.0)
    later(function ()
        notes = takeMonitorNotes!(REPL[])
        check("the terminal's chat monitor notes ITS driver",
              any(n -> occursin("parser", n), notes), notes)
        traces = takeParentNotes!(ROOT[].id)
        check("…and reports the insight to the PARENT",
              any(n -> occursin(TERM[], n) && occursin("insight", n), traces), traces)
        check("the CHAT monitor sees the draft, not a terminal snapshot",
              !occursin("TERMINAL SNAPSHOT", CHAT_MONITOR_SEEN[]) &&
              !occursin("AGENT CONTEXT", CHAT_MONITOR_SEEN[]),
              first(CHAT_MONITOR_SEEN[], 240))
        # Parent -> child steering.
        steerSession!(TERM[], "note", "try sed instead")
        steer = takeParentNotes!(TERM[])
        check("the parent can steer the child",
              steer == ["STEER note: try sed instead"], steer)
        # Concrete driver status + parent trace.
        publishTerminalStatus!(REPL[], "running")
        check("driver status is concrete on the session",
              sessionForId(TERM[]).status == "running", sessionForId(TERM[]).status)
        check("…and is mirrored to the parent",
              any(n -> occursin("status: running", n), takeParentNotes!(ROOT[].id)),
              "")
        # Closing unlinks it from the tree.
        L.handleTerminalKill(TERM[]; force = true)
        later(stepClosed, 0.5)
    end, 1.2)
    return nothing
end

function stepClosed()
    check("closing the terminal unregisters the session",
          sessionForId(TERM[]) === nothing, "")
    check("…and removes it from the root's children",
          !(TERM[] in ROOT[].children), ROOT[].children)
    finish()
    return nothing
end

later(run, 5.0)
Webviews.set_timeout(function (); println("watchdog"); finish() end, wv, 120.0)
L.runEventLoopAndTeardown!(wv)
