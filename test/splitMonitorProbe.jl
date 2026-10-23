# splitMonitorProbe.jl — a SPLIT child is a real session: monitor + agent.
#
# The split pane is created through the same `terminal_create` path as a tab, so
# the Flooty session hook must attach its ambient monitor and standing
# agent. This pins that contract and the session-tree shape:
#   * the child has its own ReplSession and a MonitorState;
#   * it is registered as a TerminalSession under the ROOT chat (not under the
#     parent terminal — children are siblings in the tree);
#   * closing the child unlinks its session.
#
# Run: julia --startup-file=no --project=. test/splitMonitorProbe.jl  (opens a window)
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
const PARENT = Ref{Any}(nothing)
const PARENT_ID = Ref("")
const CHILD = Ref{Any}(nothing)
const CHILD_ID = Ref("")
const TRIES = Ref(0)

function finish()
    try Webviews.close(wv) catch e; L.requestStopEventLoop!(wv) end
    println()
    if isempty(failures)
        println("SPLIT_MONITOR_PROBE_OK")
    else
        println("FAILED CHECKS: ", join(failures, ", "))
        exit(1)
    end
    return nothing
end

function waitReady(tries)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__sm_ready__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__sm_ready__',
            text: String(typeof window.flootySplitTerminal === 'function') })).catch(function(){});
    """)
    later(function ()
        txt = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__sm_ready__", ""),
                   L.TERMINAL_BUFFER_LOCK)
        txt == "true" && return setup()
        tries > 80 && (check("the page became ready", false, txt); return finish())
        waitReady(tries + 1)
    end, 0.2)
    return nothing
end

function setup()
    # A session-backed parent through the SAME hook path as a tab.
    PARENT[] = L.startReplSession(`zsh -i`; waitPrompt = false)
    PARENT_ID[] = L.adoptSessionTerminal!(PARENT[]; name = "split-parent")
    L.runSessionTerminalHooks!(PARENT[])
    check("the parent got its monitor",
          haskey(Flooty.MONITOR_STATES, PARENT[]), "")
    later(function ()
        L.Webviews.eval!(wv, """
            (function () {
                try { window.flootySplitTerminal(); } catch (e) {}
            })();
        """)
        pollChild()
    end, 1.0)
    return nothing
end

function pollChild()
    TRIES[] += 1
    child = L.splitSession()
    if child !== nothing
        CHILD[] = child
        CHILD_ID[] = L.sessionIdFor(child)
        return verify()
    end
    TRIES[] > 100 && (check("the split child bound a session", false, ""); return finish())
    later(pollChild, 0.2)
    return nothing
end

function verify()
    child = CHILD[]
    id = CHILD_ID[]
    check("the split child has its own monitor",
          haskey(Flooty.MONITOR_STATES, child), "")
    ts = Flooty.sessionForId(id)
    check("…and a TerminalSession", ts isa Flooty.TerminalSession,
          string(typeof(ts)))
    parent_id = L.sessionIdFor(PARENT[])
    pts = Flooty.sessionForId(parent_id)
    check("…parented to the MAIN terminal",
          ts isa Flooty.TerminalSession && ts.parent == parent_id,
          string(ts isa Flooty.TerminalSession ? ts.parent : "?"))
    check("…listed as the main terminal's child",
          pts isa Flooty.TerminalSession && id in pts.children,
          string(pts isa Flooty.TerminalSession ? pts.children : "?"))
    check("…mapped to the main pane it serves",
          L.splitParentSession(child) === PARENT[], "")
    check("…and the main knows its split", L.splitChildSession(PARENT[]) === child, "")

    # The main agent must see the split and the USER's pending input there.
    mstate = get(Flooty.MONITOR_STATES, child, nothing)
    mstate === nothing || (mstate.completeFn = _ -> "{\"decision\":\"observe\"}")
    typeIntoChild(0)
end

function typeIntoChild(tries)
    child = CHILD[]
    if !L._tailAtIdlePrompt(L.tailText(child.tail))
        tries > 80 && (check("the split child reaches a prompt", false,
                             repr(last(L.tailText(child.tail), 80))); return finish())
        return later(() -> typeIntoChild(tries + 1), 0.1)
    end
    L.userWrite(child, "echo SPLIT_INTENT")
    later(function ()
        pending = L.pendingInputLine(child)
        snap = agentSnapshot(PARENT[])
        check("typing in the split is visible to the main snapshot",
              pending == "echo SPLIT_INTENT",
              repr(pending) * " tail=" * repr(last(L.tailText(child.tail), 160)))
        check("…as split=open with the pending input",
              snap.split_open && snap.split_input == "echo SPLIT_INTENT" &&
              occursin("split=open", string(snap)), string(snap))
        Flooty.forwardSplitInsight!(
            child, "the user is typing in the split")
        notes = Flooty.takeMonitorNotes!(PARENT[])
        check("the split's monitor insight is shared with the main driver",
              any(n -> occursin("split pane:", n), notes), notes)
        L.userWrite(child, "\x15")
        L.closeChildTerminalUi(wv)
        later(closed, 1.0)
    end, 0.6)
    return nothing
end

function closed()
    id = CHILD_ID[]
    check("closing the child unlinks its session",
          Flooty.sessionForId(id) === nothing, id)
    pts = Flooty.sessionForId(L.sessionIdFor(PARENT[]))
    check("…removes it from the main terminal's children",
          !(pts isa Flooty.TerminalSession && id in pts.children), "")
    check("…and clears the split/parent mapping",
          L.splitChildSession(PARENT[]) === nothing &&
          L.splitParentSession(CHILD[]) === nothing, "")
    finish()
    return nothing
end

later(() -> waitReady(0), 0.5)
Webviews.set_timeout(function ()
    println("watchdog")
    finish()
end, wv, 120.0)
L.runEventLoopAndTeardown!(wv)
