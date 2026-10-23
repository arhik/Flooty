# treeMapProbe.jl — no permanent top child tabs; tree map is an overlay.
#
# Run: julia --startup-file=no --project=. test/treeMapProbe.jl  (opens a window)
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
function finish()
    try Webviews.close(wv) catch e; L.requestStopEventLoop!(wv) end
    println()
    if isempty(failures)
        println("TREE_MAP_PROBE_OK")
    else
        println("FAILED CHECKS: ", join(failures, ", ")); exit(1)
    end
end
function report(then)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__tm__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        (function () {
            var e = document.getElementById('childTabs');
            window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__tm__',
                text: JSON.stringify({ display: e ? getComputedStyle(e).display : null,
                    open: !!(e && e.classList.contains('tree-map-open')),
                    rows: e ? e.querySelectorAll('.child-strip').length : 0 }) }))
                .catch(function(){});
        })();
    """)
    later(function ()
        then(lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__tm__", ""),
                  L.TERMINAL_BUFFER_LOCK))
    end, 0.15)
end
function waitReady(n)
    L.Webviews.eval!(wv, "createTerminal({ name: 'map-root' });")
    later(function ()
        ids = lock(() -> collect(keys(L.OWNERSHIP_SESSIONS)), L.OWNERSHIP_SESSIONS_LOCK)
        isempty(ids) && n < 60 && return later(() -> waitReady(n + 1), 0.2)
        check("a session exists", !isempty(ids))
        report() do txt
            check("top child tabs are hidden by default",
                  occursin("\"display\":\"none\"", txt), txt)
            L.Webviews.eval!(wv, """
                document.dispatchEvent(new KeyboardEvent('keydown',
                    { key: 'O', code: 'KeyO', ctrlKey: true, shiftKey: true, bubbles: true }));
            """)
            later(function ()
                report() do tm
                    check("Ctrl+Shift+O opens the tree map", occursin("\"display\":\"flex\"", tm), tm)
                    check("…with session rows", occursin("\"rows\":0", tm) == false, tm)
                    L.Webviews.eval!(wv, "toggleTreeMap(false);")
                    later(function ()
                        report() do closed
                            check("…and closes without a top bar",
                                  occursin("\"display\":\"none\"", closed), closed)
                            finish()
                        end
                    end, 0.2)
                end
            end, 0.25)
        end
    end, 0.2)
end
later(() -> waitReady(0), 0.4)
Webviews.set_timeout(function (); println("watchdog"); finish() end, wv, 60.0)
L.runEventLoopAndTeardown!(wv)
