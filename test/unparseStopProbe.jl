# unparseStopProbe.jl — harness warnings enter context and 3 strikes stop.
# Run: julia --startup-file=no --project=. test/unparseStopProbe.jl
using Flooty
using FlootyPTYLayer: startReplSession, closeSession!

failures=String[]
function check(n,ok,d="")
    println(ok ? "PASS  " : "FAIL  ", n, isempty(d) ? "" : "  ["*string(d)*"]")
    ok || push!(failures,n)
end
sess=startReplSession(`zsh -i`; waitPrompt=false)
seen=Ref("")
calls=Ref(0)
try
    sleep(1.2)
    # Same truncated JSON every turn; the model must not loop forever.
    res=Flooty.runAgentLoop!(sess, "invalid reply test";
        completeFn=msgs->begin
            calls[]+=1
            seen[]=join([string(m.role)*":"*string(m.content) for m in msgs], "\n")
            "{\"action\":\"send\",\"code\":\"julia -e 'using CUDA"
        end, maxTurns=10, evalTimeoutS=2.0)
    check("the harness does NOT stop at three unparseable replies",
          calls[] > 3, calls[])
    check("…it keeps going until the explicit turn budget",
          occursin("turn budget", lowercase(String(res.summary))), res.summary)
    check("…and still ends with a final report, not a silent exit",
          occursin("[final]", join(res.transcript, "\n")))
    check("…and the warning enters model context",
          occursin("HARNESS WARNING", seen[]), first(seen[],300))
finally
    try closeSession!(sess) catch end
end
println()
if isempty(failures)
    println("UNPARSE_STOP_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures,", ")); exit(1)
end
