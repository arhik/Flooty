# ownershipPerSessionProbe.jl — the user/AI switch is PER SESSION.
#
# Two terminals, two agents. Taking over in one must not touch the other:
# the arbitration state lives in the SESSION's control state, and the UI
# actions must name the session they act on (the page sends the focused
# pane's session id).
#
# The probe drives the REAL path: the page's callJulia -> the binding ->
# applyOwnershipAction! -> the session's control state.
#
#   julia --startup-file=no --project=. test/ownershipPerSessionProbe.jl
using Flooty
using FlootyPTYLayer
using FlootyPTYLayer: tagIn, tagOut, currentState
using Webviews

failures = String[]
function check(name, ok, detail = "")
    println(ok ? "PASS  " : "FAIL  ", name,
            isempty(detail) ? "" : "  [" * string(detail) * "]")
    ok || push!(failures, name)
    return ok
end

wv = FlootyPTYLayer.launchTerminalUI()

# The work runs off the main thread: the main thread owns the NSApplication
# event loop, and the page's bindings only exist once the loop is running.
worker = @async begin
    sleep(1.5)
    ids = String[]
    sessions = Any[]
    try
        # Two terminals, two agents (the app's hook attaches them).
        for _ in 1:2
            push!(ids, FlootyPTYLayer.handleTerminalCreate(`zsh -i`))
        end
        sleep(1.0)
        for id in ids
            sess = lock(() -> get(FlootyPTYLayer.OWNERSHIP_SESSIONS, id, nothing),
                        FlootyPTYLayer.OWNERSHIP_SESSIONS_LOCK)
            push!(sessions, sess)
            # Both start agent-owned.
            sess === nothing || tagIn(sess.control; mode = :agent)
        end
        check("two terminals with sessions", length(sessions) == 2 &&
              all(s -> s !== nothing, sessions))
        a, b = sessions
        check("both start agent-owned",
              currentState(a.control) == :agent && currentState(b.control) == :agent,
              string(currentState(a.control), "/", currentState(b.control)))

        pageCall(action, sessionId) = Webviews.dispatch(wv) do
            Webviews.eval!(wv, "callJulia('" * action * "', JSON.stringify(" *
                                "{session_id: '" * sessionId * "'}));")
        end

        # The page's Take Over on the FIRST session.
        pageCall("flootyTakeOver", ids[1])
        sleep(1.0)
        check("the session that was taken over is now user-owned",
              currentState(a.control) == :user, string(currentState(a.control)))
        check("the OTHER session is untouched",
              currentState(b.control) == :agent, string(currentState(b.control)))

        # User typing in the SECOND session yields only that one.
        pageCall("flootyUserTyping", ids[2])
        sleep(1.0)
        check("typing yields the session typed in",
              currentState(b.control) == :user, string(currentState(b.control)))
        check("the other session keeps its state",
              currentState(a.control) == :user, string(currentState(a.control)))

        # Hand the first one back to its agent.
        pageCall("flootyAssistResume", ids[1])
        sleep(1.0)
        check("the session can be handed back to its agent",
              currentState(a.control) == :agent, string(currentState(a.control)))
        check("the other session is still untouched",
              currentState(b.control) == :user, string(currentState(b.control)))
    catch err
        println("PROBE ERROR: ", sprint(showerror, err))
        push!(failures, "probe error")
    finally
        for id in ids
            try; FlootyPTYLayer.handleTerminalKill(id); catch; end
        end
    end
    sleep(0.3)
    try; Webviews.close(wv); catch; end
end

FlootyPTYLayer.runEventLoopAndTeardown!(wv)
wait(worker)

println()
if isempty(failures)
    println("OWNERSHIP_PER_SESSION_PROBE_OK")
else
    println("FAILED: ", join(failures, ", "))
    exit(1)
end
