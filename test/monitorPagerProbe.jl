# monitorPagerProbe.jl — pager + parser signals reach the monitor/driver.
using Flooty
using FlootyPTYLayer: startReplSession, closeSession!, userWrite, inAltScreen

failures = String[]
function check(name, ok, detail = "")
    println(ok ? "PASS  " : "FAIL  ", name, isempty(detail) ? "" : "  [" * string(detail) * "]")
    ok || push!(failures, name)
end

file = tempname()
write(file, join(["line $i" for i in 1:200], "\n"))
sess = startReplSession(`zsh -i`; waitPrompt = false)
try
    sleep(1.2)
    check("an idle shell prompt is not misread as a pager",
          !Flooty.pagerActive(sess, Flooty.tailRecentText(sess)))
    userWrite(sess, "less $(file)\n")
    sleep(0.8)
    check("less is running without a prompt", !Flooty.atIdlePrompt(sess, Flooty.tailRecentText(sess)))
    calls = Ref(0)
    startMonitor!(sess; cfg = MonitorConfig(pollS = 0.1),
                  completeFn = _ -> (calls[] += 1; "{\"decision\":\"observe\"}"))
    sleep(0.7)
    notes = takeMonitorNotes!(sess)
    joined = join(notes, "\n")
    check("the monitor detects the pager", occursin("PAGER ACTIVE", joined), joined)
    check("…and directs the driver to type keys",
          occursin("space = next page", joined) && occursin("Do NOT use send", joined), joined)
    check("…without spending a model call", calls[] == 0, calls[])

    userWrite(sess, "q")
    sleep(0.4)
    Flooty.noteAgentParseFailure!(sess, "<thinking>only reasoning, no action</thinking>")
    Flooty.noteAgentParseFailure!(sess, "<thinking>still reasoning, no action</thinking>")
    sleep(0.5)
    pnotes = takeMonitorNotes!(sess)
    pjoin = join(pnotes, "\n")
    check("the monitor names the parser failure", occursin("unparseable", pjoin), pjoin)
    check("…and suggests a different output approach",
          occursin("no <thinking>", pjoin) || occursin("output the JSON object only", pjoin),
          pjoin)
    stopMonitor!(sess)
finally
    closeSession!(sess)
end
println()
if isempty(failures)
    println("MONITOR_PAGER_PROBE_OK")
else
    println("FAILED: ", join(failures, ", ")); exit(1)
end
