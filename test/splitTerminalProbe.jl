# splitTerminalProbe.jl — a CHILD terminal beside the current pane.
#
# The pane area splits into two equal halves (the active tab + the child, each its
# own session), and the child can be closed again, restoring the single pane.
# Covers both entry points: the page (`splitTerminal()` / `closeChildTerminal()`)
# and Julia (`splitTerminalUi` / `closeChildTerminalUi`, what the agent action
# `splitTerminal` calls).
#
# Run: julia --startup-file=no --project=. test/splitTerminalProbe.jl   (opens a window)
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
wv = L.launchTerminalUI()   # auto tab: the probe needs a parent to split from
t0 = time()
say(m) = (println("[SPLIT] ", round(time() - t0; digits = 2), "s ", m); flush(stdout))

const report = Ref("")

function snapshot(then)
    before = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__split__", ""), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, raw"""
        (function () {
            var container = document.getElementById('terminal-container');
            var panels = [];
            for (var k in terminals) {
                var el = document.getElementById(k);
                var r = el ? el.getBoundingClientRect() : null;
                panels.push({
                    id: k,
                    visible: !!(el && el.offsetParent !== null),
                    width: r ? Math.round(r.width) : -1,
                    child: el ? el.classList.contains('split-child') : false,
                    active: el ? el.classList.contains('active') : false
                });
            }
            var out = {
                terminals: Object.keys(terminals).length,
                railTabs: document.querySelectorAll('.terminal-tab').length,
                panes: panels.filter(function (p) { return p.visible; }).length,
                active: activeTerminalId || null,
                split: container ? container.classList.contains('split') : null,
                containerWidth: container ? Math.round(container.getBoundingClientRect().width) : -1,
                panels: panels
            };
            window.flootyTerminalBufferReport(JSON.stringify({
                terminal_id: "__split__", text: JSON.stringify(out)
            })).catch(function () {});
        })();
    """)
    tries = Ref(0)
    poll = function ()
        txt = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__split__", ""), L.TERMINAL_BUFFER_LOCK)
        if txt != before || tries[] > 40
            report[] = txt
            return then()
        end
        tries[] += 1
        Webviews.set_timeout(poll, wv, 0.1)
    end
    Webviews.set_timeout(poll, wv, 0.1)
    return nothing
end

function finish()
    say("closing")
    R.disableJournalPersistence!()
    try
        Webviews.close(wv)
    catch e
        L.requestStopEventLoop!(wv)
    end
    return nothing
end

# ---- 1: page entry point ---------------------------------------------------
function stepSplitPage()
    say("splitting from the page: splitTerminal()")
    L.Webviews.eval!(wv, "splitTerminal();")
    Webviews.set_timeout(function ()
        snapshot() do
            text = report[]
            say("after split: " * text)
            check("the pane area is split", occursin("\"split\":true", text), first(text, 120))
            check("the child stays IN THE SAME TAB (no new rail tab)",
                  occursin("\"railTabs\":1", text) && occursin("\"terminals\":2", text),
                  first(text, 160))
            check("two panes are visible", occursin("\"panes\":2", text), text)
            widths = [parse(Int, m.captures[1]) for m in
                      eachmatch(r"\"width\":(\d+)", text)]
            visible = [w for w in widths if w > 0]
            check("both halves are VISIBLE", count(>=(1), visible) == 2, visible)
            check("…and share the width EQUALLY",
                  length(visible) == 2 && abs(visible[1] - visible[2]) <= 6,
                  visible)
            check("the child pane is marked", occursin("\"child\":true", text))
            stepSplitJulia()
        end
    end, wv, 1.5)
end

# ---- 2: Julia entry point (what the agent action calls) --------------------
function stepSplitJulia()
    say("closing the child from the page")
    L.Webviews.eval!(wv, "closeChildTerminal();")
    Webviews.set_timeout(function ()
        snapshot() do
            text = report[]
            say("after close: " * text)
            check("closing the child restores the single pane",
                  occursin("\"split\":false", text) && occursin("\"panes\":1", text) &&
                  occursin("\"terminals\":1", text), first(text, 160))
            check("the parent is full width again",
                  begin
                      m = match(r"\"containerWidth\":(\d+)", text)
                      w = match(r"\"width\":(\d+)", text)
                      m !== nothing && w !== nothing &&
                          parse(Int, w.captures[1]) >= parse(Int, m.captures[1]) - 6
                  end, text)
            say("splitting via Julia (the agent's splitTerminal action path)")
            FlootyPTYLayer.splitTerminalUi(wv)
            Webviews.set_timeout(function ()
                snapshot() do
                    text2 = report[]
                    say("after Julia split: " * text2)
                    check("splitTerminalUi splits the pane (same tab)",
                          occursin("\"split\":true", text2) &&
                          occursin("\"railTabs\":1", text2) &&
                          occursin("\"panes\":2", text2), first(text2, 160))
                    say("closing via Julia (the agent's closeSplit path)")
                    FlootyPTYLayer.closeChildTerminalUi(wv)
                    Webviews.set_timeout(function ()
                        snapshot() do
                            text3 = report[]
                            say("after Julia close: " * text3)
                            check("closeChildTerminalUi restores the single pane",
                                  occursin("\"split\":false", text3) &&
                                  occursin("\"panes\":1", text3), first(text3, 160))
                            finish()
                        end
                    end, wv, 1.5)
                end
            end, wv, 2.0)
        end
    end, wv, 1.5)
end

function boot()
    n = lock(() -> length(L.OWNERSHIP_SESSIONS), L.OWNERSHIP_SESSIONS_LOCK)
    if n == 0
        if time() - t0 > 30
            check("a session exists to split from", false, "timeout")
            return finish()
        end
        return Webviews.set_timeout(boot, wv, 0.25)
    end
    say("page ready with " * string(n) * " session(s)")
    Webviews.set_timeout(stepSplitPage, wv, 1.0)
end

Webviews.set_timeout(boot, wv, 2.0)
Webviews.set_timeout(function ()
    say("watchdog")
    finish()
end, wv, 120.0)
L.runEventLoopAndTeardown!(wv)

println()
if isempty(failures)
    println("SPLIT_TERMINAL_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
