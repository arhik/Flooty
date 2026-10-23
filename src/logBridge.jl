# App logs -> chat transcript.
#
# The status strip shows one live line; a warning that scrolls past it is gone. Real
# failures (an unparseable reply, a spawn warning, a provider refusal) are debugging
# EVIDENCE and must survive in the transcript. This logger forwards Julia `@warn` /
# `@error` records from THIS stack into the active tab's chat as `warn` / `error`
# messages.
#
# Deliberately scoped: only our own packages are forwarded (# modules such as HTTP
# emit per-read warnings that would drown the transcript), identical text within a
# few seconds is dropped, and a re-entrancy guard stops a log triggered by the
# forwarding machinery from recursing.
using Logging

const CHAT_LOG_SOURCES = Set{Symbol}((:Flooty, :FlootyPTYLayer,
                                      :FlootyREPLBridge, :FlootyPersistence))
const CHAT_LOG_DEDUP = Dict{String,Float64}()
const CHAT_LOG_DEDUP_LOCK = ReentrantLock()
const CHAT_LOG_DEDUP_WINDOW_S = 3.0
const CHAT_LOG_BUSY = Ref(false)
const CHAT_LOG_PREVIOUS = Ref{Any}(nothing)

"Should `(@warn msg)` in `mod` reach the chat? Pure: the test suite pins the rule."
chatLogSource(mod::Module) = nameof(mod) in CHAT_LOG_SOURCES

"True when the same level+text was forwarded within `CHAT_LOG_DEDUP_WINDOW_S`."
function chatLogDuplicate(level::Symbol, text::AbstractString)::Bool
    key = string(level, '\0', text)
    now = time()
    lock(CHAT_LOG_DEDUP_LOCK) do
        # Bounded: prune anything older than the window instead of growing forever.
        for (k, t) in collect(CHAT_LOG_DEDUP)
            now - t > CHAT_LOG_DEDUP_WINDOW_S && delete!(CHAT_LOG_DEDUP, k)
        end
        last = get(CHAT_LOG_DEDUP, key, 0.0)
        CHAT_LOG_DEDUP[key] = now
        return now - last < CHAT_LOG_DEDUP_WINDOW_S
    end
end

"Forward one diagnostic line to the ACTIVE tab's transcript (empty id = page decides)."
function chatLogEvent(level::Symbol, text::AbstractString)
    text = strip(String(text))
    isempty(text) && return nothing
    CHAT_LOG_BUSY[] && return nothing          # re-entrancy: our own logging
    chatLogDuplicate(level, text) && return nothing
    wv = activeTerminalUiWebview()
    wv === nothing && return nothing
    CHAT_LOG_BUSY[] = true
    try
        pushAgentEventToWindow(wv, AgentStatusEvent("", text, level))
    catch err
        @debug "logBridge: forwarding failed" exception = err
    finally
        CHAT_LOG_BUSY[] = false
    end
    return nothing
end

struct ChatLogLogger <: Logging.AbstractLogger
    inner::Logging.AbstractLogger
end

Logging.min_enabled_level(l::ChatLogLogger) = Logging.min_enabled_level(l.inner)
Logging.shouldlog(l::ChatLogLogger, args...) = Logging.shouldlog(l.inner, args...)
Logging.catch_exceptions(l::ChatLogLogger) = Logging.catch_exceptions(l.inner)

function Logging.handle_message(l::ChatLogLogger, level, message, _module, group, id,
                                file, line; kwargs...)
    try
        Logging.handle_message(l.inner, level, message, _module, group, id,
                               file, line; kwargs...)
    catch err
        nothing    # never let the console sink break the forwarder
    end
    if level >= Logging.Warn && _module isa Module && chatLogSource(_module)
        shown = "[" * String(nameof(_module)) * "] " * string(message)
        chatLogEvent(level >= Logging.Error ? :error : :warn, shown)
    end
    return nothing
end

"Install the chat forwarder (idempotent). Returns true when it was installed now."
function installChatLogBridge!()::Bool
    CHAT_LOG_PREVIOUS[] === nothing || return false
    previous = Logging.current_logger()
    CHAT_LOG_PREVIOUS[] = previous
    Logging.global_logger(ChatLogLogger(previous))
    return true
end

"Restore the logger that was active before `installChatLogBridge!`."
function uninstallChatLogBridge!()::Bool
    previous = CHAT_LOG_PREVIOUS[]
    previous === nothing && return false
    Logging.global_logger(previous)
    CHAT_LOG_PREVIOUS[] = nothing
    return true
end
