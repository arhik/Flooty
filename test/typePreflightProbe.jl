# typePreflightProbe.jl — large multiline type does not write into a pager.
using Flooty
using FlootyPTYLayer: startReplSession, closeSession!, userWrite

failures = String[]
function check(name, ok, detail = "")
    println(ok ? "PASS  " : "FAIL  ", name, isempty(detail) ? "" : "  [" * string(detail) * "]")
    ok || push!(failures, name)
end

file = tempname(); write(file, join(["line $i" for i in 1:100], "\n"))
sess = startReplSession(`zsh -i`; waitPrompt=false)
try
    sleep(1.2)
    userWrite(sess, "less $(file)\n")
    sleep(0.7)
    calls = Ref(0)
    res = Flooty.runAgentLoop!(sess, "type into pager"; maxTurns=4,
        completeFn = _ -> begin
            calls[] += 1
            calls[] == 1 ?
                "{\"action\":\"type\",\"keys\":\"cat > /tmp/nope <<'EOF'\\nconst X = 1\\nEOF\\n\"}" :
                "{\"action\":\"done\",\"summary\":\"done\"}"
        end)
    tr = join(res.transcript, "\n")
    check("large multiline type is refused while a pager owns the pane",
          occursin("large multiline type refused", tr), first(tr, 300))
    check("…without a successful type result", !occursin("typed 40 key(s)", tr), tr)
    check("…then the run can finish", res.ok, res.summary)
finally
    closeSession!(sess)
end
println()
if isempty(failures)
    println("TYPE_PREFLIGHT_PROBE_OK")
else
    println("FAILED: ", join(failures, ", ")); exit(1)
end
