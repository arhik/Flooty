# childTerminalProbe.jl — a terminal can launch a CHILD terminal session.
#
#   * the agent's newTerminal action creates a tab whose TerminalSession is
#     parented to the REQUESTING terminal (not the root chat);
#   * the child gets its own monitor + standing agent;
#   * the parent lists it as a child; the root lists only the parent.
#
# Run: julia --startup-file=no --project=. test/childTerminalProbe.jl  (opens a window)
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

function finish()
    try Webviews.close(wv) catch e; L.requestStopEventLoop!(wv) end
    println()
    if isempty(failures)
        println("CHILD_TERMINAL_PROBE_OK")
    else
        println("FAILED CHECKS: ", join(failures, ", "))
        exit(1)
    end
    return nothing
end

function run()
    PARENT[] = L.startReplSession(`zsh -i`; waitPrompt = false)
    PARENT_ID[] = L.adoptSessionTerminal!(PARENT[]; name = "parent")
    root = Flooty.rootChatSession() === nothing ?
           Flooty.ensureRootChatSession!() : Flooty.rootChatSession()
    L.runSessionTerminalHooks!(PARENT[]; parent_id = root.id)
    waitPage(0)
    return nothing
end

function waitPage(tries)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__ct_ready__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__ct_ready__',
            text: String(typeof createTerminal === 'function') })).catch(function(){});
    """)
    later(function ()
        ok = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__ct_ready__", ""),
                  L.TERMINAL_BUFFER_LOCK) == "true"
        if ok
            return waitParentTab(0)
        end
        tries > 80 && (check("the page became ready", false, ""); return finish())
        waitPage(tries + 1)
    end, 0.2)
    return nothing
end

function waitParentTab(tries)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__ct_ptab__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__ct_ptab__',
            text: JSON.stringify(Object.values(terminals).map(function (t) {
                return t.juliaId || ''; })) })).catch(function(){});
    """)
    later(function ()
        txt = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__ct_ptab__", ""),
                   L.TERMINAL_BUFFER_LOCK)
        if occursin(PARENT_ID[], txt)
            return runAgent()
        end
        tries > 80 && (check("the parent page tab appeared", false, txt); return finish())
        waitParentTab(tries + 1)
    end, 0.15)
    return nothing
end

function runAgent()
    replies = String[
        "{\"action\":\"newTerminal\",\"reason\":\"child test\"}",
        "{\"action\":\"done\",\"summary\":\"child opened\"}",
    ]
    i = Ref(0)
    res = runTerminalAgent!(PARENT[], "open a child terminal";
        completeFn = _ -> (i[] += 1; replies[min(i[], length(replies))]),
        maxTurns = 4)
    check("the newTerminal action ran", occursin("newTerminal: opened",
          join(res.transcript, "\n")), first(join(res.transcript, "\n"), 200))
    waitChild(0)
    return nothing
end

function waitChild(tries)
    ids = lock(() -> collect(keys(L.OWNERSHIP_SESSIONS)), L.OWNERSHIP_SESSIONS_LOCK)
    newids = filter(id -> id != PARENT_ID[], ids)
    if isempty(newids)
        tries > 80 && (check("the child terminal session appeared", false, ids); return finish())
        return later(() -> waitChild(tries + 1), 0.2)
    end
    id = newids[end]
    child = L.OWNERSHIP_SESSIONS[id]
    CHILD[] = child
    check("the child terminal session appeared", true, id)
    ts = Flooty.sessionForId(id)
    check("…with a TerminalSession", ts isa Flooty.TerminalSession,
          string(typeof(ts)))
    check("…parented to the REQUESTING terminal",
          ts isa Flooty.TerminalSession && ts.parent == PARENT_ID[],
          string(ts isa Flooty.TerminalSession ? ts.parent : "?"))
    pts = Flooty.sessionForId(PARENT_ID[])
    check("…listed as the parent's child",
          pts isa Flooty.TerminalSession && id in pts.children,
          string(pts isa Flooty.TerminalSession ? pts.children : "?"))
    root = Flooty.rootChatSession()
    check("…and NOT a root child", !(id in root.children), string(root.children))
    check("…with its own monitor", haskey(Flooty.MONITOR_STATES, child), "")
    check("…and standing agent", Flooty.agentRunnerRunning(child), "")
    check("child:1 resolves the new terminal",
          Flooty.childTerminalAt(PARENT[], 1) === ts, "")
    snap = agentSnapshot(PARENT[])
    check("…and the snapshot lists it",
          snap.child_count == 1 && occursin("terminal/tab", string(snap)),
          first(string(snap), 300))
    Flooty.forwardParentInsight!(child, "child monitor insight")
    notes = Flooty.takeParentNotes!(PARENT_ID[])
    check("its monitor insight reaches the parent driver",
          any(n -> occursin("child monitor insight", n), notes), notes)
    waitTab(id, 0)
    return nothing
end

function waitTab(id, tries)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__ct_tabs__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__ct_tabs__',
            text: JSON.stringify({
                ids: Object.values(terminals).map(function (t) { return t.juliaId || ''; }),
                roots: Array.from(document.querySelectorAll('#terminal-tabs .root-icon'))
                    .map(function (t) { return t.title; }),
                strips: document.querySelectorAll('#childTabs .child-strip').length,
                kids: Array.from(document.querySelectorAll('#childTabs .child-tab'))
                    .map(function (t) { return t.textContent.trim(); }),
                oldRows: document.querySelectorAll('#terminal-tabs .terminal-tab').length,
                railW: Math.round((document.getElementById('terminal-tabs') || {})
                    .getBoundingClientRect().width || 0),
                iconW: Math.round((document.querySelector('#terminal-tabs .root-icon') || {})
                    .getBoundingClientRect().width || 0)
            }) })).catch(function(){});
    """)
    later(function ()
        txt = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__ct_tabs__", ""),
                   L.TERMINAL_BUFFER_LOCK)
        if occursin(id, txt) || tries > 40
            check("a page tab is bound to the child session", occursin(id, txt), txt)
            check("the left rail is ICONS, not a nested tree",
                  occursin("\"oldRows\":0", txt), first(txt, 240))
            check("the rail width fits the icon",
                  occursin("\"railW\":42", txt) || occursin("\"railW\":43", txt) ||
                  (occursin("\"iconW\":34", txt) &&
                   !occursin("\"railW\":176", txt)), first(txt, 240))
            check("the child gets its own horizontal strip",
                  occursin("\"strips\":1", txt) &&
                  !occursin("\"kids\":[]", txt), first(txt, 300))
            cleanup()
            return nothing
        end
        later(() -> waitTab(id, tries + 1), 0.1)
        return nothing
    end, 0.15)
    return nothing
end

function cleanup()
    try Flooty.stopAgentRunner!(CHILD[]) catch e; nothing end
    try Flooty.stopMonitor!(CHILD[]) catch e; nothing end
    try L.closeSession!(CHILD[]) catch e; nothing end
    try L.closeSession!(PARENT[]) catch e; nothing end
    finish()
    return nothing
end

later(run, 2.0)
Webviews.set_timeout(function (); println("watchdog"); finish() end, wv, 120.0)
L.runEventLoopAndTeardown!(wv)
