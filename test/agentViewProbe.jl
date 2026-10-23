# agentViewProbe.jl — EXACTLY what the model receives as "the terminal".
#
# The agent's picture of the pane is `string(agentSnapshot(sess))`, pushed as a
# `TERMINAL SNAPSHOT` user message every turn. This probe captures those messages
# with a scripted `completeFn` (no model), then compares the snapshot's
# `outputTail` with the rendered viewport the PAGE reported (`terminalBufferFor`)
# — "agent and user see the same content" as a checkable equality.
#
# It also reproduces the `sed` repetition: `sed -i` prints NOTHING, so the screen
# (and therefore the snapshot) is byte-identical next turn; the model has no
# signal that its edit landed and re-sends. The probe prints each turn's snapshot
# so the mechanism is visible, then shows that a printing command updates it.
#
# The run happens on a background task while the Cocoa loop pumps the page — the
# same arrangement the standing agent runner uses.
#
# Run: julia --startup-file=no --project=. test/agentViewProbe.jl   (opens a window)
using Flooty
using FlootyPTYLayer
import FlootyPTYLayer: startReplSession, closeSession!, adoptSessionTerminal!,
    userWrite, terminalBufferFor, pushTerminalBuffer!, ptyWinsize, currentState, tagIn
import Webviews

const R = Flooty
const L = FlootyPTYLayer

failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = detail === "" || detail === nothing ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end

"Last TERMINAL SNAPSHOT message in a model payload (that is the pane, verbatim)."
function snapshotOf(messages)
    idx = findlast(m -> m.role == "user" &&
                        startswith(something(m.content, ""), "TERMINAL SNAPSHOT"),
                   messages)
    idx === nothing ? nothing : String(messages[idx].content)
end

"Everything after `outputTail:` in a snapshot, whitespace-trimmed."
function tailOf(snapshot)
    snapshot === nothing && return nothing
    pos = findfirst("outputTail:", snapshot)
    pos === nothing && return ""
    return strip(snapshot[last(pos) + 1:end])
end

const FILE = joinpath(mktempdir(), "agent-view.txt")
write(FILE, "ALPHA\nBETA\nGAMMA\n")

"Snapshot tail for `page`, exactly as `agentSnapshot` builds it: the whole page."
expectedTail(page, sess) = strip(R.cleanSnapshotText(page))

const wv = L.launchTerminalUI()
const t0 = time()
say(m) = (println("[VIEW] ", round(time() - t0; digits = 2), "s ", m); flush(stdout))

const sess = startReplSession(`zsh -i`; waitPrompt = false)
const captured = String[]
const compared = Bool[]
const state = Ref(:wait_page)
const runDone = Ref(false)
const result = Ref{Any}(nothing)

function closeAll()
    R.disableJournalPersistence!()
    try
        closeSession!(sess)
    catch e
    end
    try
        Webviews.close(wv)
    catch e
        L.requestStopEventLoop!(wv)
    end
    return nothing
end

function scriptedRun()
    script = [
        # turn 1: silent edit (sed -i prints nothing)
        m -> ("{\"action\":\"send\",\"code\":\"sed -i '' -e 's/BETA/DELTA/' " * FILE * "\"}"),
        # turn 2: printing read — the screen should now show DELTA
        m -> ("{\"action\":\"send\",\"code\":\"sed -n '1,3p' " * FILE * "\"}"),
        # turn 3: done
        m -> ("{\"action\":\"done\",\"summary\":\"checked the screen\"}"),
    ]
    turn = Ref(0)
    fake = messages -> begin
        turn[] += 1
        push!(captured, snapshotOf(messages))
        # Exact equality races: output keeps arriving between the snapshot and
        # this fresh report. What must hold is that the model saw the CURRENT
        # screen — the snapshot's last visible line is on the page now.
        page = pushTerminalBuffer!(sess; waitS = 0.4)
        snapTail = tailOf(last(captured))
        lastLine = snapTail === nothing ? "" :
                   (isempty(strip.(split(snapTail, '\n'))) ? "" :
                    last(split(strip(snapTail), '\n')))
        push!(compared, !isempty(page) && !isempty(lastLine) &&
                        occursin(strip(lastLine), page))
        turn[] <= length(script) ? script[turn[]](messages) :
        "{\"action\":\"done\",\"summary\":\"end\"}"
    end
    try
        result[] = R.runTerminalAgent!(sess, "edit the file and report what the screen shows";
                                       completeFn = fake, maxTurns = 4, evalTimeoutS = 20.0)
    catch err
        say("run failed: " * sprint(showerror, err))
    finally
        runDone[] = true
    end
    return nothing
end

function finish()
    res = result[]
    say("run finished: " * repr(res === nothing ? nothing : (ok = res.ok, summary = res.summary)))
    for (i, snap) in enumerate(captured)
        say("---- turn " * string(i) * " snapshot (what the LLM received) ----")
        println(snap === nothing ? "<none>" : snap)
        say("---- turn " * string(i) * " fidelity (snapshot tail == page viewport): " *
            string(get(compared, i, false)) * " ----")
    end
    check("the model receives a snapshot every turn", length(captured) >= 3, length(captured))
    check("the snapshot carries the rendered pane", all(s -> s !== nothing &&
                                                             occursin("ALPHA", s), captured))
    check("snapshot outputTail EQUALS the page's rendered viewport (all turns)",
          all(compared), compared)
    check("the snapshot picked up the agent's OWN command echo (fresh, not stale)",
          length(captured) >= 2 && captured[2] !== nothing &&
          occursin("sed -i", captured[2]))
    # Line-based: the echo of `sed -i 's/BETA/DELTA/'` CONTAINS both words, so a
    # substring test would lie; a result line is what the model gets to see.
    hasLine(snap, word) = snap !== nothing &&
                          any(==(word), strip.(split(tailOf(snap), '\n')))
    check("a silent command leaves no RESULT line on screen (why sed -i repeats)",
          length(captured) >= 2 && !hasLine(captured[1], "DELTA") &&
          !hasLine(captured[2], "DELTA"))
    # The pane keeps history, so BETA from the earlier printf is still up there;
    # what matters is that the fresh result line (DELTA) reached the model.
    check("a printing command DOES show its result to the model",
          length(captured) >= 3 && hasLine(captured[3], "DELTA"))
    closeAll()
    println()
    if isempty(failures)
        println("AGENT_VIEW_PROBE_OK")
    else
        println("FAILED CHECKS: ", join(failures, ", "))
        exit(1)
    end
    return nothing
end

function tick()
    if runDone[]
        return finish()
    end
    Webviews.set_timeout(tick, wv, 0.2)
    return nothing
end

function startRun()
    tagIn(sess.control; mode = :agent)
    adoptSessionTerminal!(sess; name = "agent view probe")
    Webviews.set_timeout(function ()
        userWrite(sess, "printf 'ALPHA\\nBETA\\nGAMMA\\n'\n")
        Webviews.set_timeout(function ()
            say("starting the scripted agent run")
            @async scriptedRun()
            Webviews.set_timeout(tick, wv, 0.2)
        end, wv, 1.5)
    end, wv, 2.0)
end

function boot()
    say("page up")
    Webviews.set_timeout(startRun, wv, 1.0)
end

Webviews.set_timeout(boot, wv, 2.0)
Webviews.set_timeout(function ()
    say("watchdog")
    finish()
end, wv, 120.0)
L.runEventLoopAndTeardown!(wv)
exit(0)
