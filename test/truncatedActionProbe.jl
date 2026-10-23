# truncatedActionProbe.jl — an output-capped `send` is recovered as one action.
#
# Run: julia --startup-file=no --project=. test/truncatedActionProbe.jl
using Flooty
using FlootyPTYLayer: startReplSession, closeSession!, tagIn

failures = String[]
function check(name, ok, detail = "")
    println(ok ? "PASS  " : "FAIL  ", name, isempty(detail) ? "" : "  [" * string(detail) * "]")
    ok || push!(failures, name)
end

const R = Flooty.recoverTruncatedSend
check("recovers a complete command cut before the closing JSON",
      R("{\"action\":\"send\",\"code\":\"find . -name '*test*' | head -200") ==
      "find . -name '*test*' | head -200")
check("decodes escaped quotes",
      R("{\"action\":\"send\",\"code\":\"printf \\\"ok\\\"") ==
      "printf \"ok\"")
check("rejects an unterminated string", R("{\"action\":\"send\",\"code\":\"echo 'x") === nothing)
check("rejects a dangling operator", R("{\"action\":\"send\",\"code\":\"ls &&") === nothing)

sess = startReplSession(`zsh -i`; waitPrompt = false)
try
    sleep(1.3); tagIn(sess.control; mode = :agent)
    replies = String[
        "<thinking>read</thinking>\n{\"action\":\"send\",\"code\":\"echo TRUNCATED_OK",
        "{\"action\":\"done\",\"summary\":\"recovered\"}",
    ]
    n = Ref(0)
    res = runTerminalAgent!(sess, "recover a truncated send"; maxTurns = 4,
        completeFn = _ -> (n[] += 1; replies[min(n[], length(replies))]))
    tr = join(res.transcript, "\n")
    check("the recovered send executed", occursin("TRUNCATED_OK", tr), tr)
    check("the run continued to done", res.ok && occursin("recovered", res.summary), res.summary)
    check("…without an unparseable strike", !occursin("unparseable", tr), tr)
finally
    closeSession!(sess)
end

println()
if isempty(failures)
    println("TRUNCATED_ACTION_PROBE_OK")
else
    println("FAILED: ", join(failures, ", ")); exit(1)
end
