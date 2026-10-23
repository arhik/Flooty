# microEditorAppProbe.jl — the REAL model, the REAL app window, the REAL editor.
#
# The user's report was a micro session in the app where save "worked" but Ctrl-Q
# never exited (type keys were written as literal `\r`/`\x11`). This probe runs the
# whole thing end to end: an adopted zsh tab in the window, the standing agent with
# the default (streaming, live) completion, an instruction to write and save a story
# in micro, and a check of the file micro actually wrote.
#
# SKIPS (exit 0) when the endpoint is unreachable.
#
# Run: julia --startup-file=no --project=. test/microEditorAppProbe.jl  (opens a window)
import FlootyPTYLayer
import Webviews
using Flooty
const L = FlootyPTYLayer

failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = detail === "" || detail === nothing ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end

if !ollamaReachable()
    println("SKIP: endpoint unreachable")
    println("MICRO_EDITOR_APP_PROBE_SKIPPED")
    exit(0)
end
if Sys.which("micro") === nothing
    println("SKIP: micro not installed")
    println("MICRO_EDITOR_APP_PROBE_SKIPPED")
    exit(0)
end

const FILE = joinpath(mktempdir(), "app-story.txt")
const RUN = Ref{Any}(nothing)
wv = L.launchTerminalUI()
const REPORT = Ref("")

function finish()
    try Webviews.close(wv) catch e; L.requestStopEventLoop!(wv) end
    println()
    if isempty(failures)
        println("MICRO_EDITOR_APP_PROBE_OK")
    else
        println("FAILED CHECKS: ", join(failures, ", "))
        exit(1)
    end
    return nothing
end

function run()
    sess = L.startReplSession(`zsh -i`; waitPrompt = false)
    id = L.adoptSessionTerminal!(sess; name = "micro")
    println("tab=", id, " file=", FILE)
    # Timers, never `sleep`: a sleep inside this callback blocks the UI thread and
    # the adoption attach (also a timer) never runs.
    waitPrompt = function (tries = 0)
        if L._tailAtIdlePrompt(L.tailText(sess.tail))
            check("the tab is at a shell prompt", true, "")
            L.tagIn(sess.control; mode = :agent)
            return startAgent(sess)
        end
        if tries > 80
            check("the tab is at a shell prompt", false, last(L.tailText(sess.tail), 100))
            L.closeSession!(sess)
            return finish()
        end
        return Webviews.set_timeout(() -> waitPrompt(tries + 1), wv, 0.25)
    end
    waitPrompt()
    return nothing
end

function startAgent(sess)

    task = "Open the micro editor on the file $(FILE): run `micro $(FILE)`. " *
           "Then type a three-line story about a terminal that learned to think. " *
           "Use the type action; press Enter by putting \\r between lines. " *
           "Save with Ctrl-S (type \\x13). Quit with Ctrl-Q (type \\x11) and answer " *
           "y if it asks about saving changes. Then cat the file to prove it was " *
           "saved, and stop."
    # OFF THE UI THREAD, exactly as the app's monitor does. Running the loop inside
    # a run-loop callback blocks the UI (page requests time out, progress cannot
    # paint) and made the window look dead mid-run.
    RUN[] = @async runTerminalAgent!(sess, task; maxTurns = 14, evalTimeoutS = 45.0)
    poll = function ()
        istaskdone(RUN[]) || return Webviews.set_timeout(poll, wv, 0.5)
        return checkRun(sess)
    end
    Webviews.set_timeout(poll, wv, 0.5)
    return nothing
end

function checkRun(sess)
    res = try
        fetch(RUN[])
    catch e
        cause = e isa TaskFailedException ? something(e.task.exception, e) : e
        println("run error: ", sprint(showerror, cause))
        bt = try sprint(Base.show_backtrace, catch_backtrace()) catch; "" end
        println("bt: ", first(bt, 600))
        (ok = false, turns = 0, summary = sprint(showerror, cause), transcript = String[])
    end
    tr = join(res.transcript, "\n")
    println("summary: ", res.summary)
    check("the agent run completes", res.ok, res.summary)
    check("it launched micro", occursin("micro", tr), "")
    check("it typed the story (type action)", occursin("type:", tr), "")
    # micro saves with Ctrl-S, but a model may also use its command mode ("save").
    check("it saved (Ctrl-S or micro's save command)",
          occursin("\\x13", tr) || occursin("save", lowercase(tr)), "")
    check("it quit with Ctrl-Q", occursin("\\x11", tr), "")

    body = isfile(FILE) ? read(FILE, String) : ""
    lines = [strip(l) for l in split(body, '\n') if !isempty(strip(l))]
    check("micro wrote the file", isfile(FILE), FILE)
    check("…with a multi-line story", length(lines) >= 2, (length(lines), body))
    check("…and the text is a story, not escape junk",
          occursin(r"[A-Za-z]{3}", body) && !occursin("\e", body), first(body, 200))

    # The shell repaints its prompt a moment after the editor exits; the probe used
    # to sample instantly. Wait (with timers) before judging.
    settle = function (tries = 0)
        snap = Flooty.agentSnapshot(sess)
        if snap.atPrompt === true || tries > 20
            return check("the pane is back at the shell prompt after the editor",
                         snap.atPrompt === true,
                         (atPrompt = snap.atPrompt, alt = L.inAltScreen(sess),
                          tail = last(L.tailText(sess.tail), 80)))
        end
        Webviews.set_timeout(() -> settle(tries + 1), wv, 0.2)
    end
    settle()
    L.closeSession!(sess)
    finish()
    return nothing
end

Webviews.set_timeout(run, wv, 2.0)
Webviews.set_timeout(function (); println("watchdog"); finish() end, wv, 600.0)
L.runEventLoopAndTeardown!(wv)
