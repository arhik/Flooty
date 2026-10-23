# confidenceProbe.jl — monitor confidence is a radial gauge in the status bar.
# Run: julia --startup-file=no --project=. test/confidenceProbe.jl  (opens a window)
import FlootyPTYLayer
import Webviews
using Flooty
const L = FlootyPTYLayer
failures = String[]
function check(n, ok, d="")
    println(ok ? "PASS  " : "FAIL  ", n, isempty(d) ? "" : "  ["*string(d)*"]")
    ok || push!(failures,n)
end
wv = L.launchTerminalUI(chatOnly = true)
later(f,s=0.25)=Webviews.set_timeout(f,wv,s)
function finish()
    try Webviews.close(wv) catch e; L.requestStopEventLoop!(wv) end
    println(); isempty(failures) ? println("CONFIDENCE_PROBE_OK") : (println("FAILED: ",join(failures,", ")); exit(1))
end
function waitReady(n)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE,"__cf_ready__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        window.flootyTerminalBufferReport(JSON.stringify({terminal_id:'__cf_ready__',
            text:String(typeof handleAgentEvent === 'function' && !!CHAT_SESSION_ID)})).catch(function(){});
    """)
    later(function()
        ok=lock(()->get(L.TERMINAL_BUFFER_CACHE,"__cf_ready__",""),L.TERMINAL_BUFFER_LOCK)=="true"
        ok && return go()
        n>80 && (check("page ready",false,""); return finish())
        waitReady(n+1)
    end,0.2)
end
function report(then)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE,"__cf__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        (function () {
            var b=document.getElementById('monitorConfidence');
            var r=document.getElementById('confidenceRing');
            var l=document.getElementById('confidenceLabel');
            window.flootyTerminalBufferReport(JSON.stringify({terminal_id:'__cf__',
                text:JSON.stringify({
                    hidden: !!(b&&b.hidden),
                    label: l?l.textContent:'',
                    conf: r?(r.style.getPropertyValue('--conf')||''):'',
                    color: r?(r.style.getPropertyValue('--conf-color')||''):''
                })})).catch(function(){});
        })();
    """)
    later(function()
        then(lock(()->get(L.TERMINAL_BUFFER_CACHE,"__cf__",""),L.TERMINAL_BUFFER_LOCK))
    end,0.15)
end
function go()
    sid=ensureRootChatSession!().id
    L.pushAgentEventToWindow(wv, L.AgentMonitorConfidenceEvent(sid, 0.78, :terminal))
    later(function()
        report() do txt
            check("confidence gauge appears", occursin("\"hidden\":false",txt),txt)
            check("…with a radial value", occursin("\"conf\":\"78.0\"",txt),txt)
            check("…and a source label", occursin("Terminal 78%",txt),txt)
            L.pushAgentEventToWindow(wv, L.AgentMonitorConfidenceEvent(sid, 0.92, :prompt))
            later(function()
                report() do t2
                    check("prompt confidence updates the gauge", occursin("PS2 92%",t2),t2)
                    finish()
                end
            end,0.25)
        end
    end,0.25)
end
later(() -> waitReady(0), 0.3)
Webviews.set_timeout(function(); println("watchdog"); finish() end, wv, 60.0)
L.runEventLoopAndTeardown!(wv)
