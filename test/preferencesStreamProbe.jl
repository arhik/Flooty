# preferencesStreamProbe.jl — the Preferences monitor has its own stream.
#
# Run: julia --startup-file=no --project=. test/preferencesStreamProbe.jl  (opens a window)
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
path = joinpath(mktempdir(), "preferences.md")
ENV["FLOOTY_PREFERENCES_PATH"] = path
PREFERENCE_COMPLETE[] = _ ->
    "{\"preferences\":[{\"scope\":\"global\",\"text\":\"prefer short answers\"}]}"
wv = L.launchTerminalUI(chatOnly = true)
later(f, s = 0.25) = Webviews.set_timeout(f, wv, s)
function finish()
    try Webviews.close(wv) catch e; L.requestStopEventLoop!(wv) end
    println()
    if isempty(failures)
        println("PREFERENCES_STREAM_PROBE_OK")
    else
        println("FAILED CHECKS: ", join(failures, ", ")); exit(1)
    end
end
function report(then)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__pf__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        (function () {
            var info = chatTabs[CHAT_SESSION_ID] || CHAT_ONLY;
            var b = document.querySelector('#chatStreamTabs [data-stream="preferences"]');
            window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__pf__',
                text: JSON.stringify({
                    tab: !!b,
                    visible: b ? getComputedStyle(b).display !== 'none' : false,
                    log: (info.preferencesMonitorChat || []).map(function (m) {
                        return m.role + ':' + m.text; })
                }) })).catch(function(){});
        })();
    """)
    later(function ()
        then(lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__pf__", ""),
                  L.TERMINAL_BUFFER_LOCK))
    end, 0.15)
end
function waitReady(n)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__pf_ready__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__pf_ready__',
            text: String(typeof handleAgentEvent === 'function' && !!CHAT_SESSION_ID) }))
            .catch(function(){});
    """)
    later(function ()
        ok = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__pf_ready__", ""),
                  L.TERMINAL_BUFFER_LOCK) == "true"
        ok && return go()
        n > 80 && (check("page ready", false, ""); return finish())
        waitReady(n + 1)
    end, 0.2)
end
function go()
    report() do txt
        check("the Preferences tab is present", occursin("\"tab\":true", txt) &&
              occursin("\"visible\":true", txt), txt)
        root = ensureRootChatSession!()
        noteUserMessage!(root, "Always keep answers short")
        for _ in 1:50
            occursin("prefer short answers", isfile(path) ? read(path, String) : "") && break
            sleep(0.1)
        end
    end
    later(function ()
        report() do txt
            check("…and the monitor stream records the preference",
                  occursin("preference noted", txt) &&
                  occursin("prefer short answers", txt), txt)
            rm(path; force = true)
            finish()
        end
    end, 0.5)
end
later(() -> waitReady(0), 0.3)
Webviews.set_timeout(function (); println("watchdog"); finish() end, wv, 60.0)
L.runEventLoopAndTeardown!(wv)
