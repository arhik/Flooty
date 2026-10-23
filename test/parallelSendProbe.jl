# parallelSendProbe.jl — the parallel action runs distinct panes concurrently.
#
#   * 2 sends to main + split finish in ~max(t), not sum(t);
#   * one ACTION RESULT carries both, in input order;
#   * the same pane twice is refused (one input stream);
#   * interactive commands are refused in a batch.
#
# Run: julia --startup-file=no --project=. test/parallelSendProbe.jl  (opens a window)
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

wv = L.launchTerminalUI(chatOnly = true)
later(f, s = 0.25) = Webviews.set_timeout(f, wv, s)
const PARENT = Ref{Any}(nothing)
const PARENT_ID = Ref("")
const CHILD = Ref{Any}(nothing)

function finish()
    try Webviews.close(wv) catch e; L.requestStopEventLoop!(wv) end
    println()
    if isempty(failures)
        println("PARALLEL_SEND_PROBE_OK")
    else
        println("FAILED CHECKS: ", join(failures, ", "))
        exit(1)
    end
    return nothing
end

tailOf(sess) = L._stripAnsi(L.tailText(sess.tail))

function run()
    PARENT[] = L.startReplSession(`zsh -i`; waitPrompt = false)
    PARENT_ID[] = L.adoptSessionTerminal!(PARENT[]; name = "parallel")
    waitReady(0)
    return nothing
end

function waitReady(tries)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__p_ready__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__p_ready__',
            text: String(typeof window.flootySplitTerminal === 'function') })).catch(function(){});
    """)
    later(function ()
        txt = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__p_ready__", ""),
                   L.TERMINAL_BUFFER_LOCK)
        txt == "true" && return setup()
        tries > 80 && (check("the page became ready", false, txt); return finish())
        waitReady(tries + 1)
    end, 0.2)
    return nothing
end

function setup()
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__p_setup__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        (function () {
            var want = "$(PARENT_ID[])", tries = 0;
            function report(s) {
                window.flootyTerminalBufferReport(JSON.stringify({
                    terminal_id: '__p_setup__', text: s })).catch(function(){});
            }
            function tick() {
                for (var k in terminals) {
                    if (terminals[k].juliaId === want) {
                        switchToTerminal(k);
                        try { report('split:' + String(window.flootySplitTerminal())); }
                        catch (e) { report('ERR:' + (e && e.message || e)); }
                        return;
                    }
                }
                if (tries++ > 100) return report('no-tab');
                setTimeout(tick, 100);
            }
            tick();
        })();
    """)
    later(() -> stepSplit(0), 0.3)
    return nothing
end

function stepSplit(tries)
    txt = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__p_setup__", ""), L.TERMINAL_BUFFER_LOCK)
    isempty(txt) && tries < 40 && return later(() -> stepSplit(tries + 1), 0.15)
    check("the split opened", startswith(txt, "split:"), txt)
    waitChild(0)
    return nothing
end

function waitChild(tries)
    child = L.splitSession()
    if child === nothing
        tries > 60 && (check("the split session is registered", false, ""); return finish())
        return later(() -> waitChild(tries + 1), 0.25)
    end
    CHILD[] = child
    check("the split session is registered", true, L.sessionIdFor(child))
    runParallel()
    return nothing
end

function runParallel()
    replies = String[
        "{\"action\":\"parallel\",\"sends\":[" *
        "{\"target\":\"main\",\"code\":\"sleep 1; echo PAR_MAIN\"}," *
        "{\"target\":\"split\",\"code\":\"sleep 1; echo PAR_SPLIT\"}]}",
        "{\"action\":\"done\",\"summary\":\"parallel done\"}",
    ]
    i = Ref(0)
    seen = Ref("")
    t0 = time()
    res = runTerminalAgent!(PARENT[], "run both panes in parallel";
        completeFn = msgs -> begin
            i[] += 1
            i[] == 2 && (seen[] = join([string(m.content) for m in msgs
                                        if m.role == "user"], "\n"))
            replies[min(i[], length(replies))]
        end, maxTurns = 4)
    elapsed = time() - t0
    tr = join(res.transcript, "\n")
    pt = tailOf(PARENT[])
    ct = tailOf(CHILD[])
    check("the batch ran", occursin("parallel: main sleep", tr), first(tr, 200))
    check("…and both results are in ONE ACTION RESULT",
          occursin("parallel 2/2 ok", seen[]) &&
          occursin("PAR_MAIN", seen[]) && occursin("PAR_SPLIT", seen[]),
          first(seen[], 300))
    check("the main command reached main", occursin("PAR_MAIN", pt), last(pt, 120))
    check("…and NOT split", !occursin("PAR_MAIN", ct), "")
    check("the split command reached split", occursin("PAR_SPLIT", ct), last(ct, 120))
    check("…and NOT main", !occursin("PAR_SPLIT", pt), "")
    m = match(r"ok in ([0-9.]+)s", seen[])
    batch = m === nothing ? Inf : parse(Float64, m.captures[1])
    check("the two 1s sleeps overlapped (batch < 1.8s)", batch < 1.8,
          "batch=$(batch)s run=$(round(elapsed; digits = 2))s")
    stepRefuse()
    return nothing
end

function stepRefuse()
    replies = String[
        "{\"action\":\"parallel\",\"sends\":[" *
        "{\"target\":\"main\",\"code\":\"echo SAME_A\"}," *
        "{\"target\":\"main\",\"code\":\"echo SAME_B\"}]}",
        "{\"action\":\"parallel\",\"sends\":[" *
        "{\"target\":\"main\",\"code\":\"vim\"}," *
        "{\"target\":\"split\",\"code\":\"echo NOPE\"}]}",
        "{\"action\":\"done\",\"summary\":\"refusals done\"}",
    ]
    i = Ref(0)
    seen = Ref("")
    res = runTerminalAgent!(PARENT[], "try invalid batches";
        completeFn = msgs -> begin
            i[] += 1
            i[] == 3 && (seen[] = join([string(m.content) for m in msgs
                                        if m.role == "user"], "\n"))
            replies[min(i[], length(replies))]
        end, maxTurns = 5)
    tr = join(res.transcript, "\n")
    check("the same pane twice is refused",
          occursin("two sends to the SAME pane", seen[]), first(seen[], 300))
    check("an interactive command is refused",
          occursin("interactive command in a batch", seen[]), first(seen[], 300))
    check("…and neither refused command ran",
          !occursin("SAME_A", tailOf(PARENT[])) && !occursin("NOPE", tailOf(CHILD[])),
          "")
    check("the refused batches did not stop the run", res.ok, res.summary)
    L.Webviews.eval!(wv, "closeChildTerminal();")
    later(function ()
        try L.closeSession!(PARENT[]) catch e; nothing end
        finish()
    end, 0.8)
    return nothing
end

later(run, 2.0)
Webviews.set_timeout(function (); println("watchdog"); finish() end, wv, 180.0)
L.runEventLoopAndTeardown!(wv)
