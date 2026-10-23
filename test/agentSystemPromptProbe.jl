# agentSystemPromptProbe.jl — the driver really receives the harness system prompt.
#
# Run: julia --startup-file=no --project=. test/agentSystemPromptProbe.jl
using Flooty
using FlootyPTYLayer: startReplSession, closeSession!, tagIn

failures = String[]
function check(name, ok, detail="")
    println(ok ? "PASS  " : "FAIL  ", name, isempty(detail) ? "" : "  [" * string(detail) * "]")
    ok || push!(failures, name)
end

sess = startReplSession(`zsh -i`; waitPrompt=false)
try
    sleep(1.3); tagIn(sess.control; mode=:agent)
    first_msgs = Ref{Any}(nothing)
    calls = Ref(0)
    res = runTerminalAgent!(sess, "inspect one file";
        completeFn = msgs -> begin
            calls[] += 1
            calls[] == 1 && (first_msgs[] = copy(msgs))
            "{\"action\":\"done\",\"summary\":\"ok\"}"
        end, maxTurns=2)
    msgs = first_msgs[]
    check("the first call has messages", msgs !== nothing)
    sysidx = findall(m -> m.role == "system", msgs)
    check("the system role is present", !isempty(sysidx), sysidx)
    sys = msgs[first(sysidx)].content
    check("…and carries the viewport rule", occursin("each snapshot is exactly the rows", sys))
    check("…and the bounded-read rule", occursin("FILE READS", sys) && occursin("never `cat`", sys))
    check("…names the terminal-use harness", occursin("TERMINAL-USE HARNESS", sys))
    check("…says output leaves the screen", occursin("Output that leaves the screen", sys))
    check("…recommends the interactive pager",
          occursin("INTERACTIVE PAGER", sys) && occursin("bat FILE", sys) &&
          occursin("git log", sys) && occursin("less FILE", sys))
    check("…uses git's interactive pager", occursin("git --paginate log", sys))
    check("…does not disable the pager for long output",
          occursin("Do not use `--no-pager`/`--paging=never` for a", sys))
    check("…explains driven pagers", occursin("INTERACTIVE PAGER", sys) &&
          occursin("space = next page", sys) && occursin("`q` = quit", sys))
    check("…requires quitting the pager", occursin("NEVER leave a pager open", sys))
    check("the rule is restated on the turn",
          any(m -> m.role == "system" && occursin("HARNESS REMINDER", m.content), msgs))
    wire = Flooty.requestMessages(msgs)
    check("the wire request keeps role=system",
          wire[1]["role"] == "system" && occursin("FILE READS", wire[1]["content"]),
          wire[1]["content"][1:min(end, 60)])
finally
    closeSession!(sess)
end
println()
if isempty(failures)
    println("AGENT_SYSTEM_PROMPT_PROBE_OK")
else
    println("FAILED: ", join(failures, ", ")); exit(1)
end
