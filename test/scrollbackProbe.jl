# scrollbackProbe.jl — scroll-over content reaches the model, with a paging cue.
#
# VIEWPORT PARITY: the snapshot is exactly the visible viewport. Content that
# scrolled above is NOT sent; the snapshot reports how many lines are above so
# the model can page them deliberately with bat/sed.
#
# Run: julia --startup-file=no --project=. test/scrollbackProbe.jl  (opens a window)
import FlootyPTYLayer
import Flooty
import Webviews
const L = FlootyPTYLayer
const R = Flooty
const DIR = mktempdir()

failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = detail === "" || detail === nothing ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end

R.agentApp(sessionsDir = DIR, journalPath = joinpath(DIR, "journal.sqlite"))
wv = L.launchTerminalUI()          # auto tab: a page-bound session to snapshot
t0 = time()
say(m) = (println("[SCROLL] ", round(time() - t0; digits = 2), "s ", m); flush(stdout))

const sess = Ref{Any}(nothing)
const step = Ref(0)

function finish()
    R.disableJournalPersistence!()
    try Webviews.close(wv) catch e; L.requestStopEventLoop!(wv) end
    println()
    if isempty(failures)
        println("SCROLLBACK_PROBE_OK")
    else
        println("FAILED CHECKS: ", join(failures, ", "))
        exit(1)
    end
    return nothing
end

"Run one command in the page-bound session, then inspect the snapshot it produces."
function runAndInspect(checker, cmd, label)
    s = sess[]
    say("running: " * cmd)
    L.userWrite(s, cmd * "\n")
    Webviews.set_timeout(function ()
        local snap
        try
            snap = R.agentSnapshot(s)
        catch err
            check(label * ": agentSnapshot failed", false, sprint(showerror, err))
            return finish()
        end
        text = string(snap)
        say(label * ": " * first(replace(text, r"\s+" => " "), 150))
        checker(snap, text)
        Webviews.set_timeout(nextStep, wv, 0.3)
    end, wv, 1.5)
end

function nextStep()
    step[] += 1
    say("nextStep " * string(step[]))
    try
        if step[] == 1
            # SHORT first: the viewport has scrolled 17 lines; even here the
            # first line is NOT part of the visible viewport (no scrollback).
            runAndInspect("seq 1 60", "60-line output (fits the window)") do snap, text
                check("a short output reports its scrollback",
                      occursin(r"scrollback=\d+ lines above the viewport", text),
                      first(text, 140))
                check("…and says the lines are NOT included",
                      occursin("NOT included", text) &&
                      !occursin("included above", text), first(text, 160))
                lines = Set(strip.(split(split(text, "outputTail:")[end], '\n')))
                check("its first line is NOT in the viewport",
                      !("1" in lines), "")
            end
        elseif step[] == 2
            runAndInspect("seq 1 400", "400-line output (overflows the window)") do snap, text
                n = match(r"scrollback=(\d+) lines above the viewport", text)
                check("the snapshot says how many lines scrolled above",
                      n !== nothing, first(text, 140))
                check("…a real count (> 100 for 400 lines)",
                      n !== nothing && parse(Int, n.captures[1]) > 100,
                      n === nothing ? "-" : n.captures[1])
                lines = Set(strip.(split(split(text, "outputTail:")[end], '\n')))
                check("content that scrolled OFF the screen is NOT sent (line 200)",
                      !("200" in lines))
                check("the visible tail is still present (line 400)", "400" in lines)
                check("…and the lines above are flagged for PAGING",
                      occursin("NOT included", text) &&
                      occursin("bat --paging=always", text) &&
                      occursin("bat --paging=never", text), first(text, 160))
                check("the very first line of the long output is NOT dumped in",
                      !("1" in lines))
            end
        else
            say("steps completed")
            finish()
        end
    catch err
        say("nextStep FAILED: " * sprint(showerror, err, catch_backtrace()))
        check("the probe ran without errors", false, first(sprint(showerror, err), 120))
        finish()
    end
    return nothing
end

function boot()
    n = lock(() -> length(L.OWNERSHIP_SESSIONS), L.OWNERSHIP_SESSIONS_LOCK)
    if n == 0
        if time() - t0 > 30
            check("a page-bound session exists", false, "timeout")
            return finish()
        end
        return Webviews.set_timeout(boot, wv, 0.25)
    end
    sess[] = lock(() -> last(collect(values(L.OWNERSHIP_SESSIONS))),
                  L.OWNERSHIP_SESSIONS_LOCK)
    L.tagIn(sess[].control; mode = :agent)
    say("page-bound session ready")
    Webviews.set_timeout(nextStep, wv, 0.5)
end

Webviews.set_timeout(boot, wv, 2.0)
Webviews.set_timeout(function (); say("watchdog"); finish() end, wv, 120.0)
L.runEventLoopAndTeardown!(wv)
