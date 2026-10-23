# reasoningRetryProbe.jl — reasoning-only output is encoded into an action.
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
    res = Flooty.runAgentLoop!(sess, "run one command"; maxTurns = 4,
        completeFn = msgs -> begin
            calls[] += 1
            is_encoder = any(m -> m.role == "system" &&
                                 occursin("encode a terminal agent", m.content), msgs)
            if calls[] == 1
                "<thinking>I should run echo REASONING_OK</thinking>"
            elseif is_encoder
                "{\"action\":\"send\",\"code\":\"echo REASONING_OK\"}"
            else
                "{\"action\":\"done\",\"summary\":\"encoded\"}"
            end
        end)
    tr = join(res.transcript, "\n")
    check("the encoder path is used", occursin("encoding the intended action", tr), first(tr, 200))
    check("the encoded action executes", occursin("REASONING_OK", tr), tr)
    check("no unparseable warning is emitted", !occursin("unparseable model output", tr), tr)
    check("the run reaches done", res.ok, res.summary)
finally
    closeSession!(sess)
end
println()
if isempty(failures)
    println("REASONING_RETRY_PROBE_OK")
else
    println("FAILED: ", join(failures, ", ")); exit(1)
end
