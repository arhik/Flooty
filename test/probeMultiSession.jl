# probeMultiSession.jl — ONE AGENT PER SESSION:
#   * TWO independent ReplSessions, each adopted as its own terminal id
#   * each gets its own standing agent (startAgentRunner! wins on BOTH)
#   * focus routing: setActiveOwnershipSession(id) decides which session the
#     UI-level actions (assist submit / takeover) act upon
#   * both agents commissioned IN PARALLEL drive their OWN PTYs and finish
#     independently of each other.
#
# Run: julia --startup-file=no --project=. test/probeMultiSession.jl
using Test
using FlootyPTYLayer
using Flooty

Flooty.ollamaReachable() || begin
    println("OLLAMA_DOWN — SKIPPING")
    exit(0)
end

startPlain() = begin
    sess = startReplSession(`julia --startup-file=no -q -i`)
    t0 = time()
    while time() - t0 < 20 &&
          !occursin("julia>", FlootyPTYLayer.tailText(sess.tail))
        sleep(0.1)
    end
    sess
end

waitIdle(runnerBusyFn::Function; limitS::Real = 240.0) = begin
    t0 = time()
    while time() - t0 < limitS && runnerBusyFn()
        sleep(0.5)
    end
end

sessA = startPlain()
sessB = startPlain()
try
    @test sessA !== sessB
    idA = FlootyPTYLayer.adoptSessionTerminal!(sessA; name = "probe A")
    idB = FlootyPTYLayer.adoptSessionTerminal!(sessB; name = "probe B")
    @test idA != idB

    # Each session gets its OWN standing agent — both must start cleanly.
    @test Flooty.startAgentRunner!(sessA)
    @test Flooty.startAgentRunner!(sessB)   # no global single-runner veto
    @test Flooty.agentRunnerRunning(sessA)
    @test Flooty.agentRunnerRunning(sessB)

    # Focus routing: actions target whichever session's tab is "active".
    FlootyPTYLayer.setActiveOwnershipSession(idA)
    Flooty.pushAssistPrompt!(
        sessA, "Set a = 21, then print \"INTENT_A_\", 2a. Finish when printed.")
    tWake = time()
    while time() - tWake < 60 &&
          !(Flooty.agentRunnerBusy(sessA) &&
            FlootyPTYLayer.currentState(sessA.control) == :agent)
        sleep(0.2)
    end
    @test Flooty.agentRunnerBusy(sessA)     # A's own agent woke
    @test FlootyPTYLayer.currentState(sessA.control) == :agent

    # Put B under agent ownership too, then interact with B while A is
    # the global active target: ownership must hit ONLY B, never A.
    FlootyPTYLayer.tagIn(sessB.control; mode = :agent)
    FlootyPTYLayer.setActiveOwnershipSession(idA)
    @test FlootyPTYLayer.handleTerminalInput(idB, "")
    sleep(0.2)
    @test FlootyPTYLayer.currentState(sessB.control) == :user
    @test FlootyPTYLayer.currentState(sessA.control) == :agent   # A unaffected

    Flooty.pushAssistPrompt!(
        sessB, "Set b = 33, then print \"INTENT_B_\", 3b. Finish when printed.")

    # Both commissions wake their own runner.
    t0 = time()
    while time() - t0 < 60 &&
          !(Flooty.agentRunnerBusy(sessA) &&
            Flooty.agentRunnerBusy(sessB))
        sleep(0.2)
    end
    @test Flooty.agentRunnerBusy(sessA)
    @test Flooty.agentRunnerBusy(sessB)

    # Both runs finish independently; each output lands in its OWN pane.
    waitIdle(() -> Flooty.agentRunnerBusy(sessA))
    waitIdle(() -> Flooty.agentRunnerBusy(sessB))
    sleep(0.5)
    tailA = replace(FlootyPTYLayer.tailText(sessA.tail), r"\s+" => "")
    tailB = replace(FlootyPTYLayer.tailText(sessB.tail), r"\s+" => "")
    @test occursin("INTENT_A_42", tailA)
    @test !occursin("INTENT_B", tailA)             # no cross-talk
    @test occursin("INTENT_B_99", tailB)
    @test !occursin("INTENT_A", tailB)             # no cross-talk
    @test FlootyPTYLayer.currentState(sessA.control) == :user
    @test FlootyPTYLayer.currentState(sessB.control) == :user
    println("transcript A tail: ", last(Flooty.lastAgentTranscript(), 2))
    println("PROBE_MULTI_SESSION_OK")
catch e
    println("PROBE_MULTI_SESSION_FAILED: ", sprint(showerror, e))
    rethrow()
finally
    Flooty.stopAgentRunner!()
    closeSession!(sessA)
    closeSession!(sessB)
end
exit(0)
