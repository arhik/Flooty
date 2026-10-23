# multiPaneProbe.jl — three panes (main + 2 children) and target split:N.
#
#   * splitTerminal() twice opens two children (bounded pool);
#   * the registry indexes them split:1 / split:2 and `split` = newest;
#   * the main snapshot lists both children and their pending input;
#   * a 3-target parallel batch runs in all three panes concurrently;
#   * `split` + `split:2` resolve to the SAME pane and are refused;
#   * closeSplit closes the whole pool.
#
# Run: julia --startup-file=no --project=. test/multiPaneProbe.jl  (opens a window)
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

function finish()
    try Webviews.close(wv) catch e; L.requestStopEventLoop!(wv) end
    println()
    if isempty(failures)
        println("MULTI_PANE_PROBE_OK")
    else
        println("FAILED CHECKS: ", join(failures, ", "))
        exit(1)
    end
    return nothing
end

tailOf(sess) = L._stripAnsi(L.tailText(sess.tail))

function run()
    PARENT[] = L.startReplSession(`zsh -i`; waitPrompt = false)
    PARENT_ID[] = L.adoptSessionTerminal!(PARENT[]; name = "three")
    # child:N resolves from the session tree: the parent must be a registered
    # TerminalSession (the split map alone is only a presentation alias).
    root = Flooty.ensureRootChatSession!()
    L.runSessionTerminalHooks!(PARENT[]; parent_id = root.id)
    waitReady(0)
    return nothing
end

function waitReady(tries)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__m_ready__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__m_ready__',
            text: String(typeof window.flootySplitTerminal === 'function') })).catch(function(){});
    """)
    later(function ()
        txt = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__m_ready__", ""),
                   L.TERMINAL_BUFFER_LOCK)
        txt == "true" && return setup()
        tries > 80 && (check("the page became ready", false, txt); return finish())
        waitReady(tries + 1)
    end, 0.2)
    return nothing
end

function setup()
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__m_setup__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        (function () {
            var want = "$(PARENT_ID[])", tries = 0;
            function report(s) {
                window.flootyTerminalBufferReport(JSON.stringify({
                    terminal_id: '__m_setup__', text: s })).catch(function(){});
            }
            function tick() {
                for (var k in terminals) {
                    if (terminals[k].juliaId === want) {
                        switchToTerminal(k);
                        var a = window.flootySplitTerminal();
                        if (!a) return report('first-null');
                        // Distinct Date.now() ids: space the creates.
                        setTimeout(function () {
                            var b = window.flootySplitTerminal();
                            report('a=' + a + ' b=' + (b || 'null'));
                        }, 700);
                        return;
                    }
                }
                if (tries++ > 100) return report('no-tab');
                setTimeout(tick, 100);
            }
            tick();
        })();
    """)
    later(() -> stepSetup(0), 0.4)
    return nothing
end

function stepSetup(tries)
    txt = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__m_setup__", ""), L.TERMINAL_BUFFER_LOCK)
    isempty(txt) && tries < 40 && return later(() -> stepSetup(tries + 1), 0.15)
    check("two split children were created", startswith(txt, "a=") &&
          !occursin("b=null", txt), txt)
    waitChildren(0)
    return nothing
end

function waitChildren(tries)
    kids = L.splitChildren(PARENT[])
    if length(kids) < 2
        if tries > 80
            println("DEBUG parent=", L.sessionIdFor(PARENT[]))
            println("DEBUG split_parent=", Dict(L.SPLIT_PARENT))
            println("DEBUG split_children=", Dict(L.SPLIT_CHILDREN))
            println("DEBUG active=", L.ACTIVE_OWNERSHIP_ID[])
            println("DEBUG owners=", lock(() -> collect(keys(L.OWNERSHIP_SESSIONS)), L.OWNERSHIP_SESSIONS_LOCK))
            check("both split sessions registered", false, length(kids))
            return finish()
        end
        return later(() -> waitChildren(tries + 1), 0.25)
    end
    verify(kids)
    return nothing
end

function verify(kids)
    k1, k2 = kids[1], kids[2]
    id1, id2 = L.sessionIdFor(k1), L.sessionIdFor(k2)
    check("both split sessions registered", id1 != id2, (id1, id2))
    check("split:1 / split:2 resolve",
          L.splitChildAt(PARENT[], 1) === k1 && L.splitChildAt(PARENT[], 2) === k2, "")
    check("child:1 / child:2 resolve the same sessions",
          Flooty.childTerminalAt(PARENT[], 1) ===
              Flooty.sessionForId(L.sessionIdFor(k1)) &&
          Flooty.childTerminalAt(PARENT[], 2) ===
              Flooty.sessionForId(L.sessionIdFor(k2)), "")
    check("`split` is the newest", L.splitSession() === k2, "")
    check("both map to the main pane",
          L.splitParentSession(k1) === PARENT[] && L.splitParentSession(k2) === PARENT[], "")
    snap = agentSnapshot(PARENT[])
    rendered = string(snap)
    check("the main snapshot lists both panes",
          snap.split_count == 2 && occursin("[1]", rendered) && occursin("[2]", rendered),
          first(rendered, 300))
    # The single-split probe covers typed pending input; here the subject is
    # the pool and the 3-pane batch. Give the shells one beat, then batch.
    for k in kids
        st = get(Flooty.MONITOR_STATES, k, nothing)
        st === nothing || (st.completeFn = _ -> "{\"decision\":\"observe\"}")
    end
    later(() -> runBatch(kids), 1.0)
    return nothing
end

function runBatch(kids)
    replies = String[
        "{\"action\":\"parallel\",\"sends\":[" *
        "{\"target\":\"main\",\"code\":\"sleep 1; echo M3\"}," *
        "{\"target\":\"split:1\",\"code\":\"sleep 1; echo S1\"}," *
        "{\"target\":\"split:2\",\"code\":\"sleep 1; echo S2\"}]}",
        "{\"action\":\"done\",\"summary\":\"three panes done\"}",
    ]
    i = Ref(0)
    seen = Ref("")
    res = runTerminalAgent!(PARENT[], "run three panes";
        completeFn = msgs -> begin
            i[] += 1
            i[] == 2 && (seen[] = join([string(m.content) for m in msgs
                                        if m.role == "user"], "\n"))
            replies[min(i[], length(replies))]
        end, maxTurns = 4)
    m = match(r"parallel 3/3 ok in ([0-9.]+)s", seen[])
    dur = m === nothing ? Inf : parse(Float64, m.captures[1])
    check("the 3-pane batch ran", occursin("parallel 3/3 ok", seen[]), first(seen[], 240))
    check("…and overlapped (3 × 1s < 1.8s)", dur < 1.8, dur)
    check("main output landed in main", occursin("M3", tailOf(PARENT[])), "")
    check("split:1 output landed in split:1", occursin("S1", tailOf(kids[1])), "")
    check("split:2 output landed in split:2", occursin("S2", tailOf(kids[2])), "")
    check("…and did not cross panes",
          !occursin("S1", tailOf(kids[2])) && !occursin("S2", tailOf(kids[1])), "")
    dupReplies = String[
        "{\"action\":\"parallel\",\"sends\":[" *
        "{\"target\":\"split\",\"code\":\"echo DUP_A\"}," *
        "{\"target\":\"split:2\",\"code\":\"echo DUP_B\"}]}",
        "{\"action\":\"done\",\"summary\":\"dup done\"}",
    ]
    j = Ref(0)
    seen2 = Ref("")
    res2 = runTerminalAgent!(PARENT[], "duplicate split targets";
        completeFn = msgs -> begin
            j[] += 1
            j[] == 2 && (seen2[] = join([string(m.content) for m in msgs
                                         if m.role == "user"], "\n"))
            dupReplies[min(j[], length(dupReplies))]
        end, maxTurns = 4)
    check("split + split:2 is the SAME pane and is refused",
          occursin("SAME pane", seen2[]), first(seen2[], 240))
    check("…and the duplicate did not run",
          !occursin("DUP_A", tailOf(kids[2])) && !occursin("DUP_B", tailOf(kids[2])), "")
    L.closeChildTerminalUi(wv)
    later(function ()
        check("closeSplit closes the whole pool", L.splitCount(PARENT[]) == 0,
              L.splitCount(PARENT[]))
        check("…and splitSession is empty", L.splitSession() === nothing, "")
        try L.closeSession!(PARENT[]) catch e; nothing end
        finish()
    end, 1.0)
    return nothing
end

later(run, 2.0)
Webviews.set_timeout(function (); println("watchdog"); finish() end, wv, 180.0)
L.runEventLoopAndTeardown!(wv)
