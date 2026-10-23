# agentUi.jl — launch the Flooty terminal UI WITH standing agents attached.
#
# WHY THIS FILE: the assist bar's instructions are consumed by standing
# agents that Flooty attaches via its session-terminal hook (__init__).
# Launching the UI from a process that only loads FlootyPTYLayer leaves every
# new tab WITHOUT an agent — prompts queue forever, Ollama is never called,
# and `ollama ps` stays empty. Loading BOTH packages here makes every tab
# agent-backed (monitor + runner auto-attached to each new session).
#
# Run:
#   julia --startup-file=no --project=/Users/arhik/.julia/dev/Flooty \
#       /Users/arhik/.julia/dev/Flooty/agentUi.jl [timeoutS]
#
# Close the window to quit; a watchdog force-quits after timeoutS (default 0 =
# no watchdog). The Poolside AI API at https://inference.poolside.ai/v1 is
# used with model `poolside/laguna-s-2.1` (configurable via FLOOTY_ACTOR_MODEL and
# FLOOTY_MONITOR_MODEL).

import FlootyPTYLayer
import Flooty

timeoutS = length(ARGS) >= 1 ? parse(Float64, ARGS[1]) : 0.0

if timeoutS > 0
    @async begin
        sleep(timeoutS)
        if FlootyPTYLayer.terminalUiRunning[]
            println("WATCHDOG: still running after ", timeoutS, "s — quitting")
            exit(42)
        end
    end
end

# The application itself lives in the package (src/app.jl): this script is only the
# convenience entry point — `julia --project=. agentUi.jl [timeoutS] ["<instruction>"]`.
# A leading number is the watchdog (0 = none, the documented default); the rest is an
# optional instruction for the first tab.
timeoutS = 0.0
taskArgs = String[]
if !isempty(ARGS) && (v = tryparse(Float64, ARGS[1])) !== nothing
    timeoutS = v
    taskArgs = String.(ARGS[2:end])
else
    taskArgs = String.(ARGS)
end
task = join(taskArgs, " ")

if timeoutS > 0
    @async begin
        sleep(timeoutS)
        if FlootyPTYLayer.terminalUiRunning[]
            println("WATCHDOG: still running after ", timeoutS, "s — quitting")
            exit(42)
        end
    end
end
println("opening agent-capable terminal UI — type in the assist bar to ",
        "commission THIS tab's agent; close window to quit")
app = Flooty.runAgentApp(task = task)
println("[app] conversations held: ", length(Flooty.appConversations(app)))
println("AGENT_UI_CLOSED")
exit(0)
