# sendFeedbackProbe.jl — a REFUSED send is visible feedback, not silence.
#
# Live: a send guard can still refuse while a foreground command owns the pane
# (a heredoc wedge is now self-healed, see stuckContinuationProbe). The guard
# returned before `loopTool`, so the Agent transcript had no send block and no
# action result; the driver looked like it had lost feedback. Every refusal now
# emits a tool call + failed result and an ACTION RESULT message.
#
# Run: julia --startup-file=no --project=. test/sendFeedbackProbe.jl
import FlootyPTYLayer
import Flooty
using Flooty
using FlootyPTYLayer: startReplSession, closeSession!, userWrite, tagIn

failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = detail === "" || detail === nothing ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end

sess = startReplSession(`zsh -i`; waitPrompt = false)
turns = Ref(0)
try
    sleep(1.4)
    tagIn(sess.control; mode = :agent)
    # A foreground command owns the pane: not PS2 (that self-heals), but no
    # prompt, so send must be refused with visible feedback.
    userWrite(sess, "sleep 12\n")
    # Wait until the command is genuinely RUNNING (not just typed/pending): a
    # stray pending line would be cleared by the guard and the send would run.
    running = false
    for _ in 1:40
        running = !Flooty.atIdlePrompt(sess) &&
                  isempty(FlootyPTYLayer.pendingInputLine(sess)) &&
                  !FlootyPTYLayer.shellAtPS2(sess)
        running && break
        sleep(0.05)
    end
    check("a foreground command is running", running,
          (repr(FlootyPTYLayer.promptSegment(sess)),
           repr(FlootyPTYLayer.pendingInputLine(sess))))

    complete = messages -> begin
        turns[] += 1
        if turns[] == 1
            return "{\"action\":\"send\",\"code\":\"echo HI\"}"
        end
        saw = any(m -> m.role == "user" &&
                       occursin("ACTION RESULT: ERROR", something(m.content, "")) &&
                       occursin("not at an idle prompt", something(m.content, "")),
                       messages)
        check("the refused send reaches the model as an ACTION RESULT", saw,
              length(messages))
        return "{\"action\":\"done\",\"summary\":\"recovered\"}"
    end
    res = Flooty.runAgentLoop!(sess, "respect a running command";
        completeFn = complete, maxTurns = 3, evalTimeoutS = 3.0,
        contextLimit = 100_000)
    check("the run finished", res.ok, res.summary)
    conv = Flooty.conversationFor(sess)
    items = lock(() -> copy(conv.messages), conv.lock)
    calls = filter(it -> it.message.role == "assistant" &&
                        it.message.tool_name == "send", items)
    results = filter(it -> it.message.role == "tool", items)
    check("the refused send is a TOOL CALL in the transcript", !isempty(calls),
          [(it.message.tool_name, it.message.content) for it in calls])
    check("…with a FAILED TOOL RESULT", any(it ->
          occursin("not at an idle prompt", String(it.message.content)), results),
          [String(it.message.content) for it in results])
finally
    try FlootyPTYLayer.userWrite(sess, "\u0003") catch; end
    closeSession!(sess)
end

println()
if isempty(failures)
    println("SEND_FEEDBACK_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
