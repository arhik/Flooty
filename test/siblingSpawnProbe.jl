# siblingSpawnProbe.jl — Ctrl+Shift+T creates a SIBLING, root stays root.
#
# Reported: Ctrl+Shift+T behaved like "spawn child". Now the active node's
# PARENT is the target: a root node gets another ROOT session, a child gets a
# sibling under the same parent.
#
# Run: julia --startup-file=no --project=. test/siblingSpawnProbe.jl  (opens a window)
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
ROOT0 = Ref{Any}(nothing)
ROOT1 = Ref{Any}(nothing)
CHILD1 = Ref{Any}(nothing)

function finish()
    try Webviews.close(wv) catch e; L.requestStopEventLoop!(wv) end
    println()
    if isempty(failures)
        println("SIBLING_SPAWN_PROBE_OK")
    else
        println("FAILED CHECKS: ", join(failures, ", ")); exit(1)
    end
end
function keyT()
    L.Webviews.eval!(wv, """
        document.dispatchEvent(new KeyboardEvent('keydown',
            { key: 'T', code: 'KeyT', ctrlKey: true, shiftKey: true, bubbles: true }));
    """)
end
function choose(kind)
    L.Webviews.eval!(wv,
        "document.querySelector('#sessionChooser [data-session-kind=\"" * kind * "\"]').click();")
end
function report(then)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__sib__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        (function () {
            var el = document.getElementById('sessionChooser');
            window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__sib__',
                text: JSON.stringify({ hidden: el ? !!el.hidden : null,
                    title: (document.getElementById('sessionChooserTitle')||{}).textContent || '',
                    chatTabs: Object.keys(chatTabs) }) })).catch(function(){});
        })();
    """)
    later(function ()
        then(lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__sib__", ""),
                  L.TERMINAL_BUFFER_LOCK))
    end, 0.15)
end
function waitReady(n)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__sib_ready__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__sib_ready__',
            text: String(typeof openSessionChooser === 'function' && !!CHAT_SESSION_ID) }))
            .catch(function(){});
    """)
    later(function ()
        ok = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__sib_ready__", ""),
                  L.TERMINAL_BUFFER_LOCK) == "true"
        ok && return rootStep()
        n > 80 && (check("page ready", false, ""); return finish())
        waitReady(n + 1)
    end, 0.2)
end
function rootStep()
    ROOT0[] = ensureRootChatSession!()
    keyT()
    report() do txt
        check("Ctrl+Shift+T opens the sibling radial",
              occursin("\"title\":\"Sibling session\"", txt), txt)
        choose("chat")
        waitRoot(0)
    end
end
function waitRoot(n)
    roots = [s for s in collect(values(Flooty.SESSIONS))
             if s isa ChatSession && s.parent === nothing &&
                s.id != ROOT0[].id]
    if isempty(roots) && n < 60
        return later(() -> waitRoot(n + 1), 0.15)
    end
    check("a ROOT node spawns another ROOT session", !isempty(roots), length(roots))
    ROOT1[] = isempty(roots) ? ROOT0[] : roots[end]
    CHILD1[] = launchChildChat!(ROOT1[].id; name = "sibling-a")
    later(childStep, 0.35)
end
function childStep()
    keyT()
    report() do txt
        check("child context reopens the sibling radial",
              occursin("\"title\":\"Sibling session\"", txt), txt)
        choose("chat")
        waitSibling(0)
    end
end
function waitSibling(n)
    kids = [s for s in collect(values(Flooty.SESSIONS))
            if s isa ChatSession && s.parent == ROOT1[].id]
    if length(kids) < 2 && n < 60
        return later(() -> waitSibling(n + 1), 0.15)
    end
    check("a CHILD node spawns a sibling, not a child of itself",
          length(kids) >= 2, [s.id for s in kids])
    check("…under the SAME parent", all(s -> s.parent == ROOT1[].id, kids),
          [s.parent for s in kids])
    check("…not under the first child",
          all(s -> s.parent != CHILD1[].id, kids), CHILD1[].id)
    finish()
end
later(() -> waitReady(0), 0.3)
Webviews.set_timeout(function (); println("watchdog"); finish() end, wv, 60.0)
L.runEventLoopAndTeardown!(wv)
