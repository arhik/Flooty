# app.jl — the application: one entry point, one state object, one protocol edge.
#
# Shape follows the family's apps (`flootyapp()`, `flootytui()`): an app object
# holds what the application owns, an entry function wires it to the UI layer, and
# `(@main)` is the CLI. The window/asset-server/bindings plumbing is FlootyPTYLayer's
# — this file adds the agent parts, and the CONVERSATIONS, which are what make a
# session's history something the app owns instead of something the page happens to
# be showing.

"""
    AgentApp

The application object: the UI/agent parameters it was started with, the model
config in force, and the conversations it owns.

`conversations` is the piece that matters architecturally — the app owns the
per-session transcript (see `conversation.jl`), the page renders it, and a run is
seeded from it. It is keyed by session id, so any future session kind
(`AbstractTerminalSession`, a browser session) can own one unchanged.
"""
Base.@kwdef mutable struct AgentApp
    cmd::Cmd = DEFAULT_CMD
    # Window geometry is OPTIONAL and owned by the UI layer: `nothing` means
    # "not specified", so `runTerminalUI` applies its own default instead of
    # the app pinning pixels it has no reason to know about.
    width::Union{Nothing,Int} = nothing
    height::Union{Nothing,Int} = nothing
    task::String = ""                       # optional first instruction
    config::AgentModelConfig = defaultAgentModelConfig()
    started_at::Float64 = time()
    # Where transcripts persist; `nothing` = the family default
    # (`~/.flooty/conversations`). The APP owns the store: headless runs never
    # open it, so probes leave the user's home directory alone.
    sessionsDir::Union{Nothing,String} = nothing
    # Event journal file. `nothing` = `~/.flooty/journal.sqlite` (or, when
    # `sessionsDir` was given, a journal next to it so probes stay hermetic).
    journalPath::Union{Nothing,String} = nothing
end

"Conversations this app currently holds (the registry lives in conversation.jl)."
appConversations(app::AgentApp) = conversations()

"This app's conversation for a session (created on first use)."
appConversation(app::AgentApp, sess::ReplSession) = conversationFor(sess)

"""
    agentApp(; cmd, width, height, task, sessionsDir) :: AgentApp

The application, as a value: nothing is launched yet. `runAgentApp` starts the
window (FlootyPTYLayer's `runTerminalUI`) and the event loop.

`width`/`height` are OPTIONAL: omit them (`nothing`) and the UI layer's own
default geometry is used; pass them only to override it.

Starting the app TURNS ON transcript persistence (see `conversation.jl`): every
agent turn is written through to `sessionsDir` (default `~/.flooty/conversations`)
as it happens, and `conversationFor(id)` restores a stored transcript under that
id instead of starting empty.
"""
function agentApp(; cmd::Cmd = DEFAULT_CMD,
                  width::Union{Nothing,Integer} = nothing,
                  height::Union{Nothing,Integer} = nothing,
                  task::AbstractString = "",
                  sessionsDir::Union{Nothing,AbstractString} = nothing,
                  journalPath::Union{Nothing,AbstractString} = nothing)
    AGENT_CONFIG[] = defaultAgentModelConfig()
    dir = sessionsDir === nothing ? nothing : String(sessionsDir)
    enableConversationPersistence!(dir)
    # The event journal is the durable half of the store: every recorded turn also
    # lands as a row there, so a session can be loaded later from the timeline
    # instead of a per-session file (see journal.jl / JOURNAL_AND_INDEX_STORE.md).
    jpath = journalPath === nothing ?
            (dir === nothing ? nothing : joinpath(dir, "journal.sqlite")) :
            String(journalPath)
    enableJournalPersistence!(jpath)
    # The app IS a chat session at boot; it must exist before the UI asks.
    ensureRootChatSession!()
    # `nothing` must stay `nothing` (field is Union{Nothing,Int}); anything
    # given is an integer size for the UI layer.
    w = width === nothing ? nothing : Int(width)
    h = height === nothing ? nothing : Int(height)
    return AgentApp(cmd = cmd, width = w, height = h,
                    task = strip(String(task)), config = AGENT_CONFIG[],
                    sessionsDir = dir, journalPath = jpath === nothing ? nothing : String(jpath))
end

"""
    commissionFirstSession!(task; timeoutS = 30.0)

The page creates its first terminal tab on load and every new session is adopted
under a terminal id; as soon as one appears, hand `task` to its standing agent.
Runs on a task, so the window can come up in the meantime.
"""
function commissionFirstSession!(task::AbstractString; timeoutS::Real = 30.0)
    isempty(strip(task)) && return nothing
    @async begin
        deadline = time() + timeoutS
        while time() < deadline
            sess = lock(FlootyPTYLayer.OWNERSHIP_SESSIONS_LOCK) do
                sessions = collect(values(FlootyPTYLayer.OWNERSHIP_SESSIONS))
                isempty(sessions) ? nothing : last(sessions)
            end
            if sess !== nothing
                @debug string("[app] commissioning the first session: ", first(strip(task), 80))
                pushAssistPrompt!(sess, String(task))
                return nothing
            end
            sleep(0.25)
        end
        @warn "[app] no session appeared; the initial instruction was not commissioned"
        return nothing
    end
    return nothing
end

# Flush stdout/stderr every second when launched as a macOS app bundle: a file
# redirect is block-buffered, so the log would stay empty until the app exits.
function enableBundledLogFlush!()
    get(ENV, "FLOOTY_APP_BUNDLE", "") == "1" || return false
    @async while true
        sleep(1.0)
        try
            flush(stdout)
            flush(stderr)
        catch
            return nothing
        end
    end
    return true
end

"""
    runAgentApp(; cmd, width, height, task) :: AgentApp

Run the terminal-agent application until its window closes: the UI layer's own
launch + event loop + teardown, with this package's agent attached to every session
(the session-terminal hook installed at load) and `task`, when given, commissioned
into the first tab.

`width`/`height` are optional overrides; when omitted the UI layer's own default
geometry applies (nothing is forwarded for them).
"""
function runAgentApp(; kwargs...)
    enableBundledLogFlush!()
    app = agentApp(; kwargs...)
    commissionFirstSession!(app.task)
    # Only forward what the caller actually chose: the UI layer owns the
    # default geometry, so an unspecified side must not be pinned here.
    ui = Pair{Symbol,Any}[:cmd => app.cmd]
    app.width === nothing || push!(ui, :width => app.width)
    app.height === nothing || push!(ui, :height => app.height)
    # The app boots CHAT-ONLY: no terminal tab until the first instruction (or the
    # agent's own newTerminal action) asks for one.
    # Diagnostics from THIS stack (@warn/@error) belong in the chat transcript,
    # not only in a status line that the next turn overwrites.
    installChatLogBridge!()
    try
        # A CLI instruction is terminal work. Booting chat-only made
        # commissionFirstSession! wait for an ownership session that the page
        # never creates; the task was dropped after the timeout. With a task,
        # let the page create the first terminal so the standing agent can take
        # the commission immediately. Bare launch stays chat-first.
        FlootyPTYLayer.runTerminalUI(; chatOnly = isempty(app.task), ui...)
    finally
        uninstallChatLogBridge!()
    end
    # Clean shutdown of the journal (WAL checkpoint + close) once the window is gone.
    disableJournalPersistence!()
    return app
end

main() = runAgentApp()

"""
CLI entry point (same shape as `flootytui`'s):

    julia -m Flooty [options] ["<instruction>"]
    julia --project=. agentUi.jl [timeoutS] ["<instruction>"]

Bare invocation LAUNCHES the app: every option is optional, and only an explicit
`--help`/`-h` prints usage.
"""
function (@main)(args)
    opts = try
        agentCliArgs(String.(args))
    catch err
        err isa ArgumentError || rethrow()
        return agentUsage(String(err.msg))
    end
    opts.help && return printAgentUsage()
    runAgentApp(task = opts.task, width = opts.width, height = opts.height,
                sessionsDir = opts.sessions, journalPath = opts.journal)
    return nothing
end

"""
    agentCliArgs(argv) -> NamedTuple

Parse `flooty` arguments — pure, so the flags can be tested without opening
a window. Options are optional; positional words are joined into the instruction.
Returns `(help, task, width, height, sessions, journal)`; throws
`ArgumentError` for a bad value (the caller prints usage).
"""
function agentCliArgs(argv::Vector{String})
    task = String[]
    width, height, sessions, journal = nothing, nothing, nothing, nothing
    help = false
    i = 1
    while i <= length(argv)
        arg = argv[i]
        if arg == "--help" || arg == "-h"
            help = true
            i += 1
        elseif arg in ("--width", "--height", "--sessions", "--journal")
            i < length(argv) ||
                throw(ArgumentError("$(arg) needs a value"))
            value = argv[i+1]
            if arg == "--sessions"
                sessions = value
            elseif arg == "--journal"
                journal = value
            else
                n = tryparse(Int, value)
                n === nothing &&
                    throw(ArgumentError("$(arg) needs an integer, got \"$(value)\""))
                arg == "--width" ? (width = n) : (height = n)
            end
            i += 2
        elseif startswith(arg, "--")
            throw(ArgumentError("unknown option \"$(arg)\""))
        else
            push!(task, arg)
            i += 1
        end
    end
    return (help = help, task = join(task, " "), width = width, height = height,
            sessions = sessions, journal = journal)
end

"Print the app's usage block."
function printAgentUsage()
    println("Flooty terminal agent")
    println()
    println("Usage:")
    println("  Julia app:  julia -m Flooty [options] [\"<instruction>\"]")
    println("  Checkout:   julia --project=. agentUi.jl [timeoutS] [\"<instruction>\"]")
    println("  Function:   using Flooty; Flooty.runAgentApp(task = \"...\")")
    println()
    println("Options:")
    println("  --width N       window width  (optional; the UI layer's default applies)")
    println("  --height N      window height (optional; the UI layer's default applies)")
    println("  --sessions DIR  transcript store (default: ~/.flooty/conversations)")
    println("  --journal FILE  event journal (default: ~/.flooty/journal.sqlite)")
    println("  --help, -h      show this help")
    return nothing
end

"Report a bad command line on stderr, then the usage block."
function agentUsage(message::AbstractString)
    println(stderr, "flooty: ", message)
    println(stderr)
    printAgentUsage()
    return nothing
end
