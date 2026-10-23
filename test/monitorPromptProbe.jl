# monitorPromptProbe.jl — monitor prompts know the terminal viewport.
using Flooty

failures=String[]
function check(n,ok,d="")
    println(ok ? "PASS  " : "FAIL  ", n, isempty(d) ? "" : "  ["*string(d)*"]")
    ok || push!(failures,n)
end
h = Flooty.MONITOR_HARNESS_CONTEXT
check("harness context names the viewport", occursin(r"visible\s+viewport", h), h)
check("…forbids whole-file reads", occursin("Never suggest `cat", h), h)
check("…recommends bounded commands",
      occursin("sed -n", h) && occursin("head -n", h) && occursin("grep -n", h), h)
check("…says output leaves the screen", occursin("output that leaves the screen", h), h)
check("…recommends the interactive pager",
      occursin("INTERACTIVE PAGER", h) && occursin("bat FILE", h) &&
      occursin("git log", h) && occursin("less FILE", h), h)
check("…uses git's interactive pager", occursin("git --paginate log", h), h)
check("…does not disable the pager for long output",
      occursin("never recommend `--no-pager`", h), h)
check("…requires quitting the pager", occursin("Never leave", h) && occursin("pager open", h), h)
check("terminal monitor prompt includes it",
      occursin(r"visible\s+viewport", Flooty.MONITOR_SYSTEM_PROMPT))
check("terminal-event prompt includes it",
      occursin(r"visible\s+viewport", Flooty.TERMINAL_EVENT_PROMPT))
check("trajectory prompt includes it",
      occursin(r"visible\s+viewport", Flooty.TRAJECTORY_SYSTEM_PROMPT))
println()
if isempty(failures)
    println("MONITOR_PROMPT_PROBE_OK")
else
    println("FAILED: ",join(failures,", ")); exit(1)
end
