# resizeSnapshotProbe.jl — after a RESIZE, does the model see what we see?
#
# The snapshot is the page's rendered viewport, sized by the live xterm grid, and
# the header reports the PTY winsize. A resize must move ALL of it together:
# header size == PTY == page grid, and the excerpt must be the NEW screen (a long
# line wraps differently at a narrow width).
#
# Run: julia --startup-file=no --project=. test/resizeSnapshotProbe.jl  (window)
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
say(m) = (println("[RSZ-SNAP] ", round(time() - t0; digits = 2), "s ", m); flush(stdout))
const sess = Ref{Any}(nothing)
const before = Ref{Any}(nothing)

function finish()
    R.disableJournalPersistence!()
    try Webviews.close(wv) catch e; L.requestStopEventLoop!(wv) end
    println()
    if isempty(failures)
        println("RESIZE_SNAPSHOT_PROBE_OK")
    else
        println("FAILED CHECKS: ", join(failures, ", "))
        exit(1)
    end
    return nothing
end

"Header fields + tail stats of one snapshot."
function snapInfo(snap)
    text = string(snap)
    m = match(r"terminal=(\d+)x(\d+)", text)
    tail = occursin("outputTail:", text) ? split(text, "outputTail:")[end] : ""
    lines = [l for l in split(strip(tail), '\n') if !isempty(strip(l))]
    return (rows = m === nothing ? -1 : parse(Int, m.captures[1]),
            cols = m === nothing ? -1 : parse(Int, m.captures[2]),
            lines = length(lines),
            chars = length(strip(tail)),
            longLines = count(l -> length(l) >= 30, lines),
            text = text)
end

"agentSnapshot asks the page and WAITS — never on the UI thread (it would block
# the very dispatch it is waiting for). Run it on a task, poll for the result."
function takeSnapshot(then)
    got = Ref{Any}(nothing)
    @async (got[] = R.agentSnapshot(sess[]))
    poll = function (n)
        got[] === nothing && n < 100 &&
            return Webviews.set_timeout(() -> poll(n + 1), wv, 0.05)
        got[] === nothing && return finish()
        return then(got[])
    end
    Webviews.set_timeout(() -> poll(0), wv, 0.05)
    return nothing
end

function step(then, tag, action)
    action()
    Webviews.set_timeout(function ()
        takeSnapshot() do snap
            info = snapInfo(snap)
            say(tag * ": header=" * string(info.rows) * "x" * string(info.cols) *
                " lines=" * string(info.lines) * " chars=" * string(info.chars) *
                " long=" * string(info.longLines))
            then(info, snap, sess[])
        end
    end, wv, 1.5)
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
    sess[] = lock(() -> last(collect(values(L.OWNERSHIP_SESSIONS))),
                  L.OWNERSHIP_SESSIONS_LOCK)
    say("bound session ready")
    # Content whose WRAPPING depends on the width: 90 W's, plus a column of lines.
    dollars = '$'
    cmd = "printf '%0.sW' " * dollars * "(seq 1 90); printf '\\n'; seq 1 60\n"
    L.userWrite(sess[], cmd)
    Webviews.set_timeout(function ()
        step("wide", () -> nothing) do info, snap, s
            before[] = info
            (rows, cols) = L.ptyWinsize(s.pty)
            check("wide: header matches the PTY winsize",
                  info.rows == rows && info.cols == cols, (info.rows, info.cols, rows, cols))
            step("narrow", () -> Base.resize!(wv, (640, 460))) do info2, snap2, s2
                (rows2, cols2) = L.ptyWinsize(s2.pty)
                check("narrow: header follows the RESIZED pty",
                      info2.rows == rows2 && info2.cols == cols2 && cols2 < info.cols,
                      (info2.rows, info2.cols, rows2, cols2, info.cols))
                # A narrow grid WRAPS: the 90-W run becomes many short visual
                # rows, so long lines disappear and the total line count grows.
                check("narrow: the long line WRAPS (no 30-char rows remain)",
                      info2.longLines == 0 && info2.lines > before[].lines,
                      (info2.longLines, info2.lines, before[].longLines, before[].lines))
                check("narrow: the long line still reaches the model",
                      occursin("WWWW", info2.text))
                step("wide again", () -> Base.resize!(wv, (1100, 750))) do info3, snap3, s3
                    (rows3, cols3) = L.ptyWinsize(s3.pty)
                    check("wide again: header follows the pty",
                          info3.rows == rows3 && info3.cols == cols3 && cols3 > info2.cols,
                          (info3.rows, info3.cols, rows3, cols3))
                    check("wide again: the wrapping unwinds (long rows return)",
                          info3.longLines >= 2 && info3.lines < info2.lines,
                          (info3.longLines, info3.lines, info2.longLines, info2.lines))
                    finish()
                end
            end
        end
    end, wv, 1.5)
    return nothing
end

Webviews.set_timeout(boot, wv, 2.0)
Webviews.set_timeout(function (); say("watchdog"); finish() end, wv, 120.0)
L.runEventLoopAndTeardown!(wv)
