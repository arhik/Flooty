# sshHistoryProbe.jl — SSH targets are remembered and suggested.
#
# Run: julia --startup-file=no --project=. test/sshHistoryProbe.jl  (opens a window)
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
    println(); isempty(failures) ? println("SSH_HISTORY_PROBE_OK") : (println("FAILED: ",join(failures,", ")); exit(1))
end
function waitReady(n)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE,"__sh_ready__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        window.flootyTerminalBufferReport(JSON.stringify({terminal_id:'__sh_ready__',
            text:String(typeof rememberSshTarget === 'function')})).catch(function(){});
    """)
    later(function()
        ok=lock(()->get(L.TERMINAL_BUFFER_CACHE,"__sh_ready__",""),L.TERMINAL_BUFFER_LOCK)=="true"
        ok && return go()
        n>80 && (check("page ready",false,""); return finish())
        waitReady(n+1)
    end,0.2)
end
function go()
    L.Webviews.eval!(wv, """
        window.localStorage.removeItem('flooty.sshTargets');
        rememberSshTarget('first@host');
        rememberSshTarget('second@host');
        rememberSshTarget('first@host');
        window.__sshHist = sshTargetHistory();
        flootyPrompt('SSH target (user@host)', 'user@host',
                     sshTargetHistory()[0] || '', sshTargetHistory());
    """)
    later(function()
        lock(() -> delete!(L.TERMINAL_BUFFER_CACHE,"__sh__"), L.TERMINAL_BUFFER_LOCK)
        L.Webviews.eval!(wv, """
            window.flootyTerminalBufferReport(JSON.stringify({terminal_id:'__sh__',
                text:JSON.stringify({
                    history: window.__sshHist,
                    value: document.getElementById('promptInput').value,
                    options: Array.from(document.querySelectorAll('#promptSuggestions option'))
                        .map(function(o){return o.value;}).slice(0,3)
                })})).catch(function(){});
        """)
        later(function()
            txt=lock(()->get(L.TERMINAL_BUFFER_CACHE,"__sh__",""),L.TERMINAL_BUFFER_LOCK)
            check("SSH history is deduped and newest-first",
                  occursin("\"first@host\",\"second@host\"", txt), txt)
            check("prompt prefills the most recent target",
                  occursin("\"value\":\"first@host\"", txt), txt)
            check("prompt offers remembered targets",
                  occursin("\"options\":[\"first@host\",\"second@host\"]", txt), txt)
            L.Webviews.eval!(wv, "document.getElementById('promptCancel').click();")
            finish()
        end,0.2)
    end,0.2)
end
later(() -> waitReady(0), 0.3)
Webviews.set_timeout(function(); println("watchdog"); finish() end, wv, 60.0)
L.runEventLoopAndTeardown!(wv)
