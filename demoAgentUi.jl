# demoAgentUi.jl — INTERACTIVE demo: a standing agent PER REPL SESSION.
#
# NOTE: closing the window tears down the UI registry, which closes the
# adopted session PTYs — they ARE the same processes. The demo handles that.
#
# Uses the Poolside AI inference API (https://inference.poolside.ai/v1)
# with model `poolside/laguna-s-2.1` — no local daemon needed.
#
# Run:
#   julia --startup-file=no --project=. demoAgentUi.jl [timeoutS]
#
# End the demo by closing the window; a watchdog force-quits after timeoutS
# seconds (default 300).
import FlootyPTYLayer
import Flooty
using FlootyPTYLayer: startReplSession, closeSession!, runTerminalUI,
    adoptSessionTerminal!, attachSessionTerminalToWindow,
    activeTerminalUiWebview, tailText, scrubSentinelLines, ReplSession
using Flooty: startAgentRunner!, stopAgentRunner!,
    startMonitor!, stopMonitor!, pushPopup!

timeoutS = length(ARGS) >= 1 ? parse(Float64, ARGS[1]) : 300.0

# The window must NOT auto-spawn its own julia tab: we adopt ours into it.
ENV["FLOOTY_UI_SKIP_AUTOCREATE"] = "1"

# PLAIN interactive julia children: each agent types into the very same
# stock prompt its user sees. No init script, no chords, no mode machine.
childCmd = `/bin/zsh -i`

"""Start one plain REPL session with its own agent + monitor, then adopt it."""
function adoptWithAgent(name::AbstractString)
    println("starting $name REPL session ...")
    sess = startReplSession(childCmd; waitPrompt = false)
    # Wait for the idle prompt so adoption replays real history.
    t0 = time()
    while time() - t0 < 20 && !occursin(r"[%\$#>]\s*$", replace(tailText(sess.tail), r"\e\[[0-?]*[ -/]*[@-~]" => ""))
        sleep(0.1)
    end
    println("starting ambient monitor + standing agent for $name ...")
    println("monitor started: ", startMonitor!(sess))
    println("standing agent: ",
            startAgentRunner!(sess) ? "ready" : "ALREADY RUNNING")
    # adoptSessionTerminal! ALREADY pushes the tab to the live window (with
    # scrubbed-tail replay). Attaching AGAIN here opened a SECOND tab bound
    # to the SAME PTY — closing either tab killed the shared process behind
    # both. One adoption = exactly one tab.
    id = adoptSessionTerminal!(sess; name = name)
    println("[demo] $name session adopted as terminal ", id)
    return sess
end

sessions = ReplSession[]
try
    setup = @async begin
        sleep(3.5)                     # let the window render + skip ping first
        try
            # ONE session -> one tab -> one standing agent (+ New Terminal
            # adds more later, each with its own agent).
            push!(sessions, adoptWithAgent("terminal"))
            println("[demo] HOW TO USE: type a task in the assist bar — THIS " *
                    "session's agent wakes and works IN ITS PANE. It hands " *
                    "the REPL back when done. Typing in the pane interrupts " *
                    "it.")
            pushPopup!("Flooty Agent",
                       "Session ready. Commission me from the assist bar below.")
        catch err
            @error "[demo] setup failed" exception = err
        end
    end

    t = @async begin                   # watchdog: force-quit after timeoutS
        deadline = time() + timeoutS
        while time() < deadline && FlootyPTYLayer.terminalUiRunning[]
            sleep(0.25)
        end
        if time() >= deadline && FlootyPTYLayer.terminalUiRunning[]
            println("WATCHDOG: still running after ", timeoutS, "s — quitting")
            exit(42)
        end
    end

    println("opening terminal window — click a tab, commission its agent from the assist bar; close to end")
    runTerminalUI()                    # BLOCKS until the window closes
    wait(setup)
    wait(t)
finally
    stopAgentRunner!()                 # stops ALL per-session agents
    stopMonitor!()                     # stops ALL per-session monitors
    for sess in sessions
        try
            closeSession!(sess)
        catch
        end
    end
end
println("DEMO_AGENT_UI_OK")
exit(0)
