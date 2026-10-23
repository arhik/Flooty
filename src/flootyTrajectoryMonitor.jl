# flootyTrajectoryMonitor.jl — watches the DRIVER AGENT's trajectory.
#
# Separate from the CHAT monitor (input draft) and the TERMINAL monitor (PTY
# state): this one consumes agent turns/tool calls/status lines and flags loops,
# repeated actions, no-progress stretches, model stalls, parse streaks and
# context pressure. Advisory only: it writes notes the driver reads next turn.

Base.@kwdef mutable struct TrajectoryConfig
    pollS::Float64 = 1.0
    cooldownS::Float64 = 12.0
    waitS::Float64 = 20.0
    contextAlert::Float64 = 0.85
    maxEvents::Int = 30
end

Base.@kwdef mutable struct TrajectoryMonitor
    sess::Any
    sid::String
    completeFn::Union{Nothing,Function} = nothing
    cfg::TrajectoryConfig = TrajectoryConfig()
    stop::Bool = false
    task::Union{Nothing,Task} = nothing
    events::Vector{String} = String[]
    task_text::String = ""
    dirty::Bool = false
    reason::String = ""
    last_eval_at::Float64 = 0.0
    inflight::Bool = false
    announced::Bool = false
    last_tool_sig::String = ""
    repeat_count::Int = 0
    last_turns::Int = 0
    last_wait_notified::Bool = false
    last_parse_notified::Bool = false
    lock::ReentrantLock = ReentrantLock()
end

const TRAJECTORY_MONITORS = IdDict{Any,TrajectoryMonitor}()
const TRAJECTORY_MONITORS_LOCK = ReentrantLock()

"UI id for trajectory events: a split child reports into its parent arena."
function trajectoryUiId(sess)::String
    if sess isa ReplSession
        parent = try
            splitParentSession(sess)
        catch
            nothing
        end
        parent === nothing || return sessionIdFor(parent)
        return sessionIdFor(sess)
    end
    return try
        String(sess.id)
    catch
        ""
    end
end

function trajectoryIsChild(sess)::Bool
    sess isa ReplSession || return false
    return try
        splitParentSession(sess) !== nothing
    catch
        false
    end
end

trajectoryPrefix(sess) = trajectoryIsChild(sess) ? "[child] " : ""

function trajectoryMonitorFor(sess)::TrajectoryMonitor
    return lock(TRAJECTORY_MONITORS_LOCK) do
        get!(TRAJECTORY_MONITORS, sess) do
            TrajectoryMonitor(sess = sess, sid = trajectoryUiId(sess))
        end
    end
end

function trajectoryAlive(m::TrajectoryMonitor)::Bool
    if m.sess isa ReplSession
        return !m.sess.closed
    end
    return sessionForId(m.sid) !== nothing
end

"Start the standing trajectory watcher for a session (idempotent)."
function startTrajectoryMonitor!(sess;
                                 completeFn::Union{Nothing,Function} = nothing,
                                 cfg::TrajectoryConfig = TrajectoryConfig())::Bool
    m = trajectoryMonitorFor(sess)
    m.completeFn = completeFn === nothing ? m.completeFn : completeFn
    m.cfg = cfg
    m.stop = false
    if !m.announced
        m.announced = true
        wv = activeTerminalUiWebview()
        if wv !== nothing
            pushAgentEventToWindow(wv, AgentMonitorThinkingEvent(
                trajectoryUiId(sess),
                trajectoryPrefix(sess) * "trajectory monitor attached — watching driver turns and tool calls";
                monitor = :trajectory))
        end
    end
    if m.task === nothing || istaskdone(m.task)
        m.task = @async trajectoryLoop(m)
    end
    return true
end

function stopTrajectoryMonitor!(sess)
    m = lock(TRAJECTORY_MONITORS_LOCK) do
        pop!(TRAJECTORY_MONITORS, sess, nothing)
    end
    m === nothing && return false
    m.stop = true
    return true
end

function trajectoryObserve!(sess, line::AbstractString; reason::AbstractString = "")
    line = strip(String(line))
    isempty(line) && return nothing
    m = trajectoryMonitorFor(sess)
    lock(m.lock) do
        push!(m.events, line)
        length(m.events) > m.cfg.maxEvents &&
            deleteat!(m.events, 1:(length(m.events) - m.cfg.maxEvents))
        if !isempty(reason)
            m.dirty = true
            m.reason = String(reason)
        end
    end
    return nothing
end

"Feed one tool call; repeated byte-identical calls are a trajectory smell."
function trajectoryToolCall!(sess, name::AbstractString, detail::AbstractString)
    m = trajectoryMonitorFor(sess)
    sig = String(name) * "|" * first(String(detail), 180)
    lock(m.lock) do
        if sig == m.last_tool_sig
            m.repeat_count += 1
        else
            m.last_tool_sig = sig
            m.repeat_count = 1
        end
    end
    trajectoryObserve!(sess, "tool " * String(name) * ": " * first(String(detail), 180))
    m.repeat_count >= 2 &&
        trajectoryObserve!(sess,
            "repeated action x" * string(m.repeat_count) * ": " * first(sig, 140);
            reason = "repeated action")
    return nothing
end

function trajectoryToolResult!(sess, ok::Bool, detail::AbstractString)
    trajectoryObserve!(sess, (ok ? "ok: " : "ERROR: ") * first(String(detail), 180);
                       reason = ok ? "" : "tool failure")
    return nothing
end

function trajectoryStatus!(sess, line::AbstractString)
    s = String(line)
    if startswith(s, "[turn ")
        mt = match(r"\[turn (\d+)\]", s)
        mt !== nothing && (trajectoryMonitorFor(sess).last_turns = parse(Int, mt.captures[1]))
    end
    reason = (startswith(s, "[warn]") || startswith(s, "[loop-guard]")) ? "loop warning" : ""
    trajectoryObserve!(sess, "status: " * first(s, 220); reason = reason)
    return nothing
end

function trajectoryContext!(sess, tokens::Integer, limit::Integer)
    limit > 0 || return nothing
    ratio = tokens / limit
    ratio >= trajectoryMonitorFor(sess).cfg.contextAlert &&
        trajectoryObserve!(sess,
            "context at $(round(Int, ratio * 100))% ($(tokens)/$(limit))";
            reason = "context pressure")
    return nothing
end

function trajectoryTask!(sess, task::AbstractString)
    m = trajectoryMonitorFor(sess)
    lock(m.lock) do
        m.task_text = first(String(task), 500)
    end
    return nothing
end

"Deterministic alternative for a malformed driver reply, using its trajectory."
function parseFailureAdvice(parseLast::AbstractString,
                            events::Vector{String})::String
    intent = ""
    for e in reverse(events)
        if startswith(e, "tool send:") || startswith(e, "tool type:")
            intent = e
            break
        end
    end
    shape = if occursin("<thinking>", parseLast)
        "Output the JSON object only; do not put <thinking> in the content."
    elseif occursin('{', parseLast) && !occursin('}', parseLast)
        "Your JSON was truncated. Shorten the command, split it at a pipe, " *
        "and close the object; avoid nested quoting."
    else
        "Use one short JSON object; no prose, fence, or repeated command."
    end
    return (isempty(intent) ? "" : "Last intent: " * first(intent, 220) * ". ") *
           "Change approach: " * shape *
           " If a pager is open, use {\"action\":\"type\"} space/b/q, never send."
end

function trajectoryLoop(m::TrajectoryMonitor)
    while !m.stop
        sleep(m.cfg.pollS)
        m.stop && break
        try
            trajectoryAlive(m) || (m.stop = true; break)
            if m.sess isa ReplSession
                wait = try agentModelWaitFor(m.sess) catch; 0.0 end
                if wait >= m.cfg.waitS && !m.last_wait_notified
                    m.last_wait_notified = true
                    trajectoryObserve!(m.sess,
                        "driver waiting on the model $(round(wait; digits = 0))s";
                        reason = "model stall")
                elseif wait <= 0
                    m.last_wait_notified = false
                end
                count, parseLast = try agentParseFailureFor(m.sess) catch; (0, "") end
                if count >= 2 && !m.last_parse_notified
                    m.last_parse_notified = true
                    events = lock(m.lock) do
                        copy(m.events)
                    end
                    advice = parseFailureAdvice(parseLast, events)
                    trajectoryObserve!(m.sess,
                        "unparseable replies x" * string(count) * " — " * advice;
                        reason = "parse failure streak")
                    # Deterministic, not model-gated: the driver gets the
                    # alternative on its next turn even if the monitor model is
                    # slow or returns no insight.
                    try pushMonitorNote!(m.sess, "unparseable replies x" * string(count) * " — " * advice; source = :trajectory) catch end
                    wv = activeTerminalUiWebview()
                    wv === nothing || pushAgentEventToWindow(wv,
                        AgentMonitorThinkingEvent(trajectoryUiId(m.sess),
                            trajectoryPrefix(m.sess) * "parse failure: " * advice;
                            monitor = :trajectory))
                elseif count == 0
                    m.last_parse_notified = false
                end
            end
            should = lock(m.lock) do
                m.dirty && !m.inflight &&
                    (time() - m.last_eval_at >= m.cfg.cooldownS)
            end
            should || continue
            snapshot, reason = lock(m.lock) do
                m.dirty = false
                m.last_eval_at = time()
                m.inflight = true
                (copy(m.events), m.reason)
            end
            @async begin
                try
                    evaluateTrajectory!(m, snapshot, reason)
                finally
                    lock(m.lock) do
                        m.inflight = false
                    end
                end
            end
        catch err
            @debug "trajectory monitor tick failed" exception = err
        end
    end
    return nothing
end

const TRAJECTORY_SYSTEM_PROMPT = """
You watch the DRIVER AGENT of a coding assistant. You see its task, recent turns,
tool calls/results and status counters. Decide whether the trajectory needs a
concrete course correction.
Look for: repeated identical actions, tool failures with no adaptation, no
progress over several turns, wrong target/session, model stalls, parse-failure
streaks, or context pressure.
Reply with EXACTLY ONE JSON object, no markdown:
{"decision":"observe","confidence":0.0}                 nothing worth saying
{"decision":"insight","title":"<t>","body":"<b>","confidence":0.0} one short, actionable observation
Never request an interrupt. Be terse; do not restate the task or the last line.

$MONITOR_HARNESS_CONTEXT"""

function evaluateTrajectory!(m::TrajectoryMonitor, events::Vector{String},
                             reason::AbstractString)
    wv = activeTerminalUiWebview()
    sess = m.sess
    sid = trajectoryUiId(sess)
    prefix = trajectoryPrefix(sess)
    brief = if sess isa ReplSession
        try agentBriefPrompt(sess) catch; "" end
    else
        isempty(m.task_text) ? "" : "TASK: " * m.task_text * "\n"
    end
    body = brief * "EVENT: " * reason * "\nRECENT TRAJECTORY:\n" *
           join(events, "\n")
    try
        fn = m.completeFn
        fn === nothing && (fn = monitorCompleteFn(sessionModelConfig(sess)))
        reply = fn(OllamaMessage[
            OllamaMessage(role = "system", content = TRAJECTORY_SYSTEM_PROMPT),
            OllamaMessage(role = "user", content = body),
        ])
        thinking = strip(extractThinking(reply))
        if !isempty(thinking)
            pushAgentEventToWindow(wv, AgentMonitorThinkingEvent(
                sid, prefix * thinking; monitor = :trajectory))
        end
        dec = extractActionJson(stripThinking(reply))
        dec === nothing || publishMonitorConfidence!(sid, dec, :trajectory)
        if dec === nothing
            pushAgentEventToWindow(wv, AgentMonitorThinkingEvent(
                sid, prefix * "observe — no structured insight"; monitor = :trajectory))
            return nothing
        end
        dw = lowercase(String(get(dec, "decision", "observe")))
        if dw != "insight"
            pushAgentEventToWindow(wv, AgentMonitorThinkingEvent(
                sid, prefix * "observe — " * dw; monitor = :trajectory))
            return nothing
        end
        insight = strip(String(get(dec, "body", "")))
        isempty(insight) && return nothing
        pushMonitorNote!(sess, insight; source = :trajectory)
        if sess isa ReplSession
            try
                forwardSplitInsight!(sess, insight)
            catch
            end
        end
        pushAgentEventToWindow(wv, AgentInsightEvent(
            sid, prefix * insight; monitor = :trajectory))
        if sess isa ChatSession || sess isa TerminalSession
            try
                pushTraceToParent!(sess,
                    SessionTrace(sess.id, :trajectory, "insight", insight))
            catch
            end
        end
    catch err
        @debug "trajectory monitor failed" exception = err
        try
            pushAgentEventToWindow(wv, AgentMonitorThinkingEvent(
                sid, prefix * "monitor error — " * first(sprint(showerror, err), 160);
                monitor = :trajectory))
        catch
        end
    end
    return nothing
end
