# copyPasteProbe.jl — paste lands in the single assist input surface.
#
# Run: julia --startup-file=no --project=. test/copyPasteProbe.jl  (opens a window)
import FlootyPTYLayer
import Webviews
using Flooty
const L = FlootyPTYLayer
failures = String[]
check(n, ok, d="") = (println(ok ? "PASS  " : "FAIL  ", n, isempty(d) ? "" : "  ["*string(d)*"]"); ok || push!(failures,n))
wv = L.launchTerminalUI(chatOnly = true)
later(f,s=0.25) = Webviews.set_timeout(f,wv,s)
function finish()
    try Webviews.close(wv) catch e; L.requestStopEventLoop!(wv) end
    println(); isempty(failures) ? println("COPY_PASTE_PROBE_OK") : (println("FAILED: ",join(failures,", ")); exit(1))
end
function waitReady(n)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE,"__cp_ready__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        window.flootyTerminalBufferReport(JSON.stringify({terminal_id:'__cp_ready__',
            text:String(typeof flootyPaste === 'function' && !!assistCm)})).catch(function(){});
    """)
    later(function()
        ok = lock(() -> get(L.TERMINAL_BUFFER_CACHE,"__cp_ready__",""),L.TERMINAL_BUFFER_LOCK)=="true"
        ok && return test()
        n>80 && (check("page ready",false,""); return finish())
        waitReady(n+1)
    end,0.2)
end
function test()
    L.Webviews.eval!(wv, """
        assistCm.setValue('hello ');
        document.body.focus();
        window.__cp = { ok: window.flootyPaste('world'),
                        value: assistCm.getValue() };
    """)
    later(function()
        lock(() -> delete!(L.TERMINAL_BUFFER_CACHE,"__cp__"), L.TERMINAL_BUFFER_LOCK)
        L.Webviews.eval!(wv, """
            window.flootyTerminalBufferReport(JSON.stringify({terminal_id:'__cp__',
                text:JSON.stringify(window.__cp || null)})).catch(function(){});
        """)
        later(function()
            txt = lock(() -> get(L.TERMINAL_BUFFER_CACHE,"__cp__",""),L.TERMINAL_BUFFER_LOCK)
            check("paste succeeds with focus outside a terminal", occursin("\"ok\":true",txt), txt)
            check("…and appends to the assist input", occursin("hello world",txt), txt)
            finish()
        end,0.2)
    end,0.2)
end
later(() -> waitReady(0), 0.3)
Webviews.set_timeout(function(); println("watchdog"); finish() end, wv, 60.0)
L.runEventLoopAndTeardown!(wv)
