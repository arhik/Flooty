# sessions.jl — the session tree. Phase 1: the ROOT chat session.
#
# The app launches as a ChatSession: it owns a conversation, one interface (the
# chat window), a layout, a driver (the chat responder) and a chat monitor that
# observes user interaction (typing bursts / pauses). Spawned sessions (terminals
# today, Typst/browser later) are CHILDREN: they carry their own interfaces,
# monitors and driver, and report traces to their parent so the parent driver can
# steer them. With one root session the parent links are inert but real.

using UUIDs

"One user-visible session. `:chat` today; `:terminal`/`:typst` become children."
Base.@kwdef mutable struct ChatSession
    id::String = string("chat-", uuid4())
    kind::Symbol = :chat
    parent::Union{Nothing,String} = nothing
    children::Vector{String} = String[]
    interfaces::Vector{Symbol} = Symbol[:chat]
    layout::Symbol = :chat
    status::String = "idle"
    created_at::Float64 = time()
end

"Session-owned transcript (the app's store, keyed by the session id)."
conversationOf(s::ChatSession) = conversationFor(s.id)

"""
A spawned TERMINAL session: the root chat's child. Two interfaces (the terminal
pane and its chat rail), so two monitors; its driver is the terminal agent loop.
"""
Base.@kwdef mutable struct TerminalSession
    id::String
    kind::Symbol = :terminal          # :terminal | :ssh
    remote::String = ""               # ssh target (user@host)
    parent::Union{Nothing,String} = nothing
    children::Vector{String} = String[]
    repl::Union{Nothing,ReplSession} = nothing
    interfaces::Vector{Symbol} = Symbol[:terminal, :chat]
    layout::Symbol = :split
    status::String = "idle"
    created_at::Float64 = time()
end

"""
A BROWSER session: its own web panel (URL bar + iframe) and chat rail. The
driver navigates/replies; page content is not readable cross-origin (navigation
is the action surface).
"""
Base.@kwdef mutable struct BrowserSession
    id::String = string("browser-", uuid4())
    parent::Union{Nothing,String} = nothing
    children::Vector{String} = String[]
    url::String = "about:blank"
    status::String = "idle"
    interfaces::Vector{Symbol} = Symbol[:browser, :chat]
    layout::Symbol = :browser
    created_at::Float64 = time()
end

const SESSIONS = Dict{String,Any}()
const SESSIONS_LOCK = ReentrantLock()
const CHAT_SESSION = Ref{Union{Nothing,ChatSession}}(nothing)

registerSession!(s) = lock(SESSIONS_LOCK) do
    SESSIONS[s.id] = s
    return s
end

sessionForId(id::AbstractString) = lock(SESSIONS_LOCK) do
    get(SESSIONS, String(id), nothing)
end

"Register the TERMINAL session behind `repl` (id = its terminal id), linked to `parent_id`."
function registerTerminalSession!(repl; parent_id::Union{Nothing,AbstractString} = nothing,
                                 kind::Symbol = :terminal,
                                 remote::AbstractString = "")
    id = FlootyPTYLayer.sessionIdFor(repl)
    isempty(id) && return nothing
    return lock(SESSIONS_LOCK) do
        held = get(SESSIONS, id, nothing)
        held !== nothing && return held
        parent = parent_id === nothing || isempty(parent_id) ? nothing : String(parent_id)
        ts = TerminalSession(id = id, parent = parent, repl = repl,
                             kind = Symbol(kind), remote = String(remote))
        SESSIONS[id] = ts
        if parent !== nothing && haskey(SESSIONS, parent)
            p = SESSIONS[parent]
            if p isa ChatSession || p isa TerminalSession || p isa BrowserSession
                id in p.children || push!(p.children, id)
            end
        end
        return ts
    end
end

"""
    setParent!(id, newParentId) -> Bool

Move a session under a new parent ("" makes it a root). The old parent's
child list loses it, the new one gains it, and the session's `parent` field
follows — the tree the page draws and the tree the app drives stay the same
tree.

Returns false when the move is impossible: an unknown session, an unknown
parent, a move onto itself, or a move that would put a session under one of
its own descendants.
"""
function setParent!(id::AbstractString, newParentId::AbstractString)
    child = String(id)
    parent = String(newParentId)
    return lock(SESSIONS_LOCK) do
        sess = get(SESSIONS, child, nothing)
        sess === nothing && return false
        if !isempty(parent)
            get(SESSIONS, parent, nothing) === nothing && return false
            parent == child && return false
            descendant = false
            # A session cannot hang under its own descendant: moving a under
            # c (c already hangs under a) would make a its own descendant.
            for cid in descendantsOf(child)
                if cid == parent
                    descendant = true
                    break
                end
            end
            descendant && return false
        end
        old = sess.parent
        if old !== nothing
            p = get(SESSIONS, old, nothing)
            if p isa ChatSession || p isa TerminalSession || p isa BrowserSession
                filter!(!=(child), p.children)
            end
        end
        sess.parent = isempty(parent) ? nothing : parent
        if !isempty(parent)
            p = get(SESSIONS, parent, nothing)
            if p isa ChatSession || p isa TerminalSession || p isa BrowserSession
                child in p.children || push!(p.children, child)
            end
        end
        return true
    end
end

"Every session id below `id` (the subtree, without `id` itself)."
function descendantsOf(id::AbstractString)
    out = String[]
    stack = String[String(id)]
    while !isempty(stack)
        cur = pop!(stack)
        node = get(SESSIONS, cur, nothing)
        node === nothing && continue
        kids = (node isa ChatSession || node isa TerminalSession ||
                node isa BrowserSession) ? node.children : String[]
        for cid in kids
            cid in out || push!(out, cid)
            push!(stack, cid)
        end
    end
    return out
end

"Remove one session id from the registry and its parent's child list."
function detachSession!(sess)
    parent = sess.parent
    if parent !== nothing
        p = sessionForId(parent)
        if p isa ChatSession || p isa TerminalSession || p isa BrowserSession
            filter!(!=(sess.id), p.children)
        end
    end
    lock(SESSIONS_LOCK) do
        delete!(SESSIONS, sess.id)
    end
    return nothing
end

"Close descendants first, then the session itself; collect ids for the page."
function closeSessionSubtree!(sess, closed::Vector{String})
    for cid in copy(sess.children)
        child = sessionForId(cid)
        child === nothing && continue
        closeSessionSubtree!(child, closed)
    end
    if sess isa TerminalSession
        # Headless children have no UI registry entry; close the PTY directly
        # first, then let the UI kill path unlink/teardown if it owns the id.
        sess.repl === nothing || try
            closeSession!(sess.repl)
        catch err
            @debug "closeSessionSubtree!: closeSession! failed" exception = err
        end
        try
            FlootyPTYLayer.handleTerminalKill(String(sess.id); force = true)
        catch err
            @debug "closeSessionSubtree!: terminal kill failed" exception = err
        end
    end
    stopChatMonitor!(String(sess.id))
    try
        stopTrajectoryMonitor!(sess isa TerminalSession && sess.repl !== nothing ? sess.repl : sess)
    catch
    end
    detachSession!(sess)
    push!(closed, String(sess.id))
    return nothing
end

"Collect a subtree's ids, children before parents, for the page."
function collectSessionSubtreeIds!(sess, out::Vector{String})
    for cid in copy(sess.children)
        child = sessionForId(cid)
        child === nothing && continue
        collectSessionSubtreeIds!(child, out)
    end
    push!(out, String(sess.id))
    return out
end

"""
    closeChatSession!(session_id) -> closed_ids

Close a user-visible ChatSession and its descendants. The PRIMARY root chat is
the app's home surface and is never closed. Returns every session id the page
must remove (terminal children are gone too).

The ids are returned IMMEDIATELY and the teardown runs in a task: killing a
terminal pushes exit events to the same WebView, and doing that inside the
`flootyCloseChat` binding would deadlock waiting for the binding's response.
"""
function closeChatSession!(session_id::AbstractString)::Vector{String}
    sess = sessionForId(session_id)
    sess isa ChatSession || return String[]
    sess === rootChatSession() && return String[]
    closed = String[]
    collectSessionSubtreeIds!(sess, closed)
    @async begin
        try
            closeSessionSubtree!(sess, String[])
        catch err
            @debug "closeChatSession!: teardown failed" exception = err
        end
    end
    return closed
end

"Unlink a dead terminal session from the tree (close hook)."
function unlinkTerminalSession!(repl)
    id = FlootyPTYLayer.sessionIdFor(repl)
    isempty(id) && return false
    stopChatMonitor!(id)
    try
        stopTrajectoryMonitor!(repl)
    catch
    end
    return lock(SESSIONS_LOCK) do
        ts = get(SESSIONS, id, nothing)
        ts === nothing && return false
        # A REVIVED terminal: the tree entry now belongs to the NEW session
        # (the revive swapped the repl behind the same id). Unlinking it here
        # would drop the LIVE terminal from the tree — the agent's traces,
        # steering and parent lookups would stop seeing it.
        if ts isa TerminalSession && ts.repl !== repl
            return false
        end
        pop!(SESSIONS, id, nothing)
        if ts isa TerminalSession && ts.parent !== nothing &&
           haskey(SESSIONS, ts.parent)
            p = SESSIONS[ts.parent]
            if p isa ChatSession || p isa TerminalSession || p isa BrowserSession
                filter!(!=(id), p.children)
            end
        end
        return true
    end
end

"Create (once) and return the root chat session."
function ensureRootChatSession!()
    s = CHAT_SESSION[]
    s === nothing || return s
    s = registerSession!(ChatSession())
    CHAT_SESSION[] = s
    return s
end

rootChatSession() = CHAT_SESSION[]

# ---- traces / steering ------------------------------------------------------
"An observation from one interface's monitor (advisory, never an action)."
struct SessionTrace
    session_id::String
    interface::Symbol
    kind::String
    text::String
    at::Float64
end
SessionTrace(id, interface, kind, text) =
    SessionTrace(String(id), Symbol(interface), String(kind), String(text), time())

const PARENT_NOTES = Dict{String,Vector{String}}()
const PARENT_NOTES_LOCK = ReentrantLock()

"Record a child trace for its parent's driver. Root sessions have no parent."
function pushTraceToParent!(sess, tr::SessionTrace)
    parent = sess isa ChatSession || sess isa TerminalSession ? sess.parent : nothing
    parent === nothing && return false
    lock(PARENT_NOTES_LOCK) do
        push!(get!(Vector{String}, PARENT_NOTES, String(parent)),
              string(sess.id, "/", tr.interface, "/", tr.kind, ": ", tr.text))
    end
    return true
end

"Drain a session's incoming traces/steering notes."
takeParentNotes!(id::AbstractString) = lock(PARENT_NOTES_LOCK) do
    pop!(PARENT_NOTES, String(id), String[])
end

"""
    forwardSplitInsight!(child, body) :: Bool

A split child's monitor and its main driver share observations: the insight goes
to the CHILD's driver (its own note) and to the MAIN driver, prefixed `split
pane:`. That is the shared monitor the main agent needs to notice the user
working in the temporary pane.
"""
function forwardSplitInsight!(child, body::AbstractString)
    isempty(strip(String(body))) && return false
    parent = try
        FlootyPTYLayer.splitParentSession(child)
    catch
        nothing
    end
    parent === nothing && return false
    pushMonitorNote!(parent, "split pane: " * String(body); source = :terminal)
    return true
end

"""
    forwardParentInsight!(child, body) :: Bool

A CHILD terminal's monitor insight becomes a trace for its parent driver —
except for the root chat's own first terminal (the ambient monitor stays in its
tab) and split children (which use the split-pane MONITOR NOTE channel).
"""
function forwardParentInsight!(child, body::AbstractString)
    isempty(strip(String(body))) && return false
    id = FlootyPTYLayer.sessionIdFor(child)
    isempty(id) && return false
    ts = sessionForId(id)
    ts isa TerminalSession || return false
    ts.parent === nothing && return false
    root = rootChatSession()
    (root !== nothing && ts.parent == root.id) && return false
    return pushTraceToParent!(ts, SessionTrace(ts.id, :terminal, "insight",
                                               String(body)))
end

# ---- child sessions (one abstraction; split is only a presentation) --------
"Session object for a ReplSession's TerminalSession, or itself."
function sessionNode(sess)
    sess isa ReplSession && return sessionForId(FlootyPTYLayer.sessionIdFor(sess))
    return sess
end

"Child session objects (TerminalSession/ChatSession) in creation order."
function childSessions(sess)
    node = sessionNode(sess)
    (node isa ChatSession || node isa TerminalSession || node isa BrowserSession) ||
        return Any[]
    out = Any[]
    for id in copy(node.children)
        c = sessionForId(id)
        c === nothing || push!(out, c)
    end
    return out
end

"Terminal children (split panes AND terminal tabs) in creation order."
function childTerminals(sess)
    [c for c in childSessions(sess) if c isa TerminalSession && c.repl !== nothing]
end

"Terminal child `n` (1-based), or nothing."
function childTerminalAt(sess, n::Integer)
    kids = childTerminals(sess)
    1 <= n <= length(kids) ? kids[Int(n)] : nothing
end

"Chat children in creation order."
function childChats(sess)
    [c for c in childSessions(sess) if c isa ChatSession]
end

"Durably steer a session (parent driver -> child driver)."
function steerSession!(to_id::AbstractString, kind::AbstractString,
                       text::AbstractString)
    lock(PARENT_NOTES_LOCK) do
        push!(get!(Vector{String}, PARENT_NOTES, String(to_id)),
              "STEER " * String(kind) * ": " * String(text))
    end
    return true
end

"Driver-published, concrete session status (mirrored to the parent)."
function setSessionStatus!(sess, status::AbstractString)
    (sess isa ChatSession || sess isa TerminalSession || sess isa BrowserSession) ||
        return nothing
    sess.status = String(status)
    return nothing
end

"Status + parent trace for the terminal driver (called by the agent loop)."
function publishTerminalStatus!(repl, status::AbstractString)
    id = FlootyPTYLayer.sessionIdFor(repl)
    isempty(id) && return false
    ts = sessionForId(id)
    ts isa TerminalSession || return false
    setSessionStatus!(ts, status)
    pushTraceToParent!(ts, SessionTrace(ts.id, :terminal, "status", String(status)))
    return true
end

# ---- chat monitor -----------------------------------------------------------
# A STANDING watcher of the CHAT interface: the page reports typing/pauses, the
# loop samples the settled draft, and a cooldown gates model calls. Its insight
# is advisory: a MONITOR NOTE for the chat driver.
Base.@kwdef mutable struct ChatMonitor
    session_id::String
    cooldown_s::Float64 = 20.0
    pause_s::Float64 = 2.0
    poll_s::Float64 = 0.5
    min_chars::Int = 3
    insights::Int = 0
    announced::Bool = false
    # STANDING watcher state (like the terminal monitor): the page reports the
    # draft/typing, the loop samples it, and only a settled draft reaches the
    # model. Nothing here is one-shot.
    draft::String = ""
    paused_draft::String = ""
    paused_idle::Float64 = 0.0
    last_evaluated::String = ""
    last_eval_at::Float64 = 0.0
    inflight::Bool = false
    note_key::Any = nothing
    task::Union{Nothing,Task} = nothing
    stop::Bool = false
end

const CHAT_MONITORS = Dict{String,ChatMonitor}()
const CHAT_MONITORS_LOCK = ReentrantLock()
# Test hook: probes inject a completion instead of calling a model.
const CHAT_MONITOR_COMPLETE = Ref{Union{Nothing,Function}}(nothing)

const CHAT_MONITOR_PROMPT = """
You are the ambient USER MONITOR of the input draft. The user typed in the
assistant's chat box, then PAUSED. Judge ONLY that draft: its intent, clarity,
and whether it is worth clarifying before it is sent.
Do NOT discuss the terminal, shell, commands, files, or the agent's actions.
You do not receive a terminal snapshot; do not speculate about one.
Reply with EXACTLY ONE JSON object, no markdown:
{"decision":"observe","confidence":0.0}                 nothing worth saying
{"decision":"insight","title":"<t>","body":"<b>","confidence":0.0} a short useful observation
Speak only when useful: a destructive/irreversible action is being prepared, a
clear question is half-formed, or a concrete detail is missing. Never restate
the draft. Be terse.
"""

function chatMonitorFor(id::AbstractString)::ChatMonitor
    key = String(id)
    return lock(CHAT_MONITORS_LOCK) do
        get!(CHAT_MONITORS, key) do
            ChatMonitor(session_id = key)
        end
    end
end

"Resolve the session whose model/notes this chat monitor uses."
function chatMonitorNoteKey(sess)
    sess isa ChatSession && return sess
    if sess isa TerminalSession && sess.repl !== nothing
        return sess.repl
    end
    return try
        FlootyPTYLayer.sessionForTerminalId(String(sess.id))
    catch
        nothing
    end
end

"""
    announceChatMonitor!(session_id, wv)

The Chat tab is a monitor surface: it must say it is alive before it has an
insight. Once per session.
"""
function announceChatMonitor!(session_id::AbstractString, wv)::Bool
    wv === nothing && return false
    m = chatMonitorFor(session_id)
    m.announced && return false
    m.announced = true
    pushAgentEventToWindow(wv, AgentMonitorThinkingEvent(
        String(session_id), "user monitor attached — watching user intent"))
    return true
end

"""
    startChatMonitor!(session_id; note_key = nothing, wv = nothing)

Start the STANDING chat watcher for a session. Idempotent: one loop per chat
session, exactly like `startMonitor!` for a terminal. The loop samples the
page-reported draft; a settled draft is the episode that reaches the model.
"""
function startChatMonitor!(session_id::AbstractString;
                           note_key = nothing, wv = nothing)::Bool
    m = chatMonitorFor(session_id)
    note_key === nothing || (m.note_key = note_key)
    m.stop = false
    announceChatMonitor!(String(session_id), wv)
    if m.task === nothing || istaskdone(m.task)
        m.task = @async chatMonitorLoop(m)
    end
    return true
end

"Stop a chat watcher (session closed / test teardown)."
function stopChatMonitor!(session_id::AbstractString)
    m = lock(CHAT_MONITORS_LOCK) do
        pop!(CHAT_MONITORS, String(session_id), nothing)
    end
    m === nothing && return false
    m.stop = true
    return true
end

"""
    migrateChatMonitor!(old_id, new_id; note_key = nothing)

The FIRST terminal adopts the chat-only thread; its Chat tab is the same
surface, now keyed by the terminal id. Transfer the watcher (including the
`announced` flag) so both a root monitor and a terminal monitor cannot attach
to one transcript.
"""
function migrateChatMonitor!(old_id::AbstractString, new_id::AbstractString;
                             note_key = nothing)::Bool
    String(old_id) == String(new_id) && return false
    old = lock(CHAT_MONITORS_LOCK) do
        pop!(CHAT_MONITORS, String(old_id), nothing)
    end
    old === nothing && return false
    old.stop = true
    m = chatMonitorFor(new_id)
    m.note_key = note_key === nothing ? old.note_key : note_key
    m.announced = old.announced
    m.insights = old.insights
    m.draft = old.draft
    m.paused_draft = old.paused_draft
    m.paused_idle = old.paused_idle
    m.last_evaluated = old.last_evaluated
    m.last_eval_at = old.last_eval_at
    startChatMonitor!(String(new_id); note_key = m.note_key,
                      wv = FlootyPTYLayer.activeTerminalUiWebview())
    return true
end

"""
    chatMonitorLoop(m)

Standing sampler, the chat-side analogue of `monitorLoop`: every `poll_s` it
looks at the latest page-reported draft. Only a draft that has been idle for
`pause_s`, has not been evaluated, and is outside the cooldown reaches the
model. The model call runs in its own task, so sampling never blocks.
"""
function chatMonitorLoop(m::ChatMonitor)
    while !m.stop
        sleep(m.poll_s)
        m.stop && break
        try
            sess = sessionForId(m.session_id)
            sess === nothing && (m.stop = true; break)
            wv = FlootyPTYLayer.activeTerminalUiWebview()
            wv === nothing && continue
            announceChatMonitor!(m.session_id, wv)
            now = time()
            draft = strip(m.paused_draft)
            length(draft) < m.min_chars && continue
            # Only a PAUSE event marks a draft settled. A late "typing" report
            # must not erase that state (page calls can arrive out of order).
            draft == strip(m.draft) || continue
            draft == m.last_evaluated && continue
            m.inflight && continue
            now - m.last_eval_at < m.cooldown_s && continue
            m.last_evaluated = draft
            m.last_eval_at = now
            m.inflight = true
            @async begin
                try
                    evaluateChatMonitor!(m, sess, draft, m.paused_idle)
                finally
                    m.inflight = false
                end
            end
        catch err
            @debug "chat monitor sample failed" exception = err
        end
    end
    return nothing
end

"""
    evaluateChatMonitor!(m, sess, draft, idle_s)

One model-backed chat-monitor decision. Extracted from the old one-shot trace;
the standing loop now calls it.
"""
function evaluateChatMonitor!(m::ChatMonitor, sess, draft::AbstractString,
                              idle_s::Real)
    wv = FlootyPTYLayer.activeTerminalUiWebview()
    wv === nothing && return nothing
    note_key = m.note_key === nothing ? chatMonitorNoteKey(sess) : m.note_key
    try
        fn = CHAT_MONITOR_COMPLETE[]
        if fn === nothing
            # Honor the tab's MONITOR model, not the process global.
            fn = monitorCompleteFn(sessionModelConfig(note_key))
        end
        reply = fn(OllamaMessage[
            OllamaMessage(role = "system", content = CHAT_MONITOR_PROMPT),
            OllamaMessage(role = "user",
                content = "The user paused after typing (idle " *
                          string(round(Float64(idle_s); digits = 1)) *
                          "s). Current draft:\n" * draft),
        ])
        # The monitor's REASONING is its visible voice in the Monitor tab.
        thinking = strip(extractThinking(reply))
        if !isempty(thinking)
            pushAgentEventToWindow(wv,
                AgentMonitorThinkingEvent(String(m.session_id), thinking))
        end
        dec = extractActionJson(stripThinking(reply))
        dec === nothing || publishMonitorConfidence!(
            String(m.session_id), dec, :chat)
        if dec === nothing
            pushAgentEventToWindow(wv, AgentMonitorThinkingEvent(
                String(m.session_id), "observe — no structured insight"))
            return nothing
        end
        decword = lowercase(String(get(dec, "decision", "observe")))
        if decword != "insight"
            pushAgentEventToWindow(wv, AgentMonitorThinkingEvent(
                String(m.session_id), "observe — " * decword))
            return nothing
        end
        body = strip(String(get(dec, "body", "")))
        isempty(body) && return nothing
        pushMonitorNote!(note_key, body; source = :chat)
        m.insights += 1
        pushAgentEventToWindow(wv,
            AgentInsightEvent(String(m.session_id), body; monitor = :chat))
        if sess isa TerminalSession || sess isa ChatSession
            pushTraceToParent!(sess, SessionTrace(sess.id, :chat, "insight", body))
        end
    catch err
        @debug "chat monitor failed" exception = err
        try
            pushAgentEventToWindow(wv, AgentMonitorThinkingEvent(
                String(m.session_id),
                "monitor error — " * first(sprint(showerror, err), 160)))
        catch
        end
    end
    return nothing
end

"""
    chatInteractionTrace!(session_id, kind, text, idle_s) :: Bool

The chat INTERFACE reports interaction. `typing` updates the standing watcher's
draft and activity; `pause` marks it settled; `attach` starts the watcher. The
loop decides when the draft is model-worthy.
"""
function chatInteractionTrace!(session_id::AbstractString, kind::AbstractString,
                               text::AbstractString, idle_s::Real)::Bool
    sess = sessionForId(session_id)
    sess === nothing && begin
        repl = FlootyPTYLayer.sessionForTerminalId(String(session_id))
        repl === nothing && return false
        sess = registerTerminalSession!(repl)
        sess === nothing && return false
    end
    note_key = chatMonitorNoteKey(sess)
    wv = FlootyPTYLayer.activeTerminalUiWebview()
    if kind == "attach"
        return startChatMonitor!(String(session_id); note_key = note_key, wv = wv)
    end
    if kind == "submit"
        m = chatMonitorFor(sess.id)
        m.draft = ""
        m.paused_draft = ""
        return true
    end
    (kind == "typing" || kind == "pause") || return false
    draft = strip(String(text))
    length(draft) < 3 && return false
    m = chatMonitorFor(sess.id)
    m.draft = draft
    if kind == "pause"
        m.paused_draft = draft
        m.paused_idle = Float64(idle_s)
    end
    startChatMonitor!(String(session_id); note_key = note_key, wv = wv)
    return true
end

# ---- chat driver ------------------------------------------------------------
"Messages for one chat turn: system + steering/monitor notes + transcript."
function chatTurnMessages(sess::ChatSession)::Vector{OllamaMessage}
    conv = conversationOf(sess)
    msgs = OllamaMessage[OllamaMessage(role = "system", content = CHAT_SYSTEM_PROMPT)]
    for n in takeParentNotes!(sess.id)
        push!(msgs, OllamaMessage(role = "user", content = "STEER: " * n))
    end
    for n in takeMonitorNotes!(sess)
        push!(msgs, OllamaMessage(role = "user", content = "MONITOR NOTE: " * n))
    end
    append!(msgs, conversationContext(conv))
    return msgs
end
