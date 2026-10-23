# probeTakeover.jl — headless verification of Warp-style ownership arbitration:
#   * Take Over (tagOut to :user) PAUSES the loop without killing it — it waits
#     for either an assist instruction or waitTimeoutS of silence,
#   * submitting an assist prompt resumes the agent with that instruction as a
#     USER INTERJECTION message and the task still completes,
#   * no instruction before the timeout -> graceful yield ("yielded to user"),
#   * the raw arbitration plumbing the UI bindings call (applyOwnershipAction!)
#     drives :typing/:takeover/:resume correctly and notifies listeners.
#
# Run: julia --startup-file=no --project=. test/probeTakeover.jl
using Test
using FlootyPTYLayer
using Flooty

println("starting headless REPL session (plain stock-prompt child) ...")
sess = startReplSession(`julia --startup-file=no -q -i`)
try
    # Wait for the idle prompt so startup never races the assertions below.
    tReady = time()
    while time() - tReady < 20 &&
          !occursin("julia>", FlootyPTYLayer.tailText(sess.tail))
        sleep(0.1)
    end
    @test occursin("julia>", FlootyPTYLayer.tailText(sess.tail))
    println("plain julia REPL ready in child")
    # Adopt HEADLESSLY (no window needed) so the exact arbitration path the
    # page bindings call (applyOwnershipAction!) has a live session to act on.
    id = FlootyPTYLayer.adoptSessionTerminal!(sess)
    println("headless adoption id=", id)

    # ---- arbitration plumbing (identical to what the page bindings call) ---
    FlootyPTYLayer.tagIn(sess.control; mode = :agent)   # baseline: agent owns
    events = Symbol[]
    removeListener = FlootyPTYLayer.addControlStateListener!(
        action -> push!(events, action))

    @testset "ownership actions drive the control machine" begin
        @test FlootyPTYLayer.applyOwnershipAction!(:typing)
        @test FlootyPTYLayer.currentState(sess.control) == :user
        @test events == [:takeover]

        @test FlootyPTYLayer.applyOwnershipAction!(:takeover)   # idempotent
        @test FlootyPTYLayer.currentState(sess.control) == :user
        @test events == [:takeover]

        @test FlootyPTYLayer.applyOwnershipAction!(:resume)
        @test FlootyPTYLayer.currentState(sess.control) == :agent
        @test events == [:takeover, :resume]
        FlootyPTYLayer.tagOut(sess.control)             # back to :user baseline
        empty!(events)
    end

    @testset "assist prompt queue round-trips" begin
        FlootyPTYLayer.pushAssistPrompt!(sess, "focus on primes please")
        @test FlootyPTYLayer.takeAssistPrompts!(sess) ==
              ["focus on primes please"]
        @test isempty(FlootyPTYLayer.takeAssistPrompts!(sess))  # drained once
    end

    # ---- takeover mid-run: loop pauses, assist submit resumes w/ intent ----
    script = [
        "{\"action\":\"wait\",\"seconds\":2.0}",
        "{\"action\":\"send\",\"code\":\"println(\\\"INTENT_\\\", 6 * 7)\"}",
        "{\"action\":\"done\",\"summary\":\"resumed with user intent\"}",
    ]
    resultRef = Ref{Any}(nothing)
    sawInterjection = Ref(false)
    popups = String[]
    completeFn = messages -> begin
        isempty(script) &&
            return "{\"action\":\"done\",\"summary\":\"script exhausted\"}"
        if any(m -> occursin("USER INTERJECTION", something(m.content, "")), messages)
            sawInterjection[] = true
        end
        return popfirst!(script)
    end
    loopTask = @async begin
        resultRef[] = runTerminalAgent!(sess, "long-running demo task";
                                        completeFn = completeFn,
                                        maxTurns = 8, waitTimeoutS = 30.0,
                                        onEvent = fb ->
                                            push!(popups, fb.title * ": " * fb.body))
    end
    sleep(0.5)                            # loop is now inside its 2s wait turn
    FlootyPTYLayer.tagOut(sess.control)   # Take Over click / user keystroke

    # Wait until the loop has ACTUALLY observed the takeover and is parked in
    # its pause state. The pause popup fires synchronously BEFORE the loop
    # blocks, and `popups` is filled live by the onEvent callback (resultRef
    # only lands after the task returns) — so poll that.
    sawPause() = any(t -> occursin("You took over", t), popups)
    t0 = time()
    while !sawPause() && time() - t0 < 10.0
        sleep(0.05)
    end
    @test sawPause()                      # loop paused instead of dying
    @test currentState(sess.control) == :user
    @test !istaskdone(loopTask)           # paused-and-WAITING, not finished
    @test occursin("julia> ", FlootyPTYLayer.tailText(sess.tail))   # stays julia>
    println("[probe] agent parked in pause state — submitting assist prompt")
    FlootyPTYLayer.pushAssistPrompt!(sess, "now print INTENT_42")  # assist box
    FlootyPTYLayer.tagIn(sess.control; mode = :agent)   # submit hands it back
    sleep(1.0)                     # no prompt flip anymore — just let it land
    wait(loopTask)
    yielded = resultRef[]

    @testset "pause -> assist submit -> resume completes task" begin
        @test yielded !== nothing
        @test yielded.ok
        @test occursin("resumed with user intent", yielded.summary)
        @test sawInterjection[]           # model actually saw the instruction
        @test any(line -> occursin("[pause]", line), yielded.transcript)
        @test any(line -> occursin("[resume]", line), yielded.transcript)
        @test any(line -> occursin("now print INTENT_42", line),
                  yielded.transcript)
        @test any(t -> occursin("You took over", t), popups)
        @test any(t -> occursin("Resumed", t), popups)
        sleep(0.3)
        @test occursin("INTENT_42",
                       replace(FlootyPTYLayer.tailText(sess.tail), r"\s+" => ""))
        @test FlootyPTYLayer.currentState(sess.control) == :user
    end

    # ---- takeover with NO instruction: times out into a graceful yield -----
    script2 = [ "{\"action\":\"wait\",\"seconds\":5.0}",
                "{\"action\":\"done\",\"summary\":\"never reached\"}" ]
    completeFn2 = messages -> isempty(script2) ?
        "{\"action\":\"done\",\"summary\":\"script exhausted\"}" : popfirst!(script2)
    resultRef2 = Ref{Any}(nothing)
    loopTask2 = @async begin
        resultRef2[] = runTerminalAgent!(sess, "abandoned task";
                                         completeFn = completeFn2,
                                         maxTurns = 4, waitTimeoutS = 1.0,
                                         onEvent = _ -> nothing)
    end
    sleep(0.5)
    FlootyPTYLayer.tagOut(sess.control)
    wait(loopTask2)
    timedOut = resultRef2[]

    @testset "silent takeover yields after waitTimeoutS" begin
        @test !timedOut.ok
        @test timedOut.summary == "yielded to user"
        @test any(line -> occursin("[yield]", line), timedOut.transcript)
        @test FlootyPTYLayer.currentState(sess.control) == :user
    end

    removeListener()
    println("transcript of resumed run:")
    foreach(line -> println("  ", line), yielded.transcript)
    println("PROBE_TAKEOVER_OK")
catch e
    println("PROBE_TAKEOVER_FAILED: ", sprint(showerror, e))
    rethrow()
finally
    closeSession!(sess)
end
exit(0)
