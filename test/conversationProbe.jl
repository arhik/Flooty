# conversationProbe.jl — the app owns the session's transcript, and a run USES it.
#
# What this pins down (the reason the conversation layer exists):
#   * every event a run produces lands in the session's `Conversation` in the
#     family's message vocabulary (`MessageItem` wrapping `OllamaMessage`):
#     your instruction as `user`, speech as `assistant` content, reasoning as
#     `thinking`, a command as `assistant` + `tool_calls`, its outcome as `tool`;
#   * the NEXT run is seeded with a bounded tail of that transcript — so a follow-up
#     instruction is not blind (the scripted model records the messages it is asked
#     to complete, which is exactly what a real one would see);
#   * the store speaks the session-layer message API (`FlootyAbstract.get_messages`
#     / `add_message!`), so a future session kind can own one unchanged.
#
# Headless: no window, no endpoint — a scripted `completeFn` drives the loop.
#
# Run: julia --startup-file=no --project=. test/conversationProbe.jl
import Flooty
import FlootyAbstract
import FlootyBase
import FlootyStreams
using FlootyStreams: OllamaMessage
using Flooty
using FlootyPTYLayer: startReplSession, closeSession!

# What each scripted run was asked to complete (what a real model would see).
const seen = Ref(Vector{Vector{FlootyStreams.OllamaMessage}}())

failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = isempty(detail) ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end

sess = startReplSession(`julia --startup-file=no -q`)
try
    conv = Flooty.conversationFor(sess)
    check("a session gets a conversation, keyed by session id",
          conv isa Flooty.Conversation &&
          Flooty.conversationFor(sess) === conv,
          conv.id)

    # ---- run 1: scripted -------------------------------------------------------
    script = [
        "{\"action\":\"send\",\"code\":\"H2 = 42\"}",
        "{\"action\":\"done\",\"summary\":\"marker written\"}",
    ]
    completeFn = messages -> begin
        push!(seen[], copy(messages))
        isempty(script) ? "{\"action\":\"done\",\"summary\":\"script exhausted\"}" :
                          popfirst!(script)
    end
    r1 = runTerminalAgent!(sess, "write H2";
                           completeFn = completeFn, maxTurns = 6)
    check("run 1 finished", r1.ok)

    transcript = Flooty.conversationTranscript(conv)
    check("your instruction is a `user` message",
          any(l -> startswith(l, "user: ") && occursin("write H2", l), transcript),
          join(transcript, " | "))
    check("the command is an `assistant` message carrying a tool call",
          any(l -> startswith(l, "assistant: ") && occursin("ran send", l), transcript),
          join(transcript, " | "))
    check("its outcome is a `tool` message",
          any(l -> startswith(l, "tool: ") && occursin("H2 = 42", l), transcript),
          join(transcript, " | "))
    check("the answer is `assistant` content",
          any(l -> startswith(l, "assistant: ") && occursin("marker written", l), transcript),
          join(transcript, " | "))

    # ---- the family's session API works on it -----------------------------------
    items = FlootyAbstract.get_messages(conv)
    check("get_messages returns MessageItem wrappers",
          !isempty(items) && all(i -> i isa FlootyBase.MessageItem, items),
          string(typeof(first(items))))
    check("their bodies are OllamaMessages (what FlootyTUI renders)",
          all(i -> i.message isa FlootyStreams.OllamaMessage, items))

    # ---- run 2: does it SEE run 1? ---------------------------------------------
    script2 = ["{\"action\":\"done\",\"summary\":\"nothing to do\"}"]
    completeFn2 = messages -> begin
        push!(seen[], copy(messages))
        isempty(script2) ? "{\"action\":\"done\",\"summary\":\"script exhausted\"}" :
                           popfirst!(script2)
    end
    empty!(script)                                  # run 2 uses its own script
    r2 = runTerminalAgent!(sess, "what did you just do?";
                           completeFn = completeFn2, maxTurns = 4)
    check("run 2 finished", r2.ok)

    secondMessages = seen[][end]
    joined = join([string(m.role, ": ", something(m.content, "")) for m in secondMessages], "\n")
    check("the second run is seeded with the FIRST run's instruction",
          occursin("write H2", joined), first(joined, 200))
    check("…with what the first run actually ran",
          occursin("ran send", joined) || occursin("\"action\":\"send\"", joined),
          first(joined, 200))
    check("…and with its result",
          occursin("H2 = 42", joined), first(joined, 200))
    # The loop appends the turn's snapshot AFTER the task, so the task is the last
    # message before it — what matters is that the new instruction is present.
    check("the new task is in the seeded context",
          any(m -> occursin("what did you just do?", something(m.content, "")),
              secondMessages[max(1, end-2):end]),
          string(length(secondMessages)))

    # ---- provider contract -------------------------------------------------------
    seeded = Flooty.conversationContext(conv)
    check("the seeded context carries NO tool-role messages (Beam rejects those " *
          "without a resolvable call)", all(m -> m.role != "tool", seeded),
          join([m.role for m in seeded], ","))
    check("a tool result appears folded into the assistant's own message",
          any(m -> m.role == "assistant" && occursin("→", something(m.content, "")), seeded),
          join([first(something(m.content, ""), 40) for m in seeded], " | "))

    # ---- a provider that refuses the history must not kill the run ---------------
    script3 = ["{\"action\":\"done\",\"summary\":\"finished after history was dropped\"}"]
    attempts = Ref(0)
    refusing = messages -> begin
        attempts[] += 1
        # Only the seeded history carries a rendered tool call.
        hasHistory = any(m -> occursin("ran send", something(m.content, "")) ||
                                    occursin("\"action\":\"send\"", something(m.content, "")),
                          messages)
        if hasHistory && attempts[] == 1
            error("HTTP 400 invalid messages: tool message 1 has no resolvable tool name")
        end
        isempty(script3) ? "{\"action\":\"done\",\"summary\":\"exhausted\"}" :
                           popfirst!(script3)
    end
    r3 = try
        runTerminalAgent!(sess, "continue"; completeFn = refusing, maxTurns = 4)
    catch e
        println("PROBE_FAILED: ", sprint(showerror, e))
        push!(failures, "history fallback")
        nothing
    end
    check("a rejected history is retried without it (run survives)",
          r3 !== nothing && r3.ok && attempts[] >= 2,
          r3 === nothing ? "threw" : string("ok=", r3.ok, " attempts=", attempts[]))
    check("the retry really dropped the history",
          any(l -> occursin("rejected the conversation history", l), r3.transcript),
          join(r3.transcript, " | "))

    # ---- bounded -----------------------------------------------------------------
    ctx = Flooty.conversationContext(conv; maxChars = 60)
    total = sum(m -> length(something(m.content, "")), ctx; init = 0)
    check("the seeded window respects its character budget", total <= 60, total)
    ctxAll = Flooty.conversationContext(conv)
    check("the default window carries the whole short conversation",
          length(ctxAll) >= 4, length(ctxAll))

    # ---- reasoning: two views, two contracts -------------------------------------
    # The transcript keeps the model's monologue (the user watches it), the seed a
    # run is given must NOT carry it: re-feeding reasoning inflates the prompt and
    # biases the next reply toward more monologue.
    thinkConv = Flooty.conversationFor("reasoning-view-probe")
    Flooty.recordTask!(thinkConv, "print 1")
    # A turn that HAS content plus reasoning: the reasoning must ride its own
    # field (never prose in the content).
    FlootyAbstract.add_message!(thinkConv,
        OllamaMessage(role = "assistant", content = "Printed 1.",
                      thinking = "MONOLOGUE-MARKER"))
    # A REASONING-ONLY turn must not become an empty assistant message in the seed.
    Flooty.recordAgentEvent!(thinkConv,
        Flooty.AgentThinkingEvent("", "REASONING-ONLY"))
    seed = Flooty.conversationContext(thinkConv)
    seedText = join([something(m.content, "") for m in seed], "\n")
    seedThinking = join([something(m.thinking, "") for m in seed], "")
    uiText = join(Flooty.conversationTranscript(thinkConv), "\n")
    check("the seed carries NO reasoning in the content",
          !occursin("MONOLOGUE-MARKER", seedText) &&
          !occursin("REASONING-ONLY", seedText), seedText)
    check("the seed still carries the assistant's answer",
          occursin("Printed 1.", seedText))
    check("the human transcript KEEPS the reasoning (the user watches it)",
          occursin("MONOLOGUE-MARKER", uiText) && occursin("REASONING-ONLY", uiText))
    check("the seed carries the reasoning in its OWN field",
          occursin("MONOLOGUE-MARKER", seedThinking), seedThinking)
    check("a reasoning-only turn is not seeded as an EMPTY assistant message",
          !occursin("REASONING-ONLY", seedThinking) &&
          all(m -> !isempty(strip(something(m.content, ""))), seed),
          [something(m.content, "") for m in seed])

    # ---- clearing -----------------------------------------------------------------
    Flooty.clearConversation!(conv)
    check("clearing empties the transcript",
          isempty(Flooty.conversationContext(conv)))
catch e
    println("PROBE_FAILED: ", sprint(showerror, e))
    push!(failures, "probe error")
finally
    closeSession!(sess)
end

println()
if isempty(failures)
    println("CONVERSATION_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
