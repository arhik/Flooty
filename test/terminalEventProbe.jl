# terminalEventProbe.jl — the terminal monitor observes terminal EVENTS.
#
# It used to speak only for long runs or user typing at the prompt, so a quick
# command (or a shell comment) produced nothing in the Terminal monitor while
# the Chat monitor invented comments from the terminal snapshot. New output that
# returns to a prompt is now an event episode with its own model decision.
#
# Run: julia --startup-file=no --project=. test/terminalEventProbe.jl
import FlootyPTYLayer
using Flooty
using FlootyPTYLayer: startReplSession, closeSession!, userWrite, tagIn

failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = detail === "" || detail === nothing ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end

sess = startReplSession(`zsh -i`; waitPrompt = false)
calls = Ref(0)
events = Any[]
try
    sleep(1.4)
    tagIn(sess.control; mode = :agent)
    startMonitor!(sess;
        completeFn = messages -> begin
            calls[] += 1
            text = join([String(something(m.content, "")) for m in messages], "\n")
            if occursin("New terminal output", text)
                return "{\"decision\":\"insight\",\"title\":\"Terminal event\"," *
                       "\"body\":\"terminal event observed\"}"
            end
            return "{\"decision\":\"observe\"}"
        end,
        onEvent = fb -> push!(events, fb),
        cfg = MonitorConfig(pollS = 0.1, interjectAfterS = 30.0,
                            eventCooldownS = 0.0,
                            intentPopupCooldownS = 0.0))
    # Wait for the first sample to arm the output cursor at the prompt; sending
    # before that makes the command part of the baseline (no event).
    st = Flooty.MONITOR_STATES[sess]
    for _ in 1:40
        st.eventArmed && break
        sleep(0.05)
    end
    check("the terminal event cursor is armed", st.eventArmed)
    userWrite(sess, "echo TERMINAL_EVENT\n")
    for _ in 1:60
        calls[] > 0 && break
        sleep(0.1)
    end
    notes = takeMonitorNotes!(sess)
    check("a quick command reaches the terminal monitor", calls[] > 0, calls[])
    check("…with a terminal-event decision",
          any(fb -> occursin("terminal event observed", fb.body), events),
          length(events))
    check("…and its insight is queued for the driver",
          any(n -> occursin("terminal event observed", n), notes), notes)
finally
    try stopMonitor!(sess) catch; end
    closeSession!(sess)
end

println()
if isempty(failures)
    println("TERMINAL_EVENT_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
