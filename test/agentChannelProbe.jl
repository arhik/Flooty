# agentChannelProbe.jl — the monitor <-> agent channel.
#
# The user wants both models' reasoning visible and talking to each other:
#   * monitor -> agent: insights become MONITOR NOTE messages on the next turn;
#   * agent -> monitor: the loop publishes a BRIEF (task + last action) that the
#     monitor's prompt carries.
#
# Run: julia --startup-file=no --project=. test/agentChannelProbe.jl
using Flooty
using FlootyPTYLayer: startReplSession, closeSession!, tagIn

failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = detail === "" || detail === nothing ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end

sess = startReplSession(`zsh -i`; waitPrompt = false)
try
    sleep(1.3)
    tagIn(sess.control; mode = :agent)

    # ---- monitor -> agent ---------------------------------------------------
    pushMonitorNote!(sess, "the build takes ~40s; do not retry it")
    check("a note is queued", takeMonitorNotes!(sess) ==
          ["[chat] the build takes ~40s; do not retry it"], "")
    pushMonitorNote!(sess, "the build takes ~40s; do not retry it")

    seen = Ref("")
    replies = String["{\"action\":\"send\",\"code\":\"echo CHANNEL_OK\"}",
                     "{\"action\":\"done\",\"summary\":\"done\"}"]
    i = Ref(0)
    res = runTerminalAgent!(sess, "check the channel";
                            completeFn = msgs -> begin
                                i[] += 1
                                i[] == 1 && (seen[] = join([string(m.content) for m in msgs
                                                            if m.content !== nothing], "\n"))
                                replies[min(i[], length(replies))]
                            end, maxTurns = 4)
    tr = join(res.transcript, "\n")
    check("the monitor's insight reached the agent's first call",
          occursin("MONITOR NOTE (independent observation): [chat] the build takes ~40s", seen[]),
          first(seen[], 200))
    check("…and is visible in the transcript",
          occursin("[monitor] [chat] the build takes", tr), "")

    # ---- agent -> monitor ---------------------------------------------------
    brief = agentBriefFor(sess)
    check("the brief carries the task", occursin("task: check the channel", brief),
          brief)
    check("…and the last action", occursin("last action: send", brief), brief)
    prompt = agentBriefPrompt(sess)
    check("the monitor's prompt prefix carries the brief",
          occursin("AGENT CONTEXT", prompt) && occursin("last action: send", prompt),
          first(prompt, 200))

    # A queued note is not re-delivered on the next run.
    seen2 = Ref("")
    j = Ref(0)
    res2 = runTerminalAgent!(sess, "second run";
                             completeFn = msgs -> begin
                                 j[] += 1
                                 j[] == 1 && (seen2[] = join([string(m.content) for m in msgs
                                                              if m.content !== nothing], "\n"))
                                 "{\"action\":\"done\",\"summary\":\"ok\"}"
                             end, maxTurns = 3)
    check("a consumed note is not re-delivered",
          !occursin("MONITOR NOTE: the build takes", seen2[]), first(seen2[], 120))
finally
    closeSession!(sess)
end

println()
if isempty(failures)
    println("AGENT_CHANNEL_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
