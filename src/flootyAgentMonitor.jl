# flootyAgentMonitor.jl — ambient watcher (Warp ambient-agent style).
#
# An @async task samples the session every pollS seconds and turns episodes
# into AgentFeedback events (bridged to UI popups by default):
#   * a statement executing longer than interjectAfterS → lfm2.5-thinking
#     decides: observe silently / popup an insight / request interrupt
#     (interrupt only auto-fires when allowInterrupt=true was configured AND
#     the agent owns the run; user-owned runs get a popup, never Ctrl+C).
#   * fresh user typing at the prompt (tail grew with a partial line) →
#     rate-limited intention-understanding popup.
#
# The monitor NEVER blocks the session; every LLM call is wrapped so a dead
# Ollama degrades to silence, not errors.

using FlootyPTYLayer

Base.@kwdef mutable struct MonitorConfig
    pollS::Float64 = 2.0
    interjectAfterS::Float64 = 10.0
    intentPopupCooldownS::Float64 = 30.0
    eventCooldownS::Float64 = 10.0    # new output/command completion
    ps2GraceS::Float64 = 3.0          # heredoc/quote continuation before Ctrl+C
    decisionAfterS::Float64 = 6.0     # ambiguous prompt → decision model
    decisionThreshold::Float64 = 0.8
    hazardTauS::Float64 = 5.0
    allowInterrupt::Bool = false      # auto-Ctrl+C on agent-owned long runs
    maxTailChars::Int = 900
end

# ---- inter-agent channel ----------------------------------------------------
# The monitor and the agent are two models on the SAME session. This is how they
# actually talk to each other (the user asked for it): the monitor's insights are
# queued as notes the agent reads at the top of its next turn, and the agent
# publishes a one-paragraph BRIEF (its task + last action) that the monitor's
# prompt carries, so its comments are about what the agent is trying to do.
const MONITOR_NOTES = IdDict{Any,Vector{String}}()
const MONITOR_NOTES_LOCK = ReentrantLock()
const AGENT_BRIEF = IdDict{Any,String}()
const AGENT_BRIEF_LOCK = ReentrantLock()

"Durably note an insight so the AGENT sees it on its next turn.
`source` names the INTERFACE monitor (chat or terminal) that produced it."
function pushMonitorNote!(sess, text::AbstractString; source::Symbol = :chat)
    isempty(strip(text)) && return nothing
    label = "[" * string(source) * "] "
    lock(MONITOR_NOTES_LOCK) do
        push!(get!(Vector{String}, MONITOR_NOTES, sess), label * String(strip(text)))
    end
    return nothing
end

"Terminal-interface monitor thinking event (the page routes it separately)."
_terminal_thinking(sid, text) =
    AgentMonitorThinkingEvent(sid, text; monitor = :terminal)

"Terminal-interface monitor note for the driver's next turn."
_terminal_note(sess, text) = pushMonitorNote!(sess, text; source = :terminal)

"Drain and clear the notes for `sess` (oldest first)."
takeMonitorNotes!(sess) = lock(MONITOR_NOTES_LOCK) do
    pop!(MONITOR_NOTES, sess, String[])
end

# Monitor-requested interruption of the RUNNING SEND. The driver polls this
# while blocked in agentWriteAndWait; a request older than the TTL is ignored
# (it belonged to a statement that already finished).
const MONITOR_INTERRUPTS = IdDict{Any,Tuple{String,Float64}}()
const MONITOR_INTERRUPTS_LOCK = ReentrantLock()
const MONITOR_INTERRUPT_TTL_S = 10.0

function requestMonitorInterrupt!(sess, reason::AbstractString)
    lock(MONITOR_INTERRUPTS_LOCK) do
        MONITOR_INTERRUPTS[sess] = (String(strip(reason)), time())
    end
    return nothing
end

function takeMonitorInterrupt!(sess; maxAgeS::Real = MONITOR_INTERRUPT_TTL_S)
    return lock(MONITOR_INTERRUPTS_LOCK) do
        v = pop!(MONITOR_INTERRUPTS, sess, nothing)
        v === nothing && return ""
        (time() - v[2]) > maxAgeS && return ""
        return v[1]
    end
end

function clearMonitorInterrupt!(sess)
    lock(MONITOR_INTERRUPTS_LOCK) do
        delete!(MONITOR_INTERRUPTS, sess)
    end
    return nothing
end

setAgentBrief!(sess, text::AbstractString) = lock(AGENT_BRIEF_LOCK) do
    AGENT_BRIEF[sess] = String(text)
    return nothing
end

agentBriefFor(sess) = lock(AGENT_BRIEF_LOCK) do
    get(AGENT_BRIEF, sess, "")
end

"Prompt prefix carrying the agent's brief, or an empty string when there is none."
function agentBriefPrompt(sess)::String
    brief = strip(agentBriefFor(sess))
    isempty(brief) && return ""
    return "AGENT CONTEXT (what the commissioned agent is doing right now):\n" *
           brief * "\n\n"
end

Base.@kwdef mutable struct MonitorState
    sess::ReplSession
    # `nothing` = resolve `monitorCompleteFn(sessionModelConfig(sess))` per call,
    # so the monitor follows its TAB's model (a Function field rejected the
    # default and aborted the session hook before the standing agent started).
    completeFn::Union{Nothing,Function}
    cfg::MonitorConfig
    onEvent::Function
    stop::Bool
    task::Union{Task,Nothing}
    lastTailLen::Int
    lastIntentPopupAt::Float64
    lastInsightAt::Float64
    busySince::Float64        # 0 = at a prompt; else when the run started
    busyNotified::Bool        # this run episode already reached the model
    lastPendingText::String   # user's partial prompt line, for intent changes
    announced::Bool
    seenPrompt::Bool         # false during login/REPL boot; boot is not a "run"
    eventArmed::Bool         # baseline established at the first real prompt
    lastEventTailLen::Int    # output/command-completion cursor
    lastEventAt::Float64     # event-model cooldown
    ps2Since::Float64        # agent-owned PS2 continuation, 0 = none
    ps2Notified::Bool
    decisionInflight::Bool
    decisionLastAt::Float64
    decisionNotified::Bool
    # Diagnostics/concurrency: `ticks` increments every sample; model calls run
    # in their own task so a slow model never freezes the watcher.
    ticks::Int
    inflight::Bool
    inflightTask::Union{Nothing,Task}
    inflightSince::Float64
    evalStallNotified::Bool
    modelWaitNotified::Bool
    parseFailureNotified::Bool
    pagerNotified::Bool
    evalLock::ReentrantLock
end

# ONE MONITOR PER SESSION (mirrors the per-session agent runners).
const MONITOR_STATES = IdDict{Any,MonitorState}()
const MONITOR_STATES_LOCK = ReentrantLock()

const MONITOR_HARNESS_CONTEXT = """
HARNESS CONTEXT — TERMINAL USE:
- You advise an agent driving a live terminal. The agent sees only the visible
  viewport snapshot; output that leaves the screen is not shown to it again.
- For a long output, recommend an INTERACTIVE PAGER: `bat FILE`, `git log`,
  `git --paginate log`, or `less FILE`. The agent must start it with `type`
  (command + newline), not `send`; `send` waits for a shell prompt hidden by
  the pager. Then `type` `space`/`b` to page, `/` to search, `q` to quit, with
  `wait` after each key. Advise quitting it before the next action. Never leave
  a pager open, and never recommend `--no-pager`/`--paging=never` for a long
  output.
- For a known small range, `sed -n 'A,Bp' FILE`, `head -n N`, `tail -n N`,
  `grep -n`, or `wc -l` is fine.
- Never suggest `cat FILE` or "read the whole file" unless the file is tiny.
- Commands run in a terminal; keep advice executable and terse.
"""

const MONITOR_SYSTEM_PROMPT = """
You watch output of one running Julia REPL statement and answer for the USER.
Reply with EXACTLY ONE JSON object, no markdown:
{"decision":"observe","confidence":0.0}                 nothing worth saying yet
{"decision":"insight","title":"<t>","body":"<b>","confidence":0.0} short useful observation
{"decision":"interrupt","reason":"<why>","confidence":0.0} this run should be stopped
Be terse. Only speak when there is something real: hang, runaway memory,
obvious wrong direction, or a completed long computation worth summarizing.

$MONITOR_HARNESS_CONTEXT"""

"""
    startMonitor!(sess; completeFn = nothing, kwargs...) :: Bool

Start watching `sess` — ONE PER SESSION, like the standing agents. Returns
false when `sess` is already watched. Feedback events flow through
`onEvent(::AgentFeedback)` — the default bridges them into the WebView popup
stack when the UI is live.
"""
function startMonitor!(sess::ReplSession;
                       completeFn::Union{Nothing,Function} = nothing,
                       onEvent::Function = defaultMonitorEventBridge!,
                       cfg::MonitorConfig = MonitorConfig())
    # If the session is ALREADY at its prompt, the first command sent after
    # startMonitor! must be watched. Only a monitor started before the login/boot
    # prompt has seenPrompt = false.
    ready = try
        atIdlePrompt(sess, tailTextOf(sess))
    catch
        false
    end
    state = MonitorState(sess = sess, completeFn = completeFn, cfg = cfg,
                         onEvent = onEvent, stop = false, task = nothing,
                         lastTailLen = _tailLen(sess),
                         lastIntentPopupAt = 0.0, lastInsightAt = 0.0,
                         busySince = 0.0, busyNotified = false,
                         lastPendingText = "", announced = false,
                         seenPrompt = ready, eventArmed = false,
                         lastEventTailLen = _tailLen(sess), lastEventAt = 0.0,
                         ps2Since = 0.0, ps2Notified = false,
                         decisionInflight = false, decisionLastAt = 0.0,
                         decisionNotified = false, ticks = 0, inflight = false, inflightTask = nothing,
                         inflightSince = 0.0, evalStallNotified = false,
                         modelWaitNotified = false, parseFailureNotified = false,
                         pagerNotified = false,
                         evalLock = ReentrantLock())
    ok = lock(MONITOR_STATES_LOCK) do
        haskey(MONITOR_STATES, sess) && return false
        MONITOR_STATES[sess] = state
        return true
    end
    ok || return false
    state.task = @async begin
        try
            monitorLoop(state)
        finally
            lock(MONITOR_STATES_LOCK) do
                if haskey(MONITOR_STATES, sess) &&
                   MONITOR_STATES[sess] === state
                    delete!(MONITOR_STATES, sess)
                end
            end
        end
    end
    return true
end

"""
    stopMonitor!([sess])

Stop monitors: `sess`'s watcher when given, otherwise ALL of them.
Idempotent; stopped monitors deregister themselves on unwind.
"""
function stopMonitor!(sess::Union{Nothing,ReplSession} = nothing)
    targets = lock(MONITOR_STATES_LOCK) do
        if sess === nothing
            collect(values(MONITOR_STATES))
        else
            s = get(MONITOR_STATES, sess, nothing)
            s === nothing ? MonitorState[] : MonitorState[s]
        end
    end
    for state in targets
        state.stop = true
        waitBoundedTask(state.task, 5.0, "monitor loop")
        # A model call may still be running in its own task; bound teardown too,
        # instead of letting a stalled client hang the app close.
        waitBoundedTask(state.inflightTask, 5.0, "monitor evaluation")
    end
    return nothing
end

monitorRunning() = lock(MONITOR_STATES_LOCK) do
    !isempty(MONITOR_STATES)
end

function monitorLoop(state::MonitorState)
    failures = 0
    reported = false
    while !state.stop
        sleep(state.cfg.pollS)
        state.stop && break
        try
            sampleOnce!(state)
            failures = 0
        catch err
            # A broken session ends monitoring; anything else is usually
            # transient — but a persistent failure must not look like a healthy
            # quiet monitor. Surface the third consecutive failure once.
            state.sess.closed && break
            failures += 1
            @debug "flootyMonitor: sample failed" exception = err
            if failures >= 3 && !reported
                reported = true
                wv = activeTerminalUiWebview()
                wv === nothing || pushAgentEventToWindow(wv,
                    _terminal_thinking(monitorUiId(state), monitorPrefix(state) * "monitor sampling failed repeatedly: " * sprint(showerror, err)))
                try
                    _terminal_note(state.sess, monitorPrefix(state) * "monitor sampling failed repeatedly: " * sprint(showerror, err))
                catch
                end
            end
        end
    end
    return nothing
end

"Wait for `t` at most `timeoutS`; true when it finished. Used by teardown."
function waitBoundedTask(t, timeoutS::Real, label::AbstractString)::Bool
    t === nothing && return true
    deadline = time() + Float64(timeoutS)
    while !istaskdone(t) && time() < deadline
        sleep(0.05)
    end
    if !istaskdone(t)
        @warn string(label, " did not finish within ", timeoutS,
                     "s; abandoning it (the process is closing)")
        return false
    end
    try
        wait(t)
    catch
    end
    return true
end

function _tailLen(sess::ReplSession)
    lock(() -> length(sess.tail.buf), sess.lock)
end

# tailText is not exported by FlootyPTYLayer; qualify instead of importing.
tailTextOf(sess::ReplSession) = FlootyPTYLayer.tailText(sess.tail)

"Recent tail only: prompt/app detection needs the last screen, not 1 MiB."
function tailRecentText(sess::ReplSession; maxBytes::Int = 8192)::String
    t = sess.tail
    return FlootyPTYLayer.tailTextFrom(t, max(0, FlootyPTYLayer.tailEnd(t) - maxBytes))
end

"""
    launchMonitorEval!(f, state) -> Bool

Run one model-backed monitor decision in a SEPARATE task. The sampling loop
keeps ticking while the model thinks; a slow monitor call must not blind the
watcher to the next episode. One evaluation per session at a time (the monitor
state, notes and cooldowns are shared).
"""
function launchMonitorEval!(f::Function, state::MonitorState)::Bool
    return lock(state.evalLock) do
        state.inflight && return false
        state.inflight = true
        state.inflightSince = time()
        state.evalStallNotified = false
        state.inflightTask = @async begin
            try
                f()
            catch err
                @debug "flootyMonitor: asynchronous evaluation failed" exception = err
                wv = activeTerminalUiWebview()
                wv === nothing || pushAgentEventToWindow(wv,
                    _terminal_thinking(monitorUiId(state), monitorPrefix(state) * "monitor evaluation failed: " * sprint(showerror, err)))
                try
                    _terminal_note(state.sess, monitorPrefix(state) * "monitor evaluation failed: " * sprint(showerror, err))
                catch
                end
            finally
                lock(state.evalLock) do
                    state.inflight = false
                    state.inflightSince = 0.0
                end
            end
        end
        return true
    end
end

const PAGER_STATUS_RE = r"\(END\)|--\s*(?:More|less)\s*--|lines \d+-\d+/\d+|(?m)^\s*:\s*$"

"Pager status text is live only near the end of the current screen."
function pagerActive(sess, tail::AbstractString)::Bool
    recent = last(String(tail), 2000)
    # less/more status text, or the reverse-video filename line that macOS less
    # paints at the bottom when it does NOT take the alternate screen.
    status = occursin(PAGER_STATUS_RE, recent) ||
             occursin(r"\e\[7m[^\e\r\n]*\e\[27m", recent)
    status || return false
    # At an idle shell prompt the reverse-video `%`/prompt is NOT a pager. The
    # status text only counts while the prompt is absent.
    return try
        !atIdlePrompt(sess, tail)
    catch
        false
    end
end

"One monitor tick."
function sampleOnce!(state::MonitorState)
    sess = state.sess
    state.ticks += 1
    nowT = time()
    # The Monitor tab must never look dead: announce attachment once the tab
    # has bound (the first tick is after pollS).
    if !state.announced
        state.announced = true
        wv = activeTerminalUiWebview()
        wv === nothing || pushAgentEventToWindow(
            wv, _terminal_thinking(monitorUiId(state), monitorPrefix(state) * "monitor attached — watching long runs and user intent"))
    end

    # A pager is a full-screen app with a different interaction contract: it
    # needs `type` keys (space/b/q), never `send` (which waits for a hidden
    # shell prompt). Detect it before the user-owned full-screen early return so
    # the Monitor tab and the driver both see the pager signal.
    pagerTail = try
        tailRecentText(sess)
    catch
        ""
    end
    pager = try pagerActive(sess, pagerTail) catch; false end
    if pager
        if !state.pagerNotified
            state.pagerNotified = true
            wv = activeTerminalUiWebview()
            msg = "PAGER ACTIVE — navigate with {\"action\":\"type\"} keys: " *
                  "space = next page, b = previous, / = search, q = quit. " *
                  "Do NOT use send: the pager hides the shell prompt."
            wv === nothing || pushAgentEventToWindow(wv,
                _terminal_thinking(monitorUiId(state), monitorPrefix(state) * msg))
            try _terminal_note(sess, msg) catch end
        end
    else
        state.pagerNotified = false
    end

    # A USER driving a full-screen app (micro, broot, vim, less) is not a
    # terminal episode: skip the tail copy/prompt parsing entirely. The old
    # 2 s tick copied the whole 1 MiB rolling tail while the user typed, which
    # added GC/parse pauses exactly when input latency is visible.
    if try
        currentState(sess.control) == :user && inAltScreen(sess)
    catch
        false
    end
        state.busySince = 0.0
        state.busyNotified = false
        return nothing
    end

    # --- episode 1: a statement/command that has NOT returned to a prompt ---
    # `sess.pending` only covers sentinel evals (`evalInRepl`). The agent's
    # `send` and the user's shell commands run as plain PTY input, so the old
    # pending-only check meant the monitor NEVER reacted to real work (observed:
    # `sleep 3` produced 0 monitor calls). Detect the episode from the prompt
    # state instead: not at an idle prompt and not inside a full-screen app.
    tailNow = pagerTail
    pendingText = try
        FlootyPTYLayer.pendingInputLine(sess)
    catch
        ""
    end
    pendingCount = lock(() -> length(sess.pending), sess.lock)
    atPrompt = try
        atIdlePrompt(sess, tailNow)
    catch
        false
    end
    appOwns = try
        inAltScreen(sess) || FlootyPTYLayer._tailLooksLikeApp(tailNow)
    catch
        false
    end
    atPrompt && (state.seenPrompt = true)
    # A PARTIAL prompt line is not a running statement: intent (episode 2) owns it.
    # Before the FIRST prompt (SSH login, Julia boot) there is no command to
    # watch; counting that as a long run made the monitor invent one.
    busy = pendingCount > 0 ||
        (state.seenPrompt && !atPrompt && !appOwns && isempty(strip(pendingText)))
    if busy
        state.busySince == 0.0 && (state.busySince = nowT)
        runFor = nowT - state.busySince
        if runFor >= state.cfg.interjectAfterS && !state.busyNotified
            state.busyNotified = true
            # Factual, ALWAYS visible in the Monitor tab, independent of the
            # model: a monitor that only speaks when a model agrees looks dead.
            wv = activeTerminalUiWebview()
            wv === nothing || pushAgentEventToWindow(wv, _terminal_thinking(
                monitorUiId(state),
                monitorPrefix(state) * "long run — $(round(runFor; digits=0))s without a prompt"))
            # ...and put the same fact in the DRIVER's note channel. Waiting is
            # legitimate (a Julia precompile can take minutes); the driver should
            # know it is a long run, not a silent failure. This is advice, not a
            # deterministic stop.
            fact = "long run — $(round(runFor; digits=0))s without a prompt " *
                   "(the command may still be working; wait, or interrupt only " *
                   "if it is genuinely stuck)"
            _terminal_note(sess, fact)
            try forwardSplitInsight!(sess, fact) catch end
            launchMonitorEval!(state) do
                handleLongRun!(state, runFor)
            end
        end
    else
        state.busySince = 0.0
        state.busyNotified = false
    end

    # --- episode 1a: terminal EVENT — new output / command completion ----
    # Long runs are not the only terminal event. A quick command, a user's
    # shell comment, or an agent's output returns to the prompt between long-run
    # evaluations; without this cursor the Terminal monitor stayed silent while
    # the Chat monitor invented comments from the terminal snapshot.
    eventTailLen = _tailLen(sess)
    if atPrompt && !appOwns && isempty(strip(pendingText)) && state.seenPrompt
        if !state.eventArmed
            state.eventArmed = true
            state.lastEventTailLen = eventTailLen
        elseif eventTailLen < state.lastEventTailLen
            state.lastEventTailLen = eventTailLen
        elseif eventTailLen > state.lastEventTailLen
            if !state.inflight &&
               (nowT - state.lastEventAt) >= state.cfg.eventCooldownS
                state.lastEventTailLen = eventTailLen
                state.lastEventAt = nowT
                launchMonitorEval!(state) do
                    handleTerminalEvent!(state)
                end
            else
                # Model busy/cooldown: consume this output, don't queue a stale
                # burst for the next evaluation.
                state.lastEventTailLen = eventTailLen
            end
        end
    end

    # --- episode 1a2: heredoc/quote continuation --------------------------
    # A send can leave the shell at PS2 (truncated heredoc, quote, cmdsubst).
    # The driver then waits for a prompt that will never return. When the agent
    # owns input, recover deterministically after a short grace period instead
    # of treating it as a long-running command.
    ps2 = try
        FlootyPTYLayer.shellAtPS2(sess)
    catch
        false
    end
    agentOwns = try
        currentState(sess.control) != :user
    catch
        true
    end
    if ps2 && state.seenPrompt && agentOwns
        state.ps2Since == 0.0 && (state.ps2Since = nowT)
        if !state.ps2Notified &&
           (nowT - state.ps2Since) >= state.cfg.ps2GraceS
            state.ps2Notified = true
            wv = activeTerminalUiWebview()
            wv === nothing || pushAgentEventToWindow(wv, _terminal_thinking(
                monitorUiId(state),
                monitorPrefix(state) * "heredoc/PS2 continuation — recovering with Ctrl+C"))
            try
                note = "heredoc/PS2 continuation detected; Ctrl+C was sent " *
                       "(or finish with the closing delimiter) before any further command"
                _terminal_note(sess, note)
                forwardSplitInsight!(sess, note)
            catch
            end
            recovered = try
                FlootyPTYLayer.recoverStuckContinuation!(sess)
            catch
                false
            end
            wv === nothing || pushAgentEventToWindow(wv, _terminal_thinking(
                monitorUiId(state),
                monitorPrefix(state) * (recovered ? "recovered to a prompt" :
                    "could not recover the continuation")))
        end
    else
        if state.ps2Notified
            note = "heredoc/PS2 continuation cleared — the terminal is at an " *
                   "idle prompt; do not assume it is still open"
            wv = activeTerminalUiWebview()
            wv === nothing || pushAgentEventToWindow(wv, _terminal_thinking(
                monitorUiId(state), monitorPrefix(state) * note))
            try
                _terminal_note(sess, note)
                forwardSplitInsight!(sess, note)
            catch
            end
        end
        state.ps2Since = 0.0
        state.ps2Notified = false
    end

    # --- episode 1a3: ambiguous prompt — decision model fallback ----------
    # Static rules said "not at a prompt" but also "not PS2". After a grace
    # period ask a decision model; its PS2 probability is combined with a time
    # hazard (confidence evolves by elapsed bucket) before we tell the driver.
    ambiguous = state.seenPrompt && !atPrompt && !ps2 && !appOwns &&
                isempty(strip(pendingText))
    if ambiguous
        elapsed = state.busySince > 0.0 ? nowT - state.busySince : 0.0
        if !state.decisionNotified && !state.decisionInflight &&
           elapsed >= state.cfg.decisionAfterS &&
           (nowT - state.decisionLastAt) >= state.cfg.decisionAfterS
            state.decisionInflight = true
            state.decisionLastAt = nowT
            tail = tailNow
            kind = try sessionKind(sess) catch; :unknown end
            @async begin
                dec = try
                    promptStatusDecision(tail = tail, kind = kind,
                        pending = pendingText, at_prompt = atPrompt, ps2 = ps2,
                        elapsed_s = elapsed, silence_s = elapsed,
                        grace_s = state.cfg.ps2GraceS,
                        tau_s = state.cfg.hazardTauS)
                catch
                    nothing
                end
                state.decisionInflight = false
                if dec !== nothing
                    wv = activeTerminalUiWebview()
                    wv === nothing || pushAgentEventToWindow(wv,
                        AgentMonitorConfidenceEvent(monitorUiId(state),
                            clamp(dec.ps2_posterior, 0.0, 1.0), :prompt))
                end
                if dec !== nothing && dec.ps2_posterior >= state.cfg.decisionThreshold &&
                   dec.ps2 > dec.running
                    state.decisionNotified = true
                    note = "prompt decision: likely incomplete PS2 " *
                        "(p_ps2=$(round(dec.ps2; digits = 2)), " *
                        "posterior=$(round(dec.ps2_posterior; digits = 2)), " *
                        "elapsed=$(round(dec.elapsed_s; digits = 0))s); " *
                        "do not repeat the command"
                    wv = activeTerminalUiWebview()
                    wv === nothing || pushAgentEventToWindow(wv, _terminal_thinking(
                        monitorUiId(state), monitorPrefix(state) * note))
                    try
                        _terminal_note(sess, note)
                        forwardSplitInsight!(sess, note)
                    catch
                    end
                end
            end
        end
    else
        state.decisionNotified = false
        state.decisionLastAt = 0.0
    end

    # --- episode 1b: the DRIVER is waiting on its model -------------------
    # A terminal at a prompt is not "busy", so without this heartbeat a stalled
    # completion is invisible to the monitor. Advice only; never a stop.
    modelWait = agentModelWaitFor(sess)
    if modelWait > 0.0
        waited = nowT - modelWait
        if waited >= state.cfg.interjectAfterS && !state.modelWaitNotified
            state.modelWaitNotified = true
            wv = activeTerminalUiWebview()
            wv === nothing || pushAgentEventToWindow(wv,
                _terminal_thinking(monitorUiId(state), monitorPrefix(state) * "driver waiting on the model for $(round(waited; digits=0))s"))
            try
                _terminal_note(sess, "driver has been waiting on the model for " *
                    "$(round(waited; digits=0))s; the terminal is idle meanwhile")
            catch
            end
        end
    else
        state.modelWaitNotified = false
    end

    # --- episode 1b2: the DRIVER is emitting unparseable replies ----------
    # No PTY output is involved; without this the monitor looks healthy while
    # the model parrots malformed JSON turn after turn.
    parseCount, parseLast = agentParseFailureFor(sess)
    if parseCount > 0
        if parseCount >= 2 && !state.parseFailureNotified
            state.parseFailureNotified = true
            detail = "driver emitted " * string(parseCount) *
                     " consecutive unparseable replies; last: " *
                     first(replace(parseLast, r"\s+" => " "), 160)
            advice = if occursin("<thinking>", parseLast)
                "change approach: output the JSON object only — no <thinking>, " *
                "markdown, or prose in the content."
            elseif occursin('{', parseLast) && !occursin('}', parseLast)
                "change approach: the JSON is truncated. Split the command " *
                "into a shorter send (or use `type` for a pager) and close the object."
            else
                "change approach: emit ONE short JSON object; no prose, fence, " *
                "or repeated command. For a pager use `type` space/b/q."
            end
            wv = activeTerminalUiWebview()
            wv === nothing || pushAgentEventToWindow(wv,
                _terminal_thinking(monitorUiId(state), detail * " — " * advice))
            try
                _terminal_note(sess, detail * " — " * advice)
            catch
            end
        end
    else
        state.parseFailureNotified = false
    end

    # --- episode 1c: a monitor evaluation itself is stuck -----------------
    stall = lock(state.evalLock) do
        if state.inflight && state.inflightSince > 0.0 &&
           (nowT - state.inflightSince) >= max(30.0, 2 * state.cfg.interjectAfterS) &&
           !state.evalStallNotified
            state.evalStallNotified = true
            nowT - state.inflightSince
        else
            0.0
        end
    end
    if stall > 0.0
        wv = activeTerminalUiWebview()
        wv === nothing || pushAgentEventToWindow(wv,
            _terminal_thinking(monitorUiId(state), monitorPrefix(state) * "monitor evaluation has been running for $(round(stall; digits=0))s"))
        try
            _terminal_note(sess, monitorPrefix(state) * "monitor evaluation has been running for $(round(stall; digits=0))s")
        catch
        end
    end

    # --- episode 2: user typing at the prompt ----------------------------
    # USER-OWNED is the point: after a run ends (a stop, a done, a
    # Take Over) the control machine is `:user` and `inputTargetFor` is
    # `inputPtyOwns`. Requiring `inputAgentEditor` here meant monitoring went
    # silent exactly when the user started typing. The prompt line is the
    # signal (an idle prompt has no pending text; the agent's own writes are
    # `:agent`, not `:user`).
    tailLen = _tailLen(sess)
    grew = tailLen > state.lastTailLen
    state.lastTailLen = tailLen
    # Growth alone is racy: the first tick can consume it before the PTY
    # reflects the typed line. A CHANGED partial line is the durable signal.
    pendingChanged = !isempty(strip(pendingText)) &&
        pendingText != state.lastPendingText
    state.lastPendingText = pendingText
    if (grew || pendingChanged) && currentState(sess.control) == :user &&
       !isempty(strip(pendingText)) &&
       (nowT - state.lastIntentPopupAt) > state.cfg.intentPopupCooldownS
        state.lastIntentPopupAt = nowT
        launchMonitorEval!(state) do
            emitIntentInsight!(state)
        end
    end
    return nothing
end

"""
The monitor's completion, resolved PER CALL so a per-tab model is honoured:
`startMonitor!` leaves it unset and the tab's current `sessionModelConfig` picks
the model (the monitor follows the actor it watches, not a process global).
"""
monitorFn(state::MonitorState) =
    state.completeFn === nothing ?
    monitorCompleteFn(sessionModelConfig(state.sess)) : state.completeFn

"""
    monitorUiId(state)

A split child's monitor reports into the PARENT arena's Terminal stream; its
own hidden pane would swallow the events. The child's own agent notes/feedback
still target the child.
"""
function monitorUiId(state::MonitorState)::String
    parent = try
        splitParentSession(state.sess)
    catch
        nothing
    end
    parent === nothing ? sessionIdFor(state.sess) : sessionIdFor(parent)
end

monitorIsChild(state::MonitorState) = try
    splitParentSession(state.sess) !== nothing
catch
    false
end
monitorPrefix(state::MonitorState) = monitorIsChild(state) ? "[child] " : ""

"Publish the latest monitor confidence for its stream (radial gauge in the UI)."
function publishMonitorConfidence!(session_id::AbstractString, decision, source::Symbol)
    c = get(decision, "confidence", nothing)
    c isa Number || return nothing
    wv = activeTerminalUiWebview()
    wv === nothing && return nothing
    pushAgentEventToWindow(wv, AgentMonitorConfidenceEvent(
        String(session_id), clamp(Float64(c), 0.0, 1.0), source))
    return nothing
end

function handleLongRun!(state::MonitorState, runFor::Float64)
    sess = state.sess
    snapText = string(agentSnapshot(sess; tailChars = state.cfg.maxTailChars))
    decision = try
        reply = monitorFn(state)(OllamaMessage[
            OllamaMessage(role = "system", content = MONITOR_SYSTEM_PROMPT),
            OllamaMessage(role = "user", content = agentBriefPrompt(state.sess) *
                    "This statement has been running $(round(runFor; digits=1))s." *
                    "\nTERMINAL SNAPSHOT\n" * snapText),
        ])
        # The monitor's reasoning goes to the MONITOR stream of the chat rail —
        # its own voice, never the agent's transcript.
        thinking = extractThinking(reply)
        if !isempty(strip(thinking))
            pushAgentEventToWindow(activeTerminalUiWebview(),
                _terminal_thinking(monitorUiId(state), monitorPrefix(state) * strip(thinking)))
        end
        extractActionLike(reply)
    catch
        nothing
    end
    decision === nothing && return nothing
    publishMonitorConfidence!(monitorUiId(state), decision, :terminal)

    dec = lowercase(String(get(decision, :decision, "observe")))
    if dec != "insight" && dec != "interrupt"
        wv = activeTerminalUiWebview()
        wv === nothing || pushAgentEventToWindow(wv, _terminal_thinking(
            monitorUiId(state), monitorPrefix(state) * "observe — " * dec))
    end
    if dec == "insight"
        (time() - state.lastInsightAt) < 5.0 && return nothing
        state.lastInsightAt = time()
        body = String(get(decision, :body, ""))
        _terminal_note(state.sess, body)          # the AGENT reads this next turn
        # A standalone session (probes, or a tab not yet in the tree) has no
        # parent/split to forward to; that must not abort the insight itself.
        try forwardSplitInsight!(state.sess, body) catch end
        try
            splitParentSession(state.sess) === nothing &&
                forwardParentInsight!(state.sess, body)
        catch
        end
        state.onEvent(AgentFeedback(
            title = String(get(decision, :title, "Insight")),
            body = body,
            kind = "info",
            sessionId = monitorUiId(state)))
    elseif dec == "interrupt"
        reason = String(get(decision, :reason, "long-running"))
        if currentState(sess.control) == :user
            # Never Ctrl+C user-owned work: ask via popup instead.
            state.onEvent(AgentFeedback(
                title = "Interrupt suggested",
                body = "Statement running $(round(runFor; digits=0))s — " *
                       reason * ". Click the terminal and press Ctrl+C to stop.",
                kind = "warn",
                sessionId = monitorUiId(state)))
        elseif state.cfg.allowInterrupt
            sent, detail = agentInterject!(sess, reason; force = true)
            state.onEvent(AgentFeedback(title = "Flooty Agent",
                                        body = detail * " — " * reason,
                                        kind = "interrupt",
                                        sessionId = monitorUiId(state)))
        else
            # The driver is polling the monitor DURING its send; queue the
            # interrupt there and let it stop the statement deliberately.
            requestMonitorInterrupt!(sess, reason)
            _terminal_note(sess, "INTERRUPT requested: " * reason)
            state.onEvent(AgentFeedback(
                title = "Interrupt requested",
                body = "Statement running $(round(runFor; digits=0))s — " *
                       reason * ". The driver will interrupt the send.",
                kind = "warn",
                sessionId = monitorUiId(state)))
        end
    end
    return nothing
end

const TERMINAL_EVENT_PROMPT = """
You watch ONE terminal session. A command/output just finished and the pane is
back at an idle prompt. Judge what happened from the snapshot and say whether
the user or agent should know something concrete.
Reply with EXACTLY ONE JSON object, no markdown:
{"decision":"observe","confidence":0.0}                 nothing worth saying
{"decision":"insight","title":"<t>","body":"<b>","confidence":0.0} a short useful observation
Do not discuss the chat input draft. Be terse; do not restate the command.

$MONITOR_HARNESS_CONTEXT"""

function handleTerminalEvent!(state::MonitorState)
    sess = state.sess
    snapText = string(agentSnapshot(sess; tailChars = state.cfg.maxTailChars))
    decision = try
        reply = monitorFn(state)(OllamaMessage[
            OllamaMessage(role = "system", content = TERMINAL_EVENT_PROMPT),
            OllamaMessage(role = "user", content = agentBriefPrompt(sess) *
                "New terminal output arrived at the prompt.\nTERMINAL SNAPSHOT\n" *
                snapText),
        ])
        thinking = extractThinking(reply)
        if !isempty(strip(thinking))
            pushAgentEventToWindow(activeTerminalUiWebview(),
                _terminal_thinking(monitorUiId(state), monitorPrefix(state) * strip(thinking)))
        end
        extractActionLike(reply)
    catch
        nothing
    end
    decision === nothing && return nothing
    publishMonitorConfidence!(monitorUiId(state), decision, :terminal)
    dec = lowercase(String(get(decision, :decision, "observe")))
    if dec != "insight"
        wv = activeTerminalUiWebview()
        wv === nothing || pushAgentEventToWindow(wv,
            _terminal_thinking(monitorUiId(state), monitorPrefix(state) * "observe — " * dec))
        return nothing
    end
    body = strip(String(get(decision, :body, "")))
    isempty(body) && return nothing
    _terminal_note(sess, body)
    try forwardSplitInsight!(sess, body) catch end
    try
        splitParentSession(sess) === nothing && forwardParentInsight!(sess, body)
    catch
    end
    state.onEvent(AgentFeedback(
        title = String(get(decision, :title, "Terminal")),
        body = body,
        kind = "info",
        sessionId = monitorUiId(state)))
    return nothing
end

function emitIntentInsight!(state::MonitorState)
    decision = try
        reply = monitorFn(state)(OllamaMessage[
            OllamaMessage(role = "system", content = MONITOR_SYSTEM_PROMPT),
            OllamaMessage(role = "user", content = agentBriefPrompt(state.sess) *
                    "The user just typed at the REPL prompt.\nTERMINAL SNAPSHOT\n" *
                    string(agentSnapshot(state.sess;
                                         tailChars = state.cfg.maxTailChars)) *
                    "\nIf you can infer their intention from what they are " *
                    "typing, reply insight with a SHORT title/body; otherwise observe."),
        ])
        # The monitor's reasoning goes to the MONITOR stream of the chat rail —
        # its own voice, never the agent's transcript.
        thinking = extractThinking(reply)
        if !isempty(strip(thinking))
            pushAgentEventToWindow(activeTerminalUiWebview(),
                _terminal_thinking(monitorUiId(state), monitorPrefix(state) * strip(thinking)))
        end
        extractActionLike(reply)
    catch
        nothing
    end
    decision === nothing && return nothing
    publishMonitorConfidence!(monitorUiId(state), decision, :terminal)
    dec = lowercase(String(get(decision, :decision, "observe")))
    if dec != "insight"
        wv = activeTerminalUiWebview()
        wv === nothing || pushAgentEventToWindow(wv, _terminal_thinking(
            monitorUiId(state), monitorPrefix(state) * "observe — " * dec))
        return nothing
    end
    body = String(get(decision, :body, ""))
    _terminal_note(state.sess, body)              # the AGENT reads this next turn
    try forwardSplitInsight!(state.sess, body) catch end
    try
        splitParentSession(state.sess) === nothing &&
            forwardParentInsight!(state.sess, body)
    catch
    end
    state.onEvent(AgentFeedback(
        title = String(get(decision, :title, "Agent")),
        body = body,
        kind = "info",
        sessionId = monitorUiId(state)))
    return nothing
end

"Tolerant parse of a monitor reply: find {..}, accept missing fields."
extractActionLike(text::AbstractString) = extractActionJson(stripThinking(text))

"""
Default event bridge: mirror feedback into the live WebView UI popup stack
(and stdout when no window). This is what makes the monitor visible like
Warp's ambient popups.
"""
function defaultMonitorEventBridge!(fb::AgentFeedback)
    wv = FlootyPTYLayer.activeTerminalUiWebview()
    if wv !== nothing
        # "info" IS the agent talking to the user (its insight/message); that is
        # text, so it also lands in the chat transcript — and in the session's
        # conversation, which is what later runs are seeded from. Warnings,
        # interrupts and failures are alerts, not conversation: popup only.
        if fb.kind == "info" && !isempty(strip(fb.body))
            # AMBIENT insight: popup + chat, but NOT the session conversation — a
            # commissioned agent must not inherit the monitor's voice or its
            # {decision:…} protocol.
            ev = AgentInsightEvent(fb.sessionId, fb.body; monitor = :terminal)
            FlootyPTYLayer.pushAgentEventToWindow(wv, ev)
        end
        FlootyPTYLayer.pushAgentFeedbackToWindow(wv, fb.title, fb.body, fb.kind;
                                                 sessionId = fb.sessionId)
    else
        @debug string("[agent-feedback] ($(fb.kind)) ", fb.title, ": ", fb.body)
    end
    return nothing
end
