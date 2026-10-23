# warmContextProbe.jl — a follow-up run must not fall back to the tiny seed.
using FlootyStreams: OllamaMessage
using Flooty
using FlootyPTYLayer: startReplSession, closeSession!

failures = String[]
function check(name, ok, detail = "")
    println(ok ? "PASS  " : "FAIL  ", name, isempty(detail) ? "" : "  [" * string(detail) * "]")
    ok || push!(failures, name)
end

sess = startReplSession(`zsh -i`; waitPrompt = false)
try
    sleep(1.2)
    n = Ref(0)
    firstRun = runTerminalAgent!(sess, "warm-up"; maxTurns = 12,
        completeFn = _ -> begin
            n[] += 1
            n[] <= 6 ? "{\"action\":\"send\",\"code\":\"echo WARM_$(n[])\"}" :
                       "{\"action\":\"done\",\"summary\":\"warm\"}"
        end)
    check("the first run produced turns", occursin("WARM_6", join(firstRun.transcript, "\n")))

    seen = Ref("")
    second = runTerminalAgent!(sess, "follow-up"; maxTurns = 4,
        completeFn = msgs -> begin
            seen[] = join([string(m.content) for m in msgs], "\n")
            "{\"action\":\"done\",\"summary\":\"follow-up\"}"
        end)
    check("the follow-up sees the first run's actions",
          occursin("echo WARM_1", seen[]), Base.first(seen[], 200))
    seedline = findfirst(l -> startswith(l, "[seed]"), second.transcript)
    check("the follow-up is warm-seeded (not an empty seed)",
          seedline !== nothing && !occursin(" 0 chars", second.transcript[seedline]),
          seedline === nothing ? "no seed line" : second.transcript[seedline])
    # Direct cache check at the scale the user saw: 100k chars must survive a
    # stop/restart seed path instead of collapsing to the 6k fallback.
    conv = Flooty.conversationFor("warm-large-probe")
    Flooty.recordTask!(conv, "large task")
    big = [OllamaMessage(role = "assistant", content = "x" ^ 1000) for _ in 1:100]
    Flooty.storeRunContext!(conv, vcat([OllamaMessage(role = "system", content = "sys")], big))
    warm = Flooty.warmRunHistory(conv)
    chars = sum(m -> length(something(m.content, "")), warm; init = 0)
    check("a 100k-char warm context survives the stop boundary", chars >= 90_000, chars)
finally
    closeSession!(sess)
end
println()
if isempty(failures)
    println("WARM_CONTEXT_PROBE_OK")
else
    println("FAILED: ", join(failures, ", ")); exit(1)
end
