# sendRepeatProbe.jl — repeated sends are allowed but cannot loop forever.
#
# Sends are deliberately NOT deduplicated: rerunning an idempotent inspection
# is legitimate, and refusing it hides terminal state from the next turn. The
# explicit turn budget is the safety net.
#
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
    check("identical sends execute", occursin("send: echo SAME", tr), first(tr,300))
    check("…the explicit turn budget stops the loop",
          occursin("turn budget", lowercase(String(res.summary))), res.summary)
    check("…at maxTurns, not later", calls[] <= 21, calls[])
finally
    closeSession!(sess)
end
println()
if isempty(failures)
    println("SEND_REPEAT_PROBE_OK")
else
    println("FAILED: ",join(failures,", ")); exit(1)
end
