# resizeProbe.jl — the terminal follows the WINDOW and the pane layout.
#
# Checks the three sizes agree after a change: the xterm grid, the PTY winsize
# (what programs see), and both panes when the tab is split. Covers: native window
# resize, the chat rail being dragged (container width changes), and the split
# child (which used to be left out of the resize path).
#
# Run: julia --startup-file=no --project=. test/resizeProbe.jl  (opens a window)
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
wv = L.launchTerminalUI()
t0 = time()
say(m) = (println("[RESIZE] ", round(time() - t0; digits = 2), "s ", m); flush(stdout))
const report = Ref("")

function snapshot(then)
    before = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__rsz__", ""), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, raw"""
        (function () {
            var tabs = [];
            for (var k in terminals) {
                var i = terminals[k];
                tabs.push({ tab: k, julia: i.juliaId || null,
                            cols: i.term.cols, rows: i.term.rows,
                            w: Math.round(document.getElementById(k).getBoundingClientRect().width) });
            }
            window.flootyTerminalBufferReport(JSON.stringify({
                terminal_id: '__rsz__',
                text: JSON.stringify({ tabs: tabs, active: activeTerminalId,
                                       inner: [window.innerWidth, window.innerHeight] })
            })).catch(function () {});
        })();
    """)
    tries = Ref(0)
    poll = function ()
        txt = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__rsz__", ""), L.TERMINAL_BUFFER_LOCK)
        if txt != before || tries[] > 40
            report[] = txt
            return then(txt)
        end
        tries[] += 1
        Webviews.set_timeout(poll, wv, 0.1)
    end
    Webviews.set_timeout(poll, wv, 0.1)
    return nothing
end

"PTY winsize for the session bound to a terminal id."
function ptyFor(id)
    sess = L.sessionForTerminalId(id)
    sess === nothing && return (rows = -1, cols = -1)
    (rows, cols) = L.ptyWinsize(sess.pty)
    return (rows = rows, cols = cols)
end

function gridFor(txt, id)
    m = match(Regex("\"julia\":\"" * id * "\",\"cols\":(\\d+),\"rows\":(\\d+)"), txt)
    m === nothing && return (rows = -1, cols = -1)
    return (rows = parse(Int, m.captures[2]), cols = parse(Int, m.captures[1]))
end

function finish()
    R.disableJournalPersistence!()
    try Webviews.close(wv) catch e; L.requestStopEventLoop!(wv) end
    println()
    if isempty(failures)
        println("RESIZE_PROBE_OK")
    else
        println("FAILED CHECKS: ", join(failures, ", "))
        exit(1)
    end
    return nothing
end

function checkAgreement(label, txt, ids)
    for id in ids
        grid = gridFor(txt, id)
        pty = ptyFor(id)
        check(label * ": " * id * " grid == pty winsize",
              grid.cols == pty.cols && grid.rows == pty.rows,
              (grid, pty))
    end
end

function stepWindow(tab1)
    say("native window resize 1100x750 -> 800x560")
    Base.resize!(wv, (800, 560))
    Webviews.set_timeout(function ()
        snapshot() do txt
            say("after window resize: " * txt)
            checkAgreement("window resize", txt, [tab1])
            inner = match(r"\"inner\":\[(\d+),(\d+)\]", txt)
            check("the xterm grid followed the window",
                  inner !== nothing && parse(Int, inner.captures[1]) == 800 &&
                  gridFor(txt, tab1).cols < 69,
                  (inner === nothing ? "-" : inner.captures, gridFor(txt, tab1)))
            stepChatWidth(tab1)
        end
    end, wv, 1.2)
    return nothing
end

function stepChatWidth(tab1)
    say("dragging the chat rail (setChatWidth 620)")
    L.Webviews.eval!(wv, "setChatWidth(620, false);")
    Webviews.set_timeout(function ()
        snapshot() do txt
            say("after chat resize: " * txt)
            checkAgreement("chat rail dragged", txt, [tab1])
            stepSplit(tab1)
        end
    end, wv, 0.8)
    return nothing
end

function stepSplit(tab1)
    say("splitting, then resizing again")
    L.Webviews.eval!(wv, "splitTerminal();")
    Webviews.set_timeout(function ()
        ids = lock(() -> collect(keys(L.OWNERSHIP_SESSIONS)), L.OWNERSHIP_SESSIONS_LOCK) |>
              xs -> String.(xs)
        if length(ids) < 2
            check("the split created a second session", false, length(ids))
            return finish()
        end
        child = setdiff(ids, [tab1])[1]
        snapshot() do txt
            say("after split: " * txt)
            checkAgreement("split (initial)", txt, [tab1, child])
            Base.resize!(wv, (980, 640))
            Webviews.set_timeout(function ()
                snapshot() do txt2
                    say("after split + window resize: " * txt2)
                    checkAgreement("split + window resize", txt2, [tab1, child])
                    finish()
                end
            end, wv, 1.2)
        end
    end, wv, 1.0)
    return nothing
end

function boot(attempt = 0)
    n = lock(() -> length(L.OWNERSHIP_SESSIONS), L.OWNERSHIP_SESSIONS_LOCK)
    if n == 0
        if attempt > 120
            check("a session exists", false, "timeout")
            return finish()
        end
        return Webviews.set_timeout(() -> boot(attempt + 1), wv, 0.25)
    end
    tab1 = lock(() -> first(keys(L.OWNERSHIP_SESSIONS)), L.OWNERSHIP_SESSIONS_LOCK) |> String
    say("tab ready: " * tab1)
    waitBound(tab1, 0)
    return nothing
end

"Wait until the page's tab is BOUND to the session (juliaId assigned)."
function waitBound(tab1, attempt)
    snapshot() do txt
        if !occursin("\"julia\":\"" * tab1 * "\"", txt) && attempt < 40
            return Webviews.set_timeout(() -> waitBound(tab1, attempt + 1), wv, 0.2)
        end
        say("initial: " * txt)
        checkAgreement("initial", txt, [tab1])
        stepWindow(tab1)
    end
    return nothing
end

Webviews.set_timeout(boot, wv, 2.0)
Webviews.set_timeout(function (); say("watchdog"); finish() end, wv, 120.0)
L.runEventLoopAndTeardown!(wv)
