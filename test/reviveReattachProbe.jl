# reviveReattachProbe.jl — a revived terminal gets its agents back.
#
# A revive (the pane's "Revive" button) creates a NEW ReplSession object
# behind the SAME terminal id. Every per-session registry in the app is keyed
# by the session OBJECT, so without the reconnect hook the revived terminal
# keeps no monitor, no driver and no agent brief: the pane looks alive but the
# agent that was driving it is gone, and the chat gets no answer.
#
# This probe drives the real path: create a session-backed terminal (the app
# hooks attach the agents), revive it through FlootyPTYLayer, and check that
# the NEW session is the one the agents are running on.
#
#   julia --startup-file=no --project=. test/reviveReattachProbe.jl
using Flooty
using FlootyPTYLayer
using FlootyPTYLayer: startReplSession, closeSession!

failures = String[]
function check(name, ok, detail = "")
    println(ok ? "PASS  " : "FAIL  ", name,
            isempty(detail) ? "" : "  [" * string(detail) * "]")
    ok || push!(failures, name)
    return ok
end

sess = nothing
termId = ""
try
    # The path the page uses for a NEW terminal: it spawns the session AND
    # fires the app's session-terminal hooks (the standing agent, the
    # monitor, the tree entry).
    termId = FlootyPTYLayer.handleTerminalCreate(`zsh -i`)
    sleep(1.0)
    sess = lock(() -> get(FlootyPTYLayer.OWNERSHIP_SESSIONS, termId, nothing),
                FlootyPTYLayer.OWNERSHIP_SESSIONS_LOCK)
    check("the terminal has an id", !isempty(termId), termId)
    check("the session is registered", sess !== nothing)
    check("the standing agent is running on the session",
          sess !== nothing && Flooty.agentRunnerRunning(sess))
    check("a monitor is running", Flooty.monitorRunning())
    check("the session tree knows the terminal",
          Flooty.sessionForId(termId) !== nothing)

    # Give the agent a brief, so we can prove it SURVIVES the revive.
    sess === nothing || Flooty.setAgentBrief!(sess,
        "the brief from before the revive")
    check("the agent brief is set",
          sess !== nothing &&
          !isempty(Flooty.agentBriefFor(sess)))

    # Revive: the package swaps the PTY behind the same terminal id and runs
    # the reconnect hooks.
    ok = FlootyPTYLayer.handleTerminalReconnect(termId)
    check("the revive succeeded", ok)
    sleep(0.8)

    newSess = lock(() -> get(FlootyPTYLayer.OWNERSHIP_SESSIONS, termId, nothing),
                   FlootyPTYLayer.OWNERSHIP_SESSIONS_LOCK)
    check("the revive created a NEW session object",
          newSess !== nothing && newSess !== sess)

    if newSess !== nothing
        check("the standing agent runs on the REVIVED session",
              Flooty.agentRunnerRunning(newSess))
        check("a monitor is running for the revived session",
              Flooty.monitorRunning())
        check("the agent brief came along",
              occursin("before the revive",
                        string(Flooty.agentBriefFor(newSess))))
        tree = Flooty.sessionForId(termId)
        println("  [tree] sessionForId(", termId, ") = ", tree)
        println("  [tree] sessionIdFor(newSess) = ",
                repr(FlootyPTYLayer.sessionIdFor(newSess)))
        println("  [tree] tree.repl === newSess : ",
                tree !== nothing && tree.repl === newSess)
        println("  [run] newSess.closed = ", newSess.closed)
        println("  [run] the revived pty is alive = ", newSess.pty.open,
                " exitStatus=", newSess.pty.exitStatus)
        check("the revived PTY is still alive",
              newSess.pty.open && newSess.pty.exitStatus === nothing)
        check("the session tree points at the revived session",
              tree !== nothing && tree.repl === newSess)
    end
finally
    if sess !== nothing
        try; closeSession!(sess); catch; end
    end
    if !isempty(termId)
        try; FlootyPTYLayer.handleTerminalKill(termId); catch; end
    end
end

println()
if isempty(failures)
    println("REVIVE_REATTACH_PROBE_OK")
else
    println("FAILED: ", join(failures, ", "))
    exit(1)
end
