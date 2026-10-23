# flootyAgentRunner.jl — a STANDING, prompt-driven agent for one ReplSession.
#
# Warp-model alignment (per design discussion):
#   * ONE ReplSession; the agent is not a second PTY or a hidden worker —
#     it TYPES INTO THE SAME pane the user sees (keystrokes echo, output
#     renders live).
|#   * IDLE by default: the USER owns the REPL until they submit an
|#     instruction through the assist bar. Submitting IS commissioning the
|#     agent: it wakes, tags :agent (pill -> ai — "AI running the show",
|#     prompt stays stock julia>), works visibly, then tags OUT
|#     (pill -> julia) when finished.
#   * While a run is ACTIVE, further submissions are consumed by the loop
#     itself as USER INTERJECTIONs (pause-and-wait arbitration in
#     runAgentLoop!) — the runner deliberately stops polling so prompts are
#     never double-consumed.
#
|# ONE AGENT PER SESSION (user decision): runners are keyed by the session
|# object, so EVERY repl tab can carry its own standing agent at the same
|# time — each commissioned independently through its own assist bar.

using FlootyPTYLayer

mutable struct AgentRunner
    sess::ReplSession
    stop::Bool
    active::Bool              # a commissioned run is executing
    task::Union{Task,Nothing}
end

# Test seam: probes inject a completion for the commissioned run (the real
# path otherwise resolves the tab's actor model).
const RUNNER_COMPLETE = Ref{Union{Nothing,Function}}(nothing)

# One runner per session: keyed by the session object itself.
const AGENT_RUNNERS = IdDict{Any,AgentRunner}()
const AGENT_RUNNERS_LOCK = ReentrantLock()

"""
    startAgentRunner!(sess::ReplSession; kwargs...) :: Bool

Start the standing agent for `sess` — ONE PER SESSION, so every repl tab can
carry its own agent simultaneously. Returns false when `sess` already has a
runner. Keyword args forward to `runTerminalAgent!`
(maxTurns, evalTimeoutS, waitTimeoutS).

While idle the runner polls the session's assist-prompt queue; a submitted
instruction commissions one full agent run against the SHARED PTY. Between
runs ownership returns to the user automatically.
"""
function startAgentRunner!(sess::ReplSession;
                           maxTurns::Int = 0,
                           evalTimeoutS::Real = 60.0,
                           waitTimeoutS::Real = 300.0)
    lock(AGENT_RUNNERS_LOCK) do
        get(AGENT_RUNNERS, sess, nothing) !== nothing && return false
    end
    runner = AgentRunner(sess, false, false, nothing)
    installed = lock(AGENT_RUNNERS_LOCK) do
        # Re-check inside the lock: two tasks commissioning the same session
        # concurrently — exactly one wins, the loser sees already-running.
        if get(AGENT_RUNNERS, sess, nothing) !== nothing
            return false
        end
        AGENT_RUNNERS[sess] = runner
        return true
    end
    installed || return false
    runner.task = @async begin
        try
            while !runner.stop && !sess.closed
                sleep(0.25)
                runner.stop && break
                runner.active && continue          # loop drains its own intents
                prompts = takeAssistPrompts!(sess)
                isempty(prompts) && continue
                # First queued line is the commission; any extras were typed
                # blind-folded before the run started — prepend them so the
                # model sees everything the user said.
                task = join(prompts, "\nAND ALSO: ")
                runner.active = true
                try
                    say0(sess, "commissioned: " * first(task, 120))
                    runTerminalAgent!(sess, task;
                                      maxTurns = maxTurns,
                                      evalTimeoutS = evalTimeoutS,
                                      waitTimeoutS = waitTimeoutS,
                                      completeFn = RUNNER_COMPLETE[])
                catch err
                    say0(sess, "[runner] run failed: " * sprint(showerror, err))
                finally
                    runner.active = false
                    # Hand the REPL back unless the user already took over.
                    try
                        currentState(sess.control) != :user &&
                            tagOut(sess.control)
                    catch
                    end
                    say0(sess,
                         "idle — the REPL is yours (type an instruction to commission the agent)")
                end
            end
        catch err
            @warn "flootyAgentRunner: died" exception = err
        finally
            # Deregister so the same session can be re-commissioned later.
            lock(AGENT_RUNNERS_LOCK) do
                if haskey(AGENT_RUNNERS, sess) && AGENT_RUNNERS[sess] === runner
                    delete!(AGENT_RUNNERS, sess)
                end
            end
        end
    end
    return true
end

"""
    stopAgentRunner!([sess]) 

Stop standing agents: `sess`'s runner when given, otherwise ALL of them.
Idempotent; stopped runners deregister themselves on unwind.
"""
function stopAgentRunner!(sess::Union{Nothing,ReplSession} = nothing)
    targets = lock(AGENT_RUNNERS_LOCK) do
        if sess === nothing
            collect(values(AGENT_RUNNERS))
        else
            r = get(AGENT_RUNNERS, sess, nothing)
            r === nothing ? AgentRunner[] : AgentRunner[r]
        end
    end
    for runner in targets
        runner.stop = true
        # Bound teardown; a run blocked in a model/send must not hang the app.
        waitBoundedTask(runner.task, 5.0, "agent runner")
    end
    return nothing
end

agentRunnerRunning() = lock(AGENT_RUNNERS_LOCK) do
    any(r -> !r.stop, values(AGENT_RUNNERS))
end
agentRunnerRunning(sess::ReplSession) = lock(AGENT_RUNNERS_LOCK) do
    r = get(AGENT_RUNNERS, sess, nothing)
    return r !== nothing && !r.stop
end
"""True while ANY standing agent (or `sess`'s) is executing a run."""
agentRunnerBusy() = lock(AGENT_RUNNERS_LOCK) do
    any(r -> r.active, values(AGENT_RUNNERS))
end
agentRunnerBusy(sess::ReplSession) = lock(AGENT_RUNNERS_LOCK) do
    r = get(AGENT_RUNNERS, sess, nothing)
    return r !== nothing && r.active
end

# Local announcer: stdout + PER-SESSION status tagging, without depending on
# the loop internals. Session-tagged lines let the page keep each tab's
# status independent while several agents run concurrently.
say0(sess::ReplSession, line::AbstractString) = begin
    @debug string("[agent-runner] ", line)
    wv = FlootyPTYLayer.activeTerminalUiWebview()
    wv === nothing || FlootyPTYLayer.pushAgentEventToWindow(
        wv, AgentStatusEvent(FlootyPTYLayer.sessionIdFor(sess), String(line)))
    return nothing
end
