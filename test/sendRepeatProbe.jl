# sendRepeatProbe.jl — an ignored monitor note cannot cause infinite identical sends.
# Run: julia --startup-file=no --project=. test/sendRepeatProbe.jl
using Flooty
using FlootyPTYLayer: startReplSession, closeSession!

failures=String[]
function check(n,ok,d="")
    println(ok ? "PASS  " : "FAIL  ", n, isempty(d) ? "" : "  ["*string(d)*"]")
    ok || push!(failures,n)
end
sess=startReplSession(`zsh -i`; waitPrompt=false)
calls=Ref(0)
try
    sleep(1.2)
    res=Flooty.runAgentLoop!(sess, "repeat test";
        completeFn=_ -> (calls[]+=1;
            "{\"action\":\"send\",\"code\":\"echo SAME\"}"),
        maxTurns=20, evalTimeoutS=2.0)
    tr=join(res.transcript,"\n")
    check("identical sends are skipped", occursin("identical send repeated", tr), first(tr,300))
    check("…and the run stops", occursin("stopped after repeated identical sends",
          String(res.summary)), res.summary)
    check("…before maxTurns", calls[] < 20, calls[])
finally
    closeSession!(sess)
end
println()
if isempty(failures)
    println("SEND_REPEAT_PROBE_OK")
else
    println("FAILED: ",join(failures,", ")); exit(1)
end
