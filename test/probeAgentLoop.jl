# probeAgentLoop.jl — deterministic end-to-end test of the autonomous loop
# WITHOUT Ollama: a scripted fake `completeFn` returns canned actions and we
# assert they actually executed against a REAL PTY-backed REPL session.
#
# Run: julia --startup-file=no --project=. test/probeAgentLoop.jl
using Test
using FlootyPTYLayer
using Flooty

println("starting headless REPL session ...")
sess = startReplSession(`julia --startup-file=no -q`)
try
    events = Vector{Flooty.AgentFeedback}()
    script = [ # one entry per turn, consumed in order
        "{\"action\":\"send\",\"code\":\"AGENT_LOOP_MARKER = 40 + 2\"}",
        "{\"action\":\"send\",\"code\":\"println(\\\"MARKER=\\\", AGENT_LOOP_MARKER)\"}",
        "{\"action\":\"wait\",\"seconds\":0.5}",
        "{\"action\":\"feedback\",\"title\":\"Loop probe\",\"body\":\"halfway\",\"kind\":\"info\"}",
        "{\"action\":\"done\",\"summary\":\"marker written and echoed\"}",
    ]
    completeFn = messages -> begin
        isempty(script) &&
            return "{\"action\":\"done\",\"summary\":\"script exhausted\"}"
        return popfirst!(script)
    end

    result = runTerminalAgent!(sess, "write AGENT_LOOP_MARKER and echo it";
                               completeFn = completeFn, maxTurns = 8,
                               onEvent = fb -> push!(events, fb))

    @testset "agent loop" begin
        @test result.ok
        @test result.turns == 5
        @test occursin("marker written", result.summary)
        # The marker must have REALLY evaluated inside the PTY session.
        # runTerminalAgent!'s finally-block yielded control to :user, so the
        # gate refuses agent writes until we tag back in — which is exactly
        # the ownership contract working as intended.
        @test FlootyPTYLayer.currentState(sess.control) == :user
        FlootyPTYLayer.tagIn(sess.control; mode = :agent)
        ok, excerpt = Flooty.agentSendStatement!(
            sess, "println(\"VERIFY_\", AGENT_LOOP_MARKER)")
        sleep(0.2)
        tail = FlootyPTYLayer.tailText(sess.tail)
        @test ok
        @test occursin("VERIFY_42", replace(tail, r"\s+" => ""))
        @test length(events) == 1
        @test events[1].title == "Loop probe"
        @test !isempty(Flooty.lastAgentTranscript())
    end

    # Ownership gate: user-owned sessions must refuse agent writes.
    FlootyPTYLayer.tagIn(sess.control; mode = :agent)
    FlootyPTYLayer.tagOut(sess.control)   # back to :user
    ok2, why = Flooty.agentSendStatement!(sess, "1+1")
    @test !ok2
    @test occursin("yield", why)

    # Interject gating: refused while user owns the session.
    sent, detail = Flooty.agentInterject!(sess, "test"; force = false)
    @test !sent

    println("transcript:")
    foreach(line -> println("  ", line), result.transcript)
    println("PROBE_AGENT_LOOP_OK")
catch e
    println("PROBE_AGENT_LOOP_FAILED: ", sprint(showerror, e))
    rethrow()
finally
    closeSession!(sess)
end
exit(0)
