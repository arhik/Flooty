# reasoningFallbackProbe.jl — encoder failure still yields a bounded probe.
using Flooty
using FlootyPTYLayer: startReplSession, closeSession!, tagIn

failures = String[]
function check(name, ok, detail = "")
    println(ok ? "PASS  " : "FAIL  ", name, isempty(detail) ? "" : "  [" * string(detail) * "]")
    ok || push!(failures, name)
end

sess = startReplSession(`zsh -i`; waitPrompt = false)
try
    sleep(1.2); tagIn(sess.control; mode = :agent)
    calls = Ref(0)
    res = Flooty.runAgentLoop!(sess, "probe fallback"; maxTurns = 5,
        completeFn = msgs -> begin
            calls[] += 1
            encoder = any(m -> m.role == "system" &&
                              occursin("encode a terminal agent", m.content), msgs)
            if calls[] == 1
                "<thinking>I should look around first.</thinking>"
            elseif encoder
                "<thinking>still only reasoning</thinking>"
            else
                "{\"action\":\"done\",\"summary\":\"fallback worked\"}"
            end
        end)
    tr = join(res.transcript, "\n")
    check("the bounded probe is used", occursin("running a bounded probe", tr), first(tr, 200))
    check("…and it executes pwd/ls", occursin("send: pwd && ls -la", tr), tr)
    check("…with no unparseable warning", !occursin("unparseable model output", tr), tr)
    check("the run reaches done", res.ok, res.summary)
finally
    closeSession!(sess)
end
println()
if isempty(failures)
    println("REASONING_FALLBACK_PROBE_OK")
else
    println("FAILED: ", join(failures, ", ")); exit(1)
end
