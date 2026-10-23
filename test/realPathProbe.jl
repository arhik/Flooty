# realPathProbe.jl — the REAL completion path: default completeFn, streaming client,
# a live endpoint, one terminal, one task.
#
# Every other probe injects a scripted `completeFn`; that is why a regression in
# `makeCompleteFn`/`actorCompleteFn` (they were accidentally deleted) and in the
# monitor's default sink (it aborted the session hook, so no agent attached) went
# unnoticed while the suites stayed green and the app's chat did nothing.
#
# This probe runs exactly what the app runs: `runTerminalAgent!` with NO
# completeFn, against the configured endpoint. It SKIPS (exit 0) when the endpoint
# is unreachable, so the suite still works offline.
#
# Run: julia --startup-file=no --project=. test/realPathProbe.jl
using Flooty
using FlootyPTYLayer: startReplSession, closeSession!

failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = detail === "" || detail === nothing ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end

if !ollamaReachable()
    println("SKIP: endpoint unreachable — real-path probe needs a live model")
    println("REAL_PATH_PROBE_SKIPPED")
    exit(0)
end

cfg = defaultAgentModelConfig()
println("endpoint=", cfg.baseUrl, " model=", cfg.actorModel)

# ---- the builders exist and are callable (the regression that bit us) -------
check("makeCompleteFn is defined", Flooty.makeCompleteFn isa Function)
check("actorCompleteFn is defined", Flooty.actorCompleteFn isa Function)
check("monitorCompleteFn is defined", Flooty.monitorCompleteFn isa Function)
fn = Flooty.actorCompleteFn(defaultAgentModelConfig())   # throws if broken
check("actorCompleteFn builds a completion", fn isa Function)

sess = startReplSession(`julia --startup-file=no -q`)
try
    sleep(2.0)
    res = runTerminalAgent!(sess, "print 1 and stop"; maxTurns = 4, evalTimeoutS = 25.0)
    transcript = join(res.transcript, "\n")
    check("a REAL run finishes (default streaming completion)", res.ok, res.summary)
    check("…the terminal was driven", occursin("send:", transcript) ||
          occursin("ok:", transcript), first(transcript, 160))
    check("…it did not die on a missing builder",
          !occursin("UndefVarError", transcript) && !occursin("MethodError", transcript))
    conv = conversationFor(sess)
    check("the run is in the transcript", length(conversationTranscript(conv)) >= 2,
          length(conversationTranscript(conv)))
finally
    closeSession!(sess)
end

println()
if isempty(failures)
    println("REAL_PATH_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
