# sshSessionProbe.jl — SSH sessions and their child terminals.
#
# The PTY command is simulated (`zsh -i`) so the probe is hermetic; the SESSION
# metadata and inheritance are the subject: kind=:ssh, remote target, and a
# child terminal that inherits the SSH command/target and is parented to it.
#
# Run: julia --startup-file=no --project=. test/sshSessionProbe.jl  (opens a window)
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

function finish()
    try Webviews.close(wv) catch e; L.requestStopEventLoop!(wv) end
    println()
    if isempty(failures)
        println("SSH_SESSION_PROBE_OK")
    else
        println("FAILED CHECKS: ", join(failures, ", "))
        exit(1)
    end
    return nothing
end

function waitReady(tries)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__ssh_ready__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__ssh_ready__',
            text: String(typeof createTerminal === 'function') })).catch(function(){});
    """)
    later(function ()
        ok = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__ssh_ready__", ""),
                  L.TERMINAL_BUFFER_LOCK) == "true"
        ok && return createParent()
        tries > 80 && (check("the page became ready", false, ""); return finish())
        waitReady(tries + 1)
    end, 0.2)
    return nothing
end

function createParent()
    L.Webviews.eval!(wv, """
        createTerminal({ name: 'ssh sim', kind: 'ssh', remote: 'u@h',
                         sshCmd: 'zsh -i' });
    """)
    waitParent(0)
    return nothing
end

function waitParent(tries)
    ids = lock(() -> collect(keys(L.OWNERSHIP_SESSIONS)), L.OWNERSHIP_SESSIONS_LOCK)
    if isempty(ids)
        tries > 80 && (check("the SSH parent session appeared", false, ""); return finish())
        return later(() -> waitParent(tries + 1), 0.2)
    end
    PARENT_ID[] = ids[end]
    PARENT[] = L.OWNERSHIP_SESSIONS[PARENT_ID[]]
    ts = Flooty.sessionForId(PARENT_ID[])
    check("the SSH session is a TerminalSession", ts isa Flooty.TerminalSession,
          string(typeof(ts)))
    check("…with kind=:ssh", ts isa Flooty.TerminalSession && ts.kind === :ssh,
          string(ts isa Flooty.TerminalSession ? ts.kind : "?"))
    check("…and its remote target",
          ts isa Flooty.TerminalSession && ts.remote == "u@h",
          string(ts isa Flooty.TerminalSession ? ts.remote : "?"))
    later(createChild, 0.5)
    return nothing
end

function createChild()
    L.Webviews.eval!(wv, """
        createTerminal({ name: 'ssh child', parentSession: "$(PARENT_ID[])" });
    """)
    waitChild(0)
    return nothing
end

function waitChild(tries)
    ids = lock(() -> collect(keys(L.OWNERSHIP_SESSIONS)), L.OWNERSHIP_SESSIONS_LOCK)
    newids = filter(id -> id != PARENT_ID[], ids)
    if isempty(newids)
        tries > 80 && (check("the SSH child terminal appeared", false, ids); return finish())
        return later(() -> waitChild(tries + 1), 0.2)
    end
    CHILD_ID[] = newids[end]
    CHILD[] = L.OWNERSHIP_SESSIONS[CHILD_ID[]]
    cts = Flooty.sessionForId(CHILD_ID[])
    check("the child terminal appeared", true, CHILD_ID[])
    check("…inherited kind=:ssh",
          cts isa Flooty.TerminalSession && cts.kind === :ssh,
          string(cts isa Flooty.TerminalSession ? cts.kind : "?"))
    check("…the remote target", cts isa Flooty.TerminalSession &&
          cts.remote == "u@h", string(cts isa Flooty.TerminalSession ? cts.remote : "?"))
    check("…and is parented to the SSH session",
          cts isa Flooty.TerminalSession && cts.parent == PARENT_ID[],
          string(cts isa Flooty.TerminalSession ? cts.parent : "?"))
    pts = Flooty.sessionForId(PARENT_ID[])
    check("…listed as the SSH session's child",
          pts isa Flooty.TerminalSession && CHILD_ID[] in pts.children,
          string(pts isa Flooty.TerminalSession ? pts.children : "?"))
    # The simulated inherited command is a local zsh; both panes reach prompts.
    later(function ()
        check("the SSH session reaches a prompt",
              L._tailAtIdlePrompt(L.tailText(PARENT[].tail)),
              last(L._stripAnsi(L.tailText(PARENT[].tail)), 100))
        check("the child reaches a prompt",
              L._tailAtIdlePrompt(L.tailText(CHILD[].tail)),
              last(L._stripAnsi(L.tailText(CHILD[].tail)), 100))
        try L.closeSession!(CHILD[]) catch e; nothing end
        try L.closeSession!(PARENT[]) catch e; nothing end
        finish()
    end, 1.0)
    return nothing
end

later(() -> waitReady(0), 0.5)
Webviews.set_timeout(function (); println("watchdog"); finish() end, wv, 120.0)
L.runEventLoopAndTeardown!(wv)
