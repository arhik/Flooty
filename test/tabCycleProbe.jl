# tabCycleProbe.jl — Ctrl+Tab / Ctrl+Shift+Tab cycle SESSIONS, in order.
#
#   * Ctrl+Tab goes forward through the session tree (roots then children);
#   * Ctrl+Shift+Tab goes backward;
#   * the Monitor tab is non-empty on attach.
#
# Run: julia --startup-file=no --project=. test/tabCycleProbe.jl  (opens a window)
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
const PARENT = Ref("")
const CHILD = Ref("")

function finish()
    try Webviews.close(wv) catch e; L.requestStopEventLoop!(wv) end
    println()
    if isempty(failures)
        println("TAB_CYCLE_PROBE_OK")
    else
        println("FAILED CHECKS: ", join(failures, ", "))
        exit(1)
    end
    return nothing
end

function report(then)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__tc__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        (function () {
            var info = terminals[activeTerminalId] || {};
            window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__tc__',
                text: JSON.stringify({
                    active: activeTerminalId,
                    name: info.name || '',
                    activeChat: activeChatId,
                    activeBrowser: activeBrowserId,
                    monitor: (info.monitorChat || []).map(function (m) {
                        return m.role + ':' + m.text; }),
                    terminalMonitor: (info.terminalMonitorChat || []).map(function (m) {
                        return m.role + ':' + m.text; }),
                    termTabVisible: (function () {
                        var b = document.querySelector('#chatStreamTabs [data-stream="terminal"]');
                        return !!(b && !b.hidden);
                    })(),
                    log: document.getElementById('agentChatLog').textContent
                }) })).catch(function () {});
        })();
    """)
    tries = Ref(0)
    poll = function ()
        txt = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__tc__", ""), L.TERMINAL_BUFFER_LOCK)
        if isempty(txt) && tries[] < 40
            tries[] += 1
            return later(poll, 0.1)
        end
        then(txt)
    end
    later(poll, 0.1)
    return nothing
end

keyTab(shift) = L.Webviews.eval!(wv, """
    document.dispatchEvent(new KeyboardEvent('keydown',
        { key: 'Tab', code: 'Tab', ctrlKey: true, shiftKey: $(shift ? "true" : "false"),
          bubbles: true }));
""")

function waitReady(tries)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__tc_ready__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__tc_ready__',
            text: String(typeof createTerminal === 'function') })).catch(function(){});
    """)
    later(function ()
        ok = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__tc_ready__", ""),
                  L.TERMINAL_BUFFER_LOCK) == "true"
        ok && return createParent()
        tries > 80 && (check("the page became ready", false, ""); return finish())
        waitReady(tries + 1)
    end, 0.2)
    return nothing
end

function createParent()
    L.Webviews.eval!(wv, "createTerminal({ name: 'parent' });")
    waitParent(0)
    return nothing
end

function waitParent(tries)
    ids = lock(() -> collect(keys(L.OWNERSHIP_SESSIONS)), L.OWNERSHIP_SESSIONS_LOCK)
    if isempty(ids)
        tries > 80 && (check("parent terminal appeared", false, ""); return finish())
        return later(() -> waitParent(tries + 1), 0.2)
    end
    PARENT[] = ids[end]
    later(createChild, 0.5)
    return nothing
end

function createChild()
    L.Webviews.eval!(wv, """
        createTerminal({ name: 'child', parentSession: "$(PARENT[])" });
    """)
    waitChild(0)
    return nothing
end

function waitChild(tries)
    ids = lock(() -> collect(keys(L.OWNERSHIP_SESSIONS)), L.OWNERSHIP_SESSIONS_LOCK)
    newids = filter(id -> id != PARENT[], ids)
    if isempty(newids)
        tries > 80 && (check("child terminal appeared", false, ids); return finish())
        return later(() -> waitChild(tries + 1), 0.2)
    end
    CHILD[] = newids[end]
    later(stepForward, 0.8)
    return nothing
end

function stepForward()
    report() do txt
        check("the child is active", occursin("\"name\":\"child\"", txt), txt)
        keyTab(false)                      # forward -> next session (root chat)
        later(stepBack, 0.3)
    end
    return nothing
end

function stepBack()
    report() do txt
        check("Ctrl+Tab moved to another session",
              occursin("\"activeChat\":\"", txt) ||
              !occursin("\"name\":\"child\"", txt), txt)
        keyTab(true)                       # reverse -> child again
        later(stepReturn, 0.3)
    end
    return nothing
end

function stepReturn()
    report() do txt
        check("Ctrl+Shift+Tab moved back to the child",
              occursin("\"name\":\"child\"", txt) &&
              occursin("\"activeChat\":null", txt), txt)
        later(checkMonitor, 3.0)           # first monitor tick + tab bind
    end
    return nothing
end

function checkMonitor()
    report() do txt
        check("the Terminal monitor tab announces attachment",
              occursin("monitor attached", txt), txt)
        check("…and the Terminal stream tab is visible",
              occursin("\"termTabVisible\":true", txt), txt)
        L.Webviews.eval!(wv, "selectChatStream('terminal');")
        later(function ()
            report() do txt2
                check("…selecting Terminal shows its monitor, not the chat one",
                      occursin("monitor attached", txt2), first(txt2, 300))
                finish()
            end
        end, 0.3)
    end
    return nothing
end

later(() -> waitReady(0), 0.5)
Webviews.set_timeout(function (); println("watchdog"); finish() end, wv, 120.0)
L.runEventLoopAndTeardown!(wv)
