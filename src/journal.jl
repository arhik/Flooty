# journal.jl — the app's side of the event journal.
#
# The journal itself lives in FlootyPersistence (`SQLiteJournal`): append-only
# events, schema-versioned rows, sessions as a projection. This file is the glue
# between a live `ReplSession` / `Conversation` and that store:
#
#   * it MINTS the session identity once per session (`session_uid`) — the whole
#     point of the journal, because the old key was derived from the UI terminal id
#     and adoption silently re-keyed it (a recorded session was orphaned);
#   * it mirrors every recorded turn into the journal (dual-write for one release:
#     `ConversationData` JSON keeps working as the export path);
#   * it rebuilds a `Conversation` from the journal (`journalConversation`), which
#     is how a session is loaded later — from any session id, after a restart.
#
# Journaling is OFF by default (headless probes stay hermetic and write nothing);
# `agentApp`/`enableJournalPersistence!` turn it on.

"Where a session's events go: a minted uid, the live session, and last-known tab id."
mutable struct JournalBinding
    uid::String
    sess::Any
    last_terminal_id::String
end

const JOURNAL = Ref{Union{Nothing,FlootyPersistence.SQLiteJournal}}(nothing)
const JOURNAL_BINDINGS = IdDict{Any,JournalBinding}()
const JOURNAL_BINDINGS_LOCK = ReentrantLock()
const JOURNAL_UIDS = IdDict{Any,String}()          # sess -> minted uid (never changes)
const JOURNAL_UIDS_LOCK = ReentrantLock()
const JOURNAL_STARTED = Set{String}()              # uids whose session_started landed
const JOURNAL_STARTED_LOCK = ReentrantLock()
const JOURNAL_DEFAULT_DIR = joinpath(homedir(), ".flooty")

"Journal file used when none is given: `~/.flooty/journal.sqlite` (`FLOOTY_JOURNAL` wins)."
function defaultJournalPath()::String
    override = get(ENV, "FLOOTY_JOURNAL", "")
    isempty(strip(override)) || return abspath(String(override))
    return joinpath(JOURNAL_DEFAULT_DIR, "journal.sqlite")
end

"The live journal, or `nothing` while journaling is off."
journalStore() = JOURNAL[]

"""
    enableJournalPersistence!([path]) :: SQLiteJournal

Turn journaling on for this process. `path` may be a file or a directory (a
directory gets `journal.sqlite` inside it); omitted ⇒ `defaultJournalPath()`.
Idempotent: calling it again with the same path reuses the open handle.
"""
function enableJournalPersistence!(path::Union{Nothing,AbstractString} = nothing)
    raw = path === nothing ? defaultJournalPath() : String(path)
    # A path without the journal's own extension is a DIRECTORY for it.
    p = endswith(raw, ".sqlite") ? abspath(raw) : joinpath(abspath(raw), "journal.sqlite")
    mkpath(dirname(p))
    j = JOURNAL[]
    j !== nothing && journal_path(j) == p && return j
    j === nothing || FlootyPersistence.close!(j)
    opened = FlootyPersistence.open_journal(p)
    JOURNAL[] = opened
    @debug string("[journal] enabled at ", p,
                  " (schema v", FlootyPersistence.schema_version(opened), ")")
    return opened
end

"Close and forget the journal (headless probes, teardown)."
function disableJournalPersistence!()
    j = JOURNAL[]
    j === nothing && return nothing
    JOURNAL[] = nothing
    FlootyPersistence.close!(j)
    return nothing
end

"Mint (once) the immutable journal identity of `sess`."
function journalSessionUid(sess)::String
    return lock(JOURNAL_UIDS_LOCK) do
        get!(JOURNAL_UIDS, sess) do
            string(uuid4())
        end
    end
end

"""
    journalBindSession!(sess, conv) :: Union{String,Nothing}

Attach `conv` to the journal under `sess`'s minted uid and record `session_started`
once. No-op (returns `nothing`) when journaling is off. Safe to call on every run:
the second call only refreshes the binding.
"""
function journalBindSession!(sess, conv)::Union{String,Nothing}
    j = JOURNAL[]
    j === nothing && return nothing
    uid = journalSessionUid(sess)
    tid = try
        sessionIdFor(sess)
    catch
        ""
    end
    binding = lock(JOURNAL_BINDINGS_LOCK) do
        b = get(JOURNAL_BINDINGS, conv, nothing)
        if b === nothing
            b = JournalBinding(uid, sess, tid)
            JOURNAL_BINDINGS[conv] = b
        else
            b.sess = sess
        end
        b
    end
    if isempty(binding.last_terminal_id) && !isempty(tid)
        lock(JOURNAL_BINDINGS_LOCK) do
            binding.last_terminal_id = tid
        end
        try
            FlootyPersistence.append_event!(j; kind = "session_adopted",
                session_uid = uid, terminal_id = tid, role = "",
                payload = "{\"v\":1}")
        catch err
            @error "flooty: journal session_adopted failed" exception = err
        end
    end
    # `session_started` exactly once per uid.
    first_start = lock(JOURNAL_STARTED_LOCK) do
        uid in JOURNAL_STARTED ? false : (push!(JOURNAL_STARTED, uid); true)
    end
    if first_start
        try
            FlootyPersistence.append_event!(j; kind = "session_started",
                session_uid = uid, terminal_id = tid)
        catch err
            @error "flooty: journal session_started failed" exception = err
        end
    end
    return uid
end

"""
    journalAppend!(conv; kind, …) -> Union{Int64,Nothing}

Append one event for `conv`'s session. `nothing` when journaling is off or the
conversation was never bound. Never throws: a journal failure is logged and the
agent run continues (a transcript is a side record, not the task).
"""
function journalAppend!(conv; kind::AbstractString, role::AbstractString = "",
                        content = nothing, thinking = nothing,
                        tool_name = nothing, tool_call_id = nothing, ok = nothing,
                        payload = nothing)
    j = JOURNAL[]
    j === nothing && return nothing
    binding = lock(JOURNAL_BINDINGS_LOCK) do
        get(JOURNAL_BINDINGS, conv, nothing)
    end
    binding === nothing && return nothing
    tid = ""
    if binding.sess !== nothing
        tid = try
            sessionIdFor(binding.sess)
        catch
            ""
        end
    end
    adopted = false
    if !isempty(tid) && tid != binding.last_terminal_id
        lock(JOURNAL_BINDINGS_LOCK) do
            binding.last_terminal_id = tid
        end
        adopted = true
    end
    id = nothing
    try
        adopted && FlootyPersistence.append_event!(j; kind = "session_adopted",
            session_uid = binding.uid, terminal_id = tid)
        id = FlootyPersistence.append_event!(j; kind = kind, session_uid = binding.uid,
            terminal_id = tid, role = role, content = content, thinking = thinking,
            tool_name = tool_name, tool_call_id = tool_call_id, ok = ok,
            model = conv.model, agent = conv.agent, payload = payload,
            cwd = try pwd() catch _; "" end)
    catch err
        @error "flooty: journal append failed (run continues)" kind exception = err
    end
    return id
end

# ---- loading a session back ---------------------------------------------------

"""
    journalConversation(id; maxMessages = CONVERSATION_MAX_MESSAGES) :: Conversation

Rebuild the transcript a session's events describe. Does not register the result
in `CONVERSATIONS` and does not journal it again — it is a read.

Event → message mapping (the projection that makes a session a query):
`user_instruction` → user content · `assistant_text` → assistant content ·
`assistant_thinking` → assistant reasoning · `tool_call` → assistant + tool call ·
`tool_result` → tool result. Lifecycle/status rows carry no message.
"""
function journalConversation(id::AbstractString;
                             maxMessages::Int = CONVERSATION_MAX_MESSAGES)::Conversation
    conv = Conversation(String(id); maxMessages = maxMessages)
    j = JOURNAL[]
    j === nothing && return conv
    for ev in FlootyPersistence.journal_events(j; session_uid = String(id))
        msg = _journalEventMessage(ev)
        msg === nothing && continue
        FlootyAbstract.add_message!(conv, msg; model = ev.model, agent = ev.agent)
    end
    return conv
end

"One journal row as the message it recorded, or `nothing` for non-message kinds."
function _journalEventMessage(ev::FlootyPersistence.JournalEvent)
    if ev.kind == "user_instruction"
        return OllamaMessage(role = "user", content = something(ev.content, ""))
    elseif ev.kind == "assistant_text"
        return OllamaMessage(role = "assistant", content = something(ev.content, ""))
    elseif ev.kind == "assistant_thinking"
        return OllamaMessage(role = "assistant", thinking = something(ev.thinking, ""))
    elseif ev.kind == "tool_call"
        call = OllamaToolCall(OllamaToolCallFunction(
            something(ev.tool_name, "tool"),
            Dict{String,Any}("detail" => something(ev.content, ""))),
            ev.tool_call_id)
        return OllamaMessage(role = "assistant", content = something(ev.content, ""),
                             tool_name = ev.tool_name, tool_calls = [call])
    elseif ev.kind == "tool_result"
        return OllamaMessage(role = "tool", content = something(ev.content, ""),
                             tool_call_id = ev.tool_call_id)
    end
    return nothing
end

"""
    journalSessionList() :: Vector{NamedTuple}

Every session the journal knows: `(session_uid, first_ts, last_ts, events,
last_id, terminal_ids)`, newest activity first. Empty while journaling is off.
"""
function journalSessionList()
    j = JOURNAL[]
    j === nothing && return NamedTuple[]
    return FlootyPersistence.journal_sessions(j)
end

"Row count/schema/size for the app's journal (`nothing` while off)."
function journalDoctor()
    j = JOURNAL[]
    j === nothing && return nothing
    return FlootyPersistence.journal_doctor(j)
end
