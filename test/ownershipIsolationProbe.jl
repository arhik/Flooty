# ownershipIsolationProbe.jl — OWNERSHIP IS PER SESSION:
#   * two independent REPL sessions, each adopted under its own terminal id
#   * both are handed to the agent (:agent) — the state each session is in
#   * the user types into session B: ONLY B flips to :user, A keeps the agent
#   * the UI-level ownership actions (takeover / typing / resume) route to the
#     session named by the terminal id, never to whichever session happens to
#     be the globally active one
#   * a control-state listener scoped to one session hears only that session's
#     transitions (a process-wide listener would report other sessions' state)
#
# Run: julia --startup-file=no --project=. test/ownershipIsolationProbe.jl
using Test
using FlootyPTYLayer

startPlain() = begin
    sess = startReplSession(`julia --startup-file=no -q -i`)
    t0 = time()
    while time() - t0 < 20 &&
          !occursin("julia>", FlootyPTYLayer.tailText(sess.tail))
        sleep(0.1)
    end
    sess
end

sessA = startPlain()
sessB = startPlain()
try
    @test sessA !== sessB
    idA = FlootyPTYLayer.adoptSessionTerminal!(sessA; name = "iso A")
    idB = FlootyPTYLayer.adoptSessionTerminal!(sessB; name = "iso B")
    @test idA != idB

    # The globally active target is A. Actions MUST NOT be routed by it.
    FlootyPTYLayer.setActiveOwnershipSession(idA)

    @testset "typing in B yields only B" begin
        FlootyPTYLayer.tagIn(sessA.control; mode = :agent)
        FlootyPTYLayer.tagIn(sessB.control; mode = :agent)
        @test FlootyPTYLayer.currentState(sessA.control) == :agent
        @test FlootyPTYLayer.currentState(sessB.control) == :agent

        # Real user keystrokes into B's terminal: the PTY write is attributed to
        # B, and B's ownership flips. A is untouched.
        @test FlootyPTYLayer.handleTerminalInput(idB, "")
        sleep(0.2)
        @test FlootyPTYLayer.currentState(sessB.control) == :user
        @test FlootyPTYLayer.currentState(sessA.control) == :agent
    end

    @testset "ownership actions route by terminal id" begin
        FlootyPTYLayer.tagIn(sessA.control; mode = :agent)
        FlootyPTYLayer.tagIn(sessB.control; mode = :agent)
        # A is the global active target; asking for a takeover of B must move
        # B and leave A alone.
        @test FlootyPTYLayer.applyOwnershipAction!(:takeover, idB)
        @test FlootyPTYLayer.currentState(sessB.control) == :user
        @test FlootyPTYLayer.currentState(sessA.control) == :agent
        # Resume B only.
        @test FlootyPTYLayer.applyOwnershipAction!(:resume, idB)
        @test FlootyPTYLayer.currentState(sessB.control) == :agent
        @test FlootyPTYLayer.currentState(sessA.control) == :agent
    end

    @testset "scoped control listeners hear only their own session" begin
        seenA = Symbol[]
        seenB = Symbol[]
        removeA = FlootyPTYLayer.addControlStateListener!(
            sessA.control, action -> push!(seenA, action))
        removeB = FlootyPTYLayer.addControlStateListener!(
            sessB.control, action -> push!(seenB, action))
        try
            FlootyPTYLayer.tagOut(sessB.control)
            sleep(0.1)
            @test isempty(seenA)          # A did not transition
            @test seenB == [:takeover]    # B did
            FlootyPTYLayer.tagOut(sessA.control)
            sleep(0.1)
            @test seenA == [:takeover]
            @test seenB == [:takeover]
            FlootyPTYLayer.tagIn(sessA.control; mode = :agent)
            sleep(0.1)
            @test seenA == [:takeover, :resume]
            @test seenB == [:takeover]
        finally
            removeA()
            removeB()
        end
    end
    println("PROBE_OWNERSHIP_ISOLATION_OK")
catch e
    println("PROBE_OWNERSHIP_ISOLATION_FAILED: ", sprint(showerror, e))
    rethrow()
finally
    closeSession!(sessA)
    closeSession!(sessB)
end
exit(0)
