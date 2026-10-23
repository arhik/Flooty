# contextSeedProbe.jl — a follow-up run keeps a useful transcript tail.
import FlootyAbstract
using Flooty
using FlootyStreams: OllamaMessage

failures = String[]
function check(name, ok, detail = "")
    println(ok ? "PASS  " : "FAIL  ", name, isempty(detail) ? "" : "  [" * string(detail) * "]")
    ok || push!(failures, name)
end

conv = Flooty.conversationFor("context-seed-probe")
Flooty.clearConversation!(conv)
Flooty.recordTask!(conv, "FIRST_MARKER: the original task")
for i in 1:60
    FlootyAbstract.add_message!(conv,
        OllamaMessage(role = "assistant", content = "step $i: " * ("detail " ^ 20)))
end
seed = Flooty.conversationContext(conv)
text = join([something(m.content, "") for m in seed], "\n")
check("the seed keeps the original task beyond 40 messages", occursin("FIRST_MARKER", text),
      string(length(seed)) * " messages")
check("…within the 1000-message bound", length(seed) <= 201, length(seed))

small = Flooty.conversationContext(conv; maxChars = 2000)
stext = join([something(m.content, "") for m in small], "\n")
check("a tight budget states that earlier transcript was omitted",
      occursin("[earlier transcript omitted:", stext), first(stext, 200))
check("…and still keeps the newest message", occursin("step 60", stext))
println()
if isempty(failures)
    println("CONTEXT_SEED_PROBE_OK")
else
    println("FAILED: ", join(failures, ", ")); exit(1)
end
