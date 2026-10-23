# agentProgressProbe.jl — a slow model call must SHOW that it is running.
#
# Reported: after the reasoning stopped the app looked dead — no feedback while the
# completion was in flight. A live phase line (#chatProgress) shows
# "waiting for the model… Ns" and is cleared when the call returns. It lives at
# the BOTTOM OF THE CHAT COLUMN, directly above the input block.
#
# The PAGE records the line every 300 ms (in-page setInterval) and the probe reads
# that recording once at the end: cross-thread sampling is what made earlier
# versions flaky.
#
# Run: julia --startup-file=no --project=. test/agentProgressProbe.jl  (opens a window)
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

wv = L.launchTerminalUI()
later(f, s = 0.25) = Webviews.set_timeout(f, wv, s)
const SESS = Ref{Any}(nothing)
const TAB = Ref("")
const RUN = Ref{Any}(nothing)
const DONE = Ref(false)

function finish()
    try Webviews.close(wv) catch e; L.requestStopEventLoop!(wv) end
    println()
    if isempty(failures)
        println("AGENT_PROGRESS_PROBE_OK")
    else
        println("FAILED CHECKS: ", join(failures, ", "))
        exit(1)
    end
    return nothing
end

function readReport(then)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__progress__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        (function () {
            var el = document.getElementById('chatProgress');
            window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__progress__',
                text: JSON.stringify({ now: el ? el.textContent : null,
                                       seen: window.__progSeen || [],
                                       events: window.__progLog || [],
                                       targets: targetsForSession("$(TAB[])").length,
                                       activeIsMine: (terminals[activeTerminalId] || {}).juliaId === "$(TAB[])",
                                       placement: el ? (!!el.closest('#thinkingPanel') &&
                                           el.parentElement &&
                                           el.parentElement.id === 'chatFooter' &&
                                           document.getElementById('assistBar') &&
                                           document.getElementById('assistBar').parentElement ===
                                               el.parentElement) : false,
                                       oldStatusGone: !document.getElementById('status-progress'),
                                       direct: (function () {
                                           var act = (terminals[activeTerminalId] || {}).juliaId || "";
                                           setAgentProgress(act, "DIRECT-TEST");
                                           var e2 = document.getElementById('chatProgress');
                                           var log = document.getElementById('agentChatLog');
                                           var input = document.getElementById('assistBar');
                                           var pr = e2 ? e2.getBoundingClientRect() : null;
                                           var lr = log ? log.getBoundingClientRect() : null;
                                           var ir = input ? input.getBoundingClientRect() : null;
                                           var shown = e2 ? e2.textContent : null;
                                           var noOverlap = !!(pr && lr && ir && pr.height > 0 &&
                                               pr.top >= lr.bottom - 1 &&
                                               pr.bottom <= ir.top + 1);
                                           setAgentProgress(act, "");
                                           return { text: shown, noOverlap: noOverlap };
                                       })() }) })).catch(function () {});
        })();
    """)
    tries = Ref(0)
    poll = function ()
        txt = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__progress__", ""),
                   L.TERMINAL_BUFFER_LOCK)
        if isempty(txt) && tries[] < 40
            tries[] += 1
            return later(poll, 0.15)
        end
        then(txt)
    end
    later(poll, 0.15)
    return nothing
end

function waitTab(tries = 0)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__tab__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        (function () {
            var st = window.flootyChatState();
            var hit = false;
            for (var k in st.tabs) if (st.tabs[k].juliaId === "$(TAB[])") hit = true;
            window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__tab__',
                text: hit ? 'yes' : 'no' })).catch(function () {});
        })();
    """)
    tries > 80 && (check("the adopted tab appeared", false, ""); return finish())
    later() do
        txt = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__tab__", ""), L.TERMINAL_BUFFER_LOCK)
        if txt == "yes"
            L.Webviews.eval!(wv, "switchToTerminal(\"$(TAB[])\");")
            later(startRun, 0.4)
        else
            waitTab(tries + 1)
        end
    end
    return nothing
end

function startRun()
    sess = SESS[]
    if !L._tailAtIdlePrompt(L.tailText(sess.tail))
        return later(startRun, 0.25)
    end
    L.tagIn(sess.control; mode = :agent)
    L.Webviews.eval!(wv, """
        (function () {
            window.__progSeen = [];
            window.__progLog = [];
            var orig = window.handleAgentEvent;
            window.handleAgentEvent = function (sid, ev) {
                if (ev && ev.kind === 'progress') window.__progLog.push(ev.text || '');
                return orig(sid, ev);
            };
            if (!window.__progTimer) {
                window.__progTimer = setInterval(function () {
                    var el = document.getElementById('chatProgress');
                    window.__progSeen.push((el && el.textContent) ? el.textContent : '');
                }, 300);
            }
        })();
    """)
    slow = msgs -> begin
        sleep(6.0)
        "{\"action\":\"done\",\"summary\":\"slow but alive\"}"
    end
    RUN[] = @async runTerminalAgent!(sess, "take your time"; completeFn = slow,
                                     maxTurns = 2)
    poll_done = function ()
        if istaskdone(RUN[])
            DONE[] = true
            try
                res = fetch(RUN[])
                println("run ok=", res.ok, " summary=", res.summary)
            catch e
                println("run error: ", sprint(showerror, e))
            end
            later(finishRun, 0.6)
            return
        end
        later(poll_done, 0.25)
    end
    later(poll_done, 0.25)
    return nothing
end

function finishRun()
    readReport() do txt
        println("report: ", txt)
        check("progress events reach the page", occursin("waiting for the model", txt), txt)
        check("…and they tick with the elapsed seconds",
              occursin(r"waiting for the model… [0-9]+s", txt), txt)
        check("…and clear when the call returns (status text empty)",
              occursin("\"now\":\"\"", txt), txt)
        # The renderer is per ACTIVE tab (page state, by design): the probe window
        # has its own default tab focused, so prove the element renders for the
        # active tab directly.
        check("the line renders for the active tab", occursin("DIRECT-TEST", txt), txt)
        check("…inside the chat column, immediately above the input",
              occursin("\"placement\":true", txt), txt)
        check("…in a footer container that does not overlap the transcript",
              occursin("\"noOverlap\":true", txt), txt)
        check("…and is gone from the status bar",
              occursin("\"oldStatusGone\":true", txt), txt)
        L.closeSession!(SESS[])
        finish()
    end
    return nothing
end

function run()
    sess = L.startReplSession(`zsh -i`; waitPrompt = false)
    SESS[] = sess
    TAB[] = L.adoptSessionTerminal!(sess; name = "slow")
    println("tab=", TAB[])
    waitTab()
    return nothing
end

later(run, 2.0)
Webviews.set_timeout(function (); println("watchdog"); finish() end, wv, 240.0)
L.runEventLoopAndTeardown!(wv)
