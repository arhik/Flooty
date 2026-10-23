# probeAgentRunner.jl — validates the STANDING agent flow end-to-end:
#   1. shared PLAIN julia child (stock prompt for user AND agent alike)
#   2. startAgentRunner! (idle)
#   3. pushAssistPrompt! == what the assist bar's flootyAssistSubmit does
#   4. runner wakes -> REAL Ollama loop drives the SAME PTY -> finishes
#   5. ownership returns to :user automatically; runner idle again
#
# Run: julia --startup-file=no --project=. test/probeAgentRunner.jl
using Test
using FlootyPTYLayer
using Flooty

Flooty.ollamaReachable() || begin
    println("OLLAMA_DOWN — SKIPPING")
    exit(0)
end

sess = startReplSession(`julia --startup-file=no -q -i`)
try
    # Wait for the stock idle prompt so the first agent payload is not typed
    # while the child is still booting.
    t0 = time()
    while time() - t0 < 20 &&
          !occursin("julia>", FlootyPTYLayer.tailText(sess.tail))
        sleep(0.1)
    end
    @test occursin("julia>", FlootyPTYLayer.tailText(sess.tail))
    id = FlootyPTYLayer.adoptSessionTerminal!(sess)

    @test Flooty.startAgentRunner!(sess)          # first start wins
    @test !Flooty.agentRunnerBusy()               # idle at first
    println("standing agent ready — commissioning (as the assist bar would)")

    # Baseline: fresh sessions start in :shared; the runner's tagOut after a
    # run is what lands the pane in explicit user ownership.
    @test FlootyPTYLayer.currentState(sess.control) in (:user, :shared)

    Flooty.pushAssistPrompt!(
        sess, "Set x = 21, then print \"INTENT_\", 2x. Finish when printed.")
    busySeen = Ref(false)
    t1 = time()
    while time() - t1 < 60
        Flooty.agentRunnerBusy() && (busySeen[] = true; break)
        sleep(0.2)
    end
    @test busySeen[]                       # runner woke on the commission

    # Wait for the run to finish and ownership to return to the user.
    t2 = time()
    while time() - t2 < 180 && Flooty.agentRunnerBusy()
        sleep(0.5)
    end
    sleep(0.5)                              # let the final tagOut land
    @test FlootyPTYLayer.currentState(sess.control) == :user
    @test !Flooty.agentRunnerBusy()

    transcript = Flooty.lastAgentTranscript()
    foreach(line -> println("  | ", line), transcript)
    @test any(line -> occursin("thinking", line), transcript)
    # Executed IN THE SHARED PANE: the loop's own excerpt (what the model saw,
    # sentinel-scrubbed) must show the printed result. The RAW tail is NOT
    # asserted: multi-line sends can split into two duplex evals, leaving the
    # print's END line beyond the excerpt window even though it executed fine.
    joined = join(transcript)
    @test occursin("INTENT_42", replace(joined, r"\s+" => ""))
    println("PROBE_AGENT_RUNNER_OK")
catch e
    println("PROBE_AGENT_RUNNER_FAILED: ", sprint(showerror, e))
    rethrow()
finally
    Flooty.stopAgentRunner!()
    closeSession!(sess)
end
exit(0)
