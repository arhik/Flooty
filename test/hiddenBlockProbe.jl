# hiddenBlockProbe.jl — the two remaining silent blocks are guarded:
#   * no prompt => the command is NOT typed into whatever owns the screen;
#   * eval timeout => the agent-owned command is Ctrl+C'd instead of running on
#     invisibly while the driver believes it failed.
#
# Run: julia --startup-file=no --project=. test/hiddenBlockProbe.jl
import FlootyPTYLayer
using FlootyPTYLayer: startReplSession, closeSession!, tagIn, userWrite,
    agentWriteAndWait, tailText

failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = detail === "" || detail === nothing ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end

sess = startReplSession(`zsh -i`; waitPrompt = false)
try
    sleep(1.4)
    tagIn(sess.control; mode = :agent)
    # ---- no prompt: refuse rather than type blind -------------------------
    userWrite(sess, "echo PARTIAL")        # deliberately not submitted
    sleep(0.3)
    outcome = agentWriteAndWait(sess, "echo SHOULD_NOT_RUN"; timeout = 1.0)
    check("a non-idle prompt refuses the send",
          !outcome.ok && occursin("not at an idle prompt", outcome.excerpt),
          first(outcome.excerpt, 160))
    check("…nothing was typed into the pending line",
          !occursin("SHOULD_NOT_RUN", tailText(sess.tail)), "")
    # Clear the partial line deterministically before the timeout test.
    for _ in 1:6
        isempty(FlootyPTYLayer.pendingInputLine(sess)) && break
        userWrite(sess, "\x03")
        sleep(0.25)
    end
    check("the partial line can be cleared",
          isempty(FlootyPTYLayer.pendingInputLine(sess)),
          repr(FlootyPTYLayer.pendingInputLine(sess)))

    # ---- timeout: stop the agent-owned command ----------------------------
    outcome2 = agentWriteAndWait(sess, "sleep 30"; timeout = 0.6)
    check("a timed-out send is interrupted",
          !outcome2.ok && occursin("[timeout: Ctrl+C sent", outcome2.excerpt),
          first(outcome2.excerpt, 180))
    sleep(0.8)
    check("…the prompt comes back",
          FlootyPTYLayer._tailAtIdlePrompt(FlootyPTYLayer.promptSegment(sess)),
          repr(FlootyPTYLayer.promptSegment(sess)))
    after = agentWriteAndWait(sess, "echo AFTER_TIMEOUT"; timeout = 5.0)
    check("…and the pane is usable", after.ok && occursin("AFTER_TIMEOUT", after.excerpt),
          first(after.excerpt, 120))
finally
    closeSession!(sess)
end

println()
if isempty(failures)
    println("HIDDEN_BLOCK_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
