# stuckContinuationProbe.jl — a heredoc-like PS2 wedge self-heals.
#
# A previous send can leave a shell at `heredoc>`/`quote>` (truncated JSON,
# interrupted write, timeout). Later sends then become heredoc body: no output,
# no feedback, a long-running harness burns turns. When the AGENT owns input,
# the next turn (or the next send guard) sends Ctrl+C, waits for the real prompt,
# and continues. User-owned input is never touched.
#
# Run: julia --startup-file=no --project=. test/stuckContinuationProbe.jl
import FlootyPTYLayer
using Flooty
using FlootyPTYLayer: startReplSession, closeSession!, userWrite, tagIn, tagOut,
    agentWriteAndWait

failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = detail === "" || detail === nothing ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end

function openHeredoc(s)
    userWrite(s, "cat <<'EOF'\nheredoc body\n")
    sleep(0.35)
    return FlootyPTYLayer.shellAtPS2(s)
end

sess = startReplSession(`zsh -i`; waitPrompt = false)
try
    sleep(1.4)
    tagIn(sess.control; mode = :agent)
    check("set up a PS2 heredoc", openHeredoc(sess), repr(FlootyPTYLayer.promptSegment(sess)))

    # A user-owned continuation is NEVER auto-aborted.
    tagOut(sess.control)
    check("user-owned input is not touched",
          !FlootyPTYLayer.recoverStuckContinuation!(sess) &&
          FlootyPTYLayer.shellAtPS2(sess))
    tagIn(sess.control; mode = :agent)

    # Direct send path: recover, then run the intended command.
    out = agentWriteAndWait(sess, "echo DIRECT_RECOVERY"; timeout = 5.0)
    check("a direct send recovers and runs", out.ok &&
          occursin("DIRECT_RECOVERY", out.excerpt), first(out.excerpt, 160))
    check("…leaving a real prompt", !FlootyPTYLayer.shellAtPS2(sess))

    # Loop path: the NEXT TURN clears what the last one left.
    check("set up a second PS2 heredoc", openHeredoc(sess),
          repr(FlootyPTYLayer.promptSegment(sess)))
    turns = Ref(0)
    complete = messages -> begin
        turns[] += 1
        if turns[] == 1
            return "{\"action\":\"send\",\"code\":\"echo LOOP_RECOVERY\"}"
        end
        saw = any(m -> m.role == "user" &&
                       occursin("LOOP_RECOVERY", something(m.content, "")), messages)
        check("the model sees the recovered command's output", saw, length(messages))
        return "{\"action\":\"done\",\"summary\":\"recovered\"}"
    end
    res = Flooty.runAgentLoop!(sess, "continue after a stuck heredoc";
                        completeFn = complete, maxTurns = 3, evalTimeoutS = 5.0)
    check("the harness run completes", res.ok, res.summary)
    check("…after a turn-start recovery",
          any(l -> occursin("recovered a stuck heredoc/PS2 continuation at turn start", l),
              res.transcript), length(res.transcript))
    check("…and the command really ran",
          any(l -> occursin("-> ok: LOOP_RECOVERY", l), res.transcript),
          length(res.transcript))
finally
    try tagIn(sess.control; mode = :agent) catch end
    try userWrite(sess, "\u0003") catch end
    closeSession!(sess)
end

println()
if isempty(failures)
    println("STUCK_CONTINUATION_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
