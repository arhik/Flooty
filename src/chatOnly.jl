# chatOnly.jl — the conversation BEFORE any terminal exists.
#
# The app boots chat-only: no pane, no PTY. The assist box then talks to the agent
# MODEL (streaming thinking + prose), and the thread is handed to the FIRST terminal
# the user opens (Ctrl+Shift+T) or asks the chat driver to open
# ({"action":"terminal","task":…}), whose standing agent continues from it.
#
# One thread per window: the app owns it; a terminal session adopts it once and then
# the terminal agent owns the conversation.

# The chat-only thread is adopted by the FIRST terminal only. Later terminals
# are independent conversations: copying the main chat into every new terminal
# made a fresh pane resume an earlier task (reported: "launch julia repl" leaked
# into a terminal opened for `ssh`).
const CHAT_THREAD_ADOPTED = Ref(false)

const CHAT_SYSTEM_PROMPT = """
You are Flooty, a concise coding assistant in a chat window. No terminal is open.
Answer ordinary questions in plain text, briefly.
When the user asks you to run commands, edit files, drive a REPL, test, build,
install, or otherwise use a terminal, reply with exactly one JSON object and no
other text:
{"action":"terminal","task":"<precise instruction for the terminal agent>"}
To open a separate chat session, reply with exactly one JSON object:
{"action":"chat","name":"<short name>"}
Do not describe terminal work instead of opening a terminal.
"""

# Test hook: probes inject a completion instead of calling a model.
const CHAT_COMPLETE = Ref{Union{Nothing,Function}}(nothing)

"""
    parseChatReply(reply) -> (kind, text, task)

The chat driver may answer in prose, in `{"reply": …}`, or with the terminal tool
`{"action":"terminal","task": …}`. `kind` is `:chat` or `:terminal`.
"""
_placeholderActionValue(v) = occursin(r"<[^<>]*>", strip(String(v)))

function parseChatReply(reply::AbstractString)
    raw = stripThinking(String(reply))
    act = extractActionJson(raw)
    if act === nothing
        # A bare {"reply": …} carries no `action`; extractActionJson rightly
        # ignores it, but the chat contract accepts it as a prose wrapper.
        try
            obj = JSON.parse(strip(raw))
            obj isa JSON.Object && (act = obj)
        catch
        end
    end
    if act === nothing
        fn = match(r"<function\s*=\s*([A-Za-z_]+)\s*>(.*?)(?:</function>|\z)"s,
                   String(raw))
        if fn !== nothing
            name = lowercase(String(fn.captures[1]))
            body = strip(String(fn.captures[2]))
            params = providerParameters(body)
            isempty(params) || (body = strip(params[1][2]))
            pm = match(r"<parameter\s*=\s*[A-Za-z_]+\s*>(.*?)</parameter>"s, body)
            pm === nothing || (body = strip(String(pm.captures[1])))
            if name in ("terminal", "send", "run", "bash", "shell", "execute")
                return (kind = :terminal, text = "", task = body, name = "")
            elseif name in ("chat", "newchat", "chat_session")
                return (kind = :chat_session, text = "", task = "",
                        name = isempty(body) ? "Chat" : body)
            elseif name in ("reply", "answer", "done")
                return (kind = :chat, text = body, task = "", name = "")
            end
        end
    end
    if act !== nothing
        kind = lowercase(getstr(act, "action", ""))
        if kind in ("terminal", "newTerminal", "openTerminal")
            task = String(getstr(act, "task", ""))
            if !_placeholderActionValue(task)
                return (kind = :terminal,
                        text = String(getstr(act, "reply", "")),
                        task = task,
                        name = "")
            end
        end
        if kind in ("chat", "newChat", "newChatSession")
            name = String(getstr(act, "name", "Chat"))
            if !_placeholderActionValue(name)
                return (kind = :chat_session,
                        text = String(getstr(act, "reply", "")),
                        task = "",
                        name = name)
            end
        end
        body = String(getstr(act, "reply", getstr(act, "message", "")))
        if !isempty(strip(body))
            return (kind = :chat, text = body, task = "")
        end
    end
    return (kind = :chat,
            text = String(strip(stripProviderMarkup(raw))),
            task = "",
            name = "")
end

"""
    launchChildChat!(parent_id; name = "Chat") -> ChatSession

Create a CHILD ChatSession (its own conversation and chat rail tab), linked to
`parent_id` so its terminal children report traces back to it. The page adds a
tab; the child is immediately active.
"""
function launchChildChat!(parent_id::AbstractString; name::AbstractString = "Chat")
    parent = isempty(parent_id) ? ensureRootChatSession!() : sessionForId(parent_id)
    parent === nothing && (parent = ensureRootChatSession!())
    child = registerSession!(ChatSession(parent = parent.id, layout = :chat))
    if parent isa ChatSession || parent isa TerminalSession
        push!(parent.children, child.id)
    end
    wv = FlootyPTYLayer.activeTerminalUiWebview()
    wv === nothing || FlootyPTYLayer.addChatTabUi(
        wv, child.id, String(name); root_id = ensureRootChatSession!().id,
        parent_id = parent.id)
    return child
end

"""
    newRootChatSession!(name = "Chat") -> ChatSession

A new ROOT conversation (no parent): its own tab and transcript, alongside the
app's root chat. Used by the new-root session chooser.
"""
function newRootChatSession!(name::AbstractString = "Chat")
    sess = registerSession!(ChatSession(parent = nothing, layout = :chat))
    wv = FlootyPTYLayer.activeTerminalUiWebview()
    wv === nothing || FlootyPTYLayer.addChatTabUi(wv, sess.id, String(name))
    return sess
end

"""
    newChatSessionHandler(parent_id, name, root) -> ChatSession

The UI chooser's spawner: a root ChatSession or a child of `parent_id`.
"""
function newChatSessionHandler(parent_id::AbstractString, name::AbstractString,
                               root::Bool)
    root && return newRootChatSession!(name)
    return launchChildChat!(parent_id; name = isempty(name) ? "Chat" : name)
end

"""
    launchChatTerminal!(task; name = "agent", cmd = DEFAULT_CMD) -> NamedTuple | nothing

Open a terminal from the CHAT session: create its ReplSession, adopt a visible
tab, fire the creation hook (ambient monitor + standing agent + chat-thread
seed), and queue `task` as the first commission. Returns `(sess, id)`.
"""
function launchChatTerminal!(task::AbstractString = "";
                             name::AbstractString = "agent",
                             cmd::Cmd = DEFAULT_CMD,
                             parent_id::AbstractString = "")
    FlootyPTYLayer.activeTerminalUiWebview() === nothing && return nothing
    # waitPrompt=false: the page path cannot block (and prompt detection is
    # flaky for some shells); the agent's own wait/atPrompt guard covers the
    # few hundred ms before the shell is ready.
    sess = startReplSession(cmd; waitPrompt = false)
    id = FlootyPTYLayer.adoptSessionTerminal!(sess; name = String(name),
                                              parent_session = parent_id)
    # Adoption does not fire the creation hook; the hook is what attaches the
    # monitor + standing agent and seeds THIS conversation into the session.
    FlootyPTYLayer.runSessionTerminalHooks!(sess; parent_id = parent_id)
    text = strip(String(task))
    isempty(text) || pushAssistPrompt!(sess, text)
    return (sess = sess, id = id)
end

"Answer one instruction on the ROOT chat session."
chatOnlyTurn!(wv, text::AbstractString, tab::AbstractString = "") =
    chatTurnFor!(ensureRootChatSession!(), wv, text, tab)

"""
    chatTurnFor!(sess::ChatSession, wv, text, tab) -> Bool

Drive ONE chat turn for any ChatSession (root or child): record the task, call
the model, handle terminal/child-chat tools, and push events tagged with `sess.id`.
"""
function chatTurnFor!(sess::ChatSession, wv, text::AbstractString,
                      tab::AbstractString = "")
    startChatMonitor!(sess.id; note_key = sess, wv = wv)
    startTrajectoryMonitor!(sess)
    trajectoryTask!(sess, text)
    noteUserMessage!(sess, text)
    conv = conversationOf(sess)
    recordTask!(conv, text)
    sessionCfg = sessionModelConfig(sess)
    conv.model = sessionCfg.actorModel
    setSessionStatus!(sess, "thinking")
    @async begin
        try
            thinkingSeen = Ref(false)
            onThinking = chunk -> begin
                thinkingSeen[] = true
                wv === nothing || pushAgentEventToWindow(wv,
                    AgentThinkingEvent(sess.id, String(chunk)))
                nothing
            end
            fn = CHAT_COMPLETE[]
            if fn === nothing
                fn = makeCompleteFn(sessionCfg, sessionCfg.actorModel;
                    onThinking = onThinking)
            end
            msgs = chatTurnMessages(sess)
            ctxLimit = try
                contextLengthFor(sessionCfg.actorModel)
            catch
                0
            end
            ctxUse = contextUsage(msgs; limit = ctxLimit)
            try
                trajectoryContext!(sess, ctxUse.tokens, ctxUse.limit)
            catch
            end
            wv === nothing || pushAgentEventToWindow(wv,
                AgentContextUsageEvent(sess.id, ctxUse.tokens, ctxUse.limit))
            wv === nothing || pushAgentEventToWindow(
                wv, AgentProgressEvent(sess.id, "thinking…"))
            reply = fn(msgs)
            thinking = strip(extractThinking(reply))
            if !isempty(thinking) && !thinkingSeen[]
                thinkingSeen[] = true
                wv === nothing || pushAgentEventToWindow(wv,
                    AgentThinkingEvent(sess.id, thinking))
            end
            parsed = parseChatReply(reply)
            # A reasoning-only reply (no JSON, nothing after <thinking>/<think>)
            # is not an answer. Retry ONCE with the reasoning preserved in the
            # assistant channel (dropping it made the model re-derive the same
            # monologue and stop again) plus a schema note. The transcript must
            # never show the raw thinking block as the agent's text.
            if parsed.kind === :chat && isempty(strip(parsed.text))
                retry = copy(msgs)
                prior = strip(stripThinking(reply))
                reasoning = strip(extractThinking(reply))
                if !isempty(prior)
                    push!(retry, OllamaMessage(role = "assistant", content = prior,
                        thinking = isempty(reasoning) ? nothing : reasoning))
                elseif !isempty(reasoning)
                    push!(retry, OllamaMessage(role = "assistant",
                        thinking = reasoning))
                end
                push!(retry, OllamaMessage(role = "user",
                    content = "SYSTEM NOTE: your previous reply contained reasoning " *
                              "only. Emit EXACTLY ONE JSON object now: " *
                              "{\"action\":\"terminal\",\"task\":\"…\"} to open " *
                              "a terminal, or {\"reply\":\"…\"} to answer. " *
                              "Never reply with reasoning only."))
                reply = fn(retry)
                thinking = strip(extractThinking(reply))
                if !isempty(thinking) && !thinkingSeen[]
                    thinkingSeen[] = true
                    wv === nothing || pushAgentEventToWindow(wv,
                        AgentThinkingEvent(sess.id, thinking))
                end
                parsed = parseChatReply(reply)
            end
            if parsed.kind === :terminal
                task = strip(parsed.task)
                isempty(task) && (task = strip(text))
                launched = launchChatTerminal!(task; parent_id = sess.id)
                shown = if launched === nothing
                    "I could not open a terminal (no window is available)."
                else
                    base = strip(parsed.text)
                    isempty(base) ? "Opening a terminal — the agent is taking over." :
                                    base * "\n\nOpening a terminal — the agent is taking over."
                end
            elseif parsed.kind === :chat_session
                child = launchChildChat!(sess.id; name = parsed.name)
                shown = "Opened a new chat (" * first(child.id, 8) * ")."
            else
                shown = parsed.text
            end
            # NEVER fall back to the raw reply: a thinking-only reply would be
            # shown as "<thinking>…</thinking>" in the agent's voice.
            wv === nothing || pushAgentEventToWindow(wv, AgentProgressEvent(sess.id, ""))
            shown = isempty(strip(shown)) ?
                    "The model returned no answer. Try again or rephrase the request." :
                    shown
            ev = AgentTextEvent(sess.id, shown)
            recordAgentEvent!(conv, ev)
            wv === nothing || pushAgentEventToWindow(wv, ev)
            setSessionStatus!(sess, "idle")
        catch err
            setSessionStatus!(sess, "error")
            wv === nothing || pushAgentEventToWindow(wv, AgentProgressEvent(sess.id, ""))
            wv === nothing || pushAgentEventToWindow(wv,
                AgentStatusEvent(sess.id, "chat failed: " * sprint(showerror, err), :error))
        end
        return nothing
    end
    return true
end

"""
    chatSessionTurn!(wv, text, tab, session_id) -> Bool

The assist binding's 4-argument handler: route to the requested ChatSession
(child chat tab) or the root.
"""
function chatSessionTurn!(wv, text::AbstractString, tab::AbstractString = "",
                          session_id::AbstractString = "")
    sid = String(session_id)
    root = ensureRootChatSession!()
    (isempty(sid) || sid == root.id) && return chatOnlyTurn!(wv, text, tab)
    s = sessionForId(sid)
    s isa ChatSession && return chatTurnFor!(s, wv, text, tab)
    s isa BrowserSession && return browserTurnFor!(s, wv, text, tab)
    return chatOnlyTurn!(wv, text, tab)
end

"Copy the ROOT chat session's transcript into `sess` (its first terminal)."
function seedChatThreadInto!(sess)
    chat = rootChatSession()
    chat === nothing && return false
    msgs = FlootyAbstract.get_messages(conversationOf(chat))
    isempty(msgs) && return false
    conv = conversationFor(sess)
    copied = 0
    for item in msgs
        m = item.message
        content = something(m.content, "")
        isempty(strip(content)) && continue
        if m.role == "user"
            recordTask!(conv, content)
        else
            recordAgentEvent!(conv, AgentTextEvent(sessionIdFor(sess), content))
        end
        copied += 1
    end
    return copied > 0
end
