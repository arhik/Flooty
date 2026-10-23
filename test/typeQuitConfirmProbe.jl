# typeQuitConfirmProbe.jl — a pager quit is CONFIRMED before the next send.
#
# Live: the agent typed "q" at a pager, the harness reported only "typed 1 key",
# and the next sends were refused with "[loop-guard] not at an idle prompt" while
# the pager still owned the screen. The type action now waits after a quit key and
# says whether the prompt actually returned.
#
# Run: julia --startup-file=no --project=. test/typeQuitConfirmProbe.jl
using Flooty
using FlootyPTYLayer: startReplSession, closeSession!, tagIn, tailText

failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = detail === "" || detail === nothing ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end

const DIR = mktempdir()
const BIG = joinpath(DIR, "big.txt")
write(BIG, join(["line " * lpad(string(i), 4, '0') for i in 1:400], "\n") * "\n")

sess = startReplSession(`zsh -i`; waitPrompt = false)
try
    sleep(1.5)
    tagIn(sess.control; mode = :agent)
    replies = String[
        "{\"action\":\"send\",\"code\":\"less $BIG\"}",
        "{\"action\":\"type\",\"keys\":\"q\"}",
        "{\"action\":\"send\",\"code\":\"echo TYPE_AFTER_PAGER\"}",
        "{\"action\":\"done\",\"summary\":\"pager driven\"}",
    ]
    i = Ref(0)
    res = runTerminalAgent!(sess, "open and quit the pager";
        completeFn = _ -> (i[] += 1; replies[min(i[], length(replies))]),
        maxTurns = 6)
    tr = join(res.transcript, "\n")
    check("quitting a pager reports the restored prompt",
          occursin("prompt restored", tr), first(tr, 300))
    check("the next send is accepted and runs",
          occursin("TYPE_AFTER_PAGER", tailText(sess.tail)) &&
          !occursin("not at an idle prompt", tr), last(tailText(sess.tail), 180))
    check("the run finishes", res.ok, res.summary)
finally
    closeSession!(sess)
end

println()
if isempty(failures)
    println("TYPE_QUIT_CONFIRM_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
