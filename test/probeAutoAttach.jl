# probeAutoAttach.jl — "+ New Terminal" must carry its own agent:
#   * handleTerminalCreate spawns a FULL ReplSession (not a bare PTY)
#   * Flooty's hook auto-attaches monitor + standing agent
#   * the UI ownership path can hand THAT pane to its agent immediately
#   * killing the terminal marks the session closed -> runner deregisters
#
# Run: julia --startup-file=no --project=. test/probeAutoAttach.jl
using Test
using FlootyPTYLayer
using Flooty

ollama = Flooty.ollamaReachable()

id = FlootyPTYLayer.handleTerminalCreate()
try
    sess = FlootyPTYLayer.setActiveOwnershipSession(id)
    @test sess !== nothing                       # page-created => real session

    t0 = time()
    while time() - t0 < 10 && !Flooty.agentRunnerRunning(sess)
        sleep(0.1)
    end
    @test Flooty.agentRunnerRunning(sess) # hook attached the runner
    @test Flooty.monitorRunning()         # and the ambient monitor

    # The exact path the pill/assist bar uses must work on this fresh tab.
    @test FlootyPTYLayer.applyOwnershipAction!(:resume)
    @test FlootyPTYLayer.currentState(sess.control) == :agent
    FlootyPTYLayer.applyOwnershipAction!(:takeover)
    @test FlootyPTYLayer.currentState(sess.control) == :user

    if ollama
        # End-to-end: commission the fresh tab's own agent like the assist bar.
        Flooty.pushAssistPrompt!(
            sess, "Print \"AUTOATTACH_OK\" and finish.")
        t1 = time()
        while time() - t1 < 60 && !Flooty.agentRunnerBusy(sess)
            sleep(0.2)
        end
        @test Flooty.agentRunnerBusy(sess)
        t2 = time()
        while time() - t2 < 180 && Flooty.agentRunnerBusy(sess)
            sleep(0.5)
        end
        @test occursin("AUTOATTACH_OK",
                       replace(FlootyPTYLayer.tailText(sess.tail),
                               r"\s+" => ""))
    else
        println("OLLAMA_DOWN — skipping commission part")
    end

    # Kill the terminal from the page side: session closes, runner unwinds.
    @test FlootyPTYLayer.handleTerminalKill(id)
    t3 = time()
    while time() - t3 < 5 && Flooty.agentRunnerRunning(sess)
        sleep(0.2)
    end
    @test !Flooty.agentRunnerRunning(sess)
    println("PROBE_AUTO_ATTACH_OK")
catch e
    println("PROBE_AUTO_ATTACH_FAILED: ", sprint(showerror, e))
    rethrow()
end
exit(0)
