# conversationPersistenceProbe.jl — transcripts persist through the FAMILY store
# (`FlootyPersistence.JSONBackend`), survive a real PROCESS RESTART, and come back
# identical at the model boundary (what the next run is seeded with).
#
# Headless: no window, no endpoint. The store is pointed at a temp directory, so
# the probe never touches `~/.flooty/conversations`.
#
# Run: julia --startup-file=no --project=. test/conversationPersistenceProbe.jl
using Flooty
using FlootyPTYLayer
using FlootyPTYLayer: startReplSession, closeSession!
import FlootyPersistence

const PROBE_DIR = mktempdir()
const PROJECT = dirname(@__DIR__)

failures = String[]
function check(name::String, ok::Bool, detail = "")
    println(ok ? "PASS  " : "FAIL  ", name, isempty(detail) ? "" : "  [" * string(detail) * "]")
    ok || push!(failures, name)
end

"Run `expr` in a FRESH julia process (same project, same store) and return stdout."
function inNewProcess(expr::String)
    script = "using Flooty\n" *
             "Flooty.enableConversationPersistence!(" * repr(PROBE_DIR) * ")\n" *
             expr
    return read(`$(Base.julia_cmd()) --startup-file=no --project=$(PROJECT) -e $(script)`,
                String)
end

# The model's view of a transcript: role + content, exactly what a next run sees.
modelView(conv) = join([string(m.role, "|", something(m.content, "")) for m in
                        Flooty.conversationContext(conv)], "\n")

sess = startReplSession(`julia --startup-file=no -q`)
try
    backend = Flooty.enableConversationPersistence!(PROBE_DIR)
    check("the app-owned store is a FlootyPersistence backend",
          backend isa FlootyPersistence.JSONBackend,
          string(typeof(backend)))

    conv = Flooty.conversationFor(sess)
    id = conv.id
    Flooty.recordTask!(conv, "write H2")
    Flooty.recordAgentEvent!(conv, AgentToolCallEvent(id, "t1-1", "send", "H2 = 42"))
    Flooty.recordAgentEvent!(conv, AgentToolResultEvent(id, "t1-1", true, "42"))
    Flooty.recordAgentEvent!(conv, AgentTextEvent(id, "marker written"))

    path = joinpath(PROBE_DIR, id * ".json")
    check("every recorded turn is written through to disk", isfile(path), id)
    check("the store holds this session's transcript",
          0 < Flooty.saveConversations!(),
          string(Flooty.saveConversations!()))
    listed = Flooty.savedConversations()
    check("the store lists it (newest first) with its messages",
          any(d -> d.id == id && length(d.messages) == 4, listed),
          string([(d.id, length(d.messages)) for d in listed]))
    check("the snapshot is a message-vocabulary round trip",
          any(d -> d.model == conv.model, listed))

    # ---- the real question: does a SECOND process see it? --------------------
    view = modelView(conv)
    check("the transcript is non-empty before the restart", !isempty(view))

    fresh = inNewProcess("conv = Flooty.conversationFor(" * repr(id) * ")\n" *
                         "print(join([string(m.role, \"|\", something(m.content, \"\")) " *
                         "for m in Flooty.conversationContext(conv)], \"\\n\"))")
    check("a NEW process restores the same model view", strip(fresh) == strip(view),
          first(replace(fresh, "\n" => " / "), 160))

    transcript = inNewProcess("conv = Flooty.conversationFor(" * repr(id) * ")\n" *
                              "print(join(Flooty.conversationTranscript(conv), \"\\n\"))")
    check("…and the prose reaches the transcript (tool call folded in)",
          occursin("ran send", transcript) && occursin("marker written", transcript),
          first(replace(transcript, "\n" => " / "), 160))
    check("the fresh process did not have to write anything to read it",
          length(readdir(PROBE_DIR)) == 1)

    # ---- deletion is explicit: a dead tab keeps its transcript --------------
    Flooty.forgetConversation!(id)
    check("forgetConversation! deletes the stored transcript", !isfile(path))
    check("…and nothing else was disturbed",
          isempty(readdir(PROBE_DIR)),
          string(readdir(PROBE_DIR)))
catch e
    println("PROBE_FAILED: ", sprint(showerror, e))
    push!(failures, "probe error")
finally
    closeSession!(sess)
end

println()
if isempty(failures)
    println("CONVERSATION_PERSISTENCE_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
