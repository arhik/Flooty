# splitSendProbe.jl — the TANDEM contract:
#   * opening a split must NOT steal the active ownership (the next prompt, the
#     snapshot and the chat stay with the tab the user is looking at);
#   * the agent can send to the SECOND terminal with target="split", while a plain
#     send keeps using the main session.
#
# Run: julia --startup-file=no --project=. test/splitSendProbe.jl  (opens a window)
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
const CHILD_SESS = Ref{Any}(nothing)

function finish()
    try Webviews.close(wv) catch e; L.requestStopEventLoop!(wv) end
    println()
    if isempty(failures)
        println("SPLIT_SEND_PROBE_OK")
    else
        println("FAILED CHECKS: ", join(failures, ", "))
        exit(1)
    end
    return nothing
end

tailOf(sess) = L._stripAnsi(L.tailText(sess.tail))

function run()
    PARENT[] = L.startReplSession(`zsh -i`; waitPrompt = false)
    PARENT_ID[] = L.adoptSessionTerminal!(PARENT[]; name = "tandem")
    println("parent=", PARENT_ID[])
    # ONE in-page script: wait for the adopted tab (adoption attaches async), focus
    # it, then split. Cross-thread timers here raced the attach and split returned
    # null on a still-null activeTerminalId.
    # The page may still be loading at +2 s; an eval dropped before its script runs
    # never reports. Wait for the split entry point, THEN install the setup script.
    waitReady(0)
    return nothing
end

function waitReady(tries)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__ready__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__ready__',
            text: String(typeof window.flootySplitTerminal === 'function' &&
                         typeof window.flootyChatState === 'function') })).catch(function(){});
    """)
    later(function ()
        txt = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__ready__", ""),
                   L.TERMINAL_BUFFER_LOCK)
        if txt == "true"
            return installSetup()
        end
        tries > 80 && (check("the page became ready", false, txt); return finish())
        waitReady(tries + 1)
    end, 0.2)
    return nothing
end

function installSetup()
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__setup__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        (function () {
            var want = "$(PARENT_ID[])", tries = 0;
            function report(s) {
                window.flootyTerminalBufferReport(JSON.stringify({
                    terminal_id: '__setup__', text: s })).catch(function(){});
            }
            function tick() {
                for (var k in terminals) {
                    if (terminals[k].juliaId === want) {
                        switchToTerminal(k);
                        var id = null;
                        try { id = window.flootySplitTerminal(); }
                        catch (e) { return report('ERR:' + (e && e.message || e)); }
                        if (!id) return report('null-split active=' + String(activeTerminalId));
                        return report('split:' + id + ' active=' + String(activeTerminalId));
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
    setup = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__setup__", ""), L.TERMINAL_BUFFER_LOCK)
    isempty(setup) && tries < 40 && return later(() -> stepSplit(tries + 1), 0.15)
    println("setup: ", setup)
    check("the split opened", startswith(setup, "split:"), setup)
    waitChild(0)
    return nothing
end

function waitChild(tries)
    child = L.splitSession()
    if child === nothing
        tries > 60 && (check("the split child's session is registered", false, ""); return finish())
        return later(() -> waitChild(tries + 1), 0.25)
    end
    CHILD_SESS[] = child
    check("the split child's session is registered", true, L.sessionIdFor(child))
    # The contract is that the CHILD never becomes active (the UI's own default tab
    # may hold focus if the boot's focus call lands later — that is a different,
    # harmless tab).
    check("…and it did NOT steal the active slot",
          L.ACTIVE_OWNERSHIP_ID[] != L.sessionIdFor(child),
          L.ACTIVE_OWNERSHIP_ID[])
    runSends()
    return nothing
end

function runSends()
    # 1) plain send → PARENT
    replies = String[
        "{\"action\":\"send\",\"code\":\"echo MAIN_PANE\"}",
        "{\"action\":\"send\",\"code\":\"echo SPLIT_PANE\",\"target\":\"split\"}",
        "{\"action\":\"done\",\"summary\":\"both panes\"}",
    ]
    i = Ref(0)
    res = runTerminalAgent!(PARENT[], "use both panes";
                            completeFn = _ -> (i[] += 1; replies[min(i[], 3)]),
                            maxTurns = 5)
    tr = join(res.transcript, "\n")
    check("the loop accepts target=split", occursin("send (split): echo SPLIT_PANE", tr),
          first(tr, 200))
    pt = tailOf(PARENT[])
    ct = tailOf(CHILD_SESS[])
    check("the plain send reached the MAIN pane", occursin("MAIN_PANE", pt), last(pt, 120))
    check("…and NOT the split pane", !occursin("MAIN_PANE", ct), "")
    check("the targeted send reached the SPLIT pane", occursin("SPLIT_PANE", ct), last(ct, 160))
    check("…and NOT the main pane", !occursin("SPLIT_PANE", pt), "")
    L.closeChildTerminalUi(wv)
    later(() -> waitClosed(0), 0.3)
    return nothing
end

function waitClosed(tries)
    if L.splitSession() === nothing || tries > 40
        check("closing the split clears the split session",
              L.splitSession() === nothing, repr(L.SPLIT_SESSION_ID[]))
        try L.closeSession!(PARENT[]) catch e; nothing end
        finish()
        return nothing
    end
    later(() -> waitClosed(tries + 1), 0.1)
    return nothing
end

later(run, 2.0)
Webviews.set_timeout(function (); println("watchdog"); finish() end, wv, 180.0)
L.runEventLoopAndTeardown!(wv)
