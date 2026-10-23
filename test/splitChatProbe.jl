# splitChatProbe.jl — a SPLIT terminal must not break the chat rail.
#
# Reported: "the chat is possibly breaking because of split terminal". The child
# pane has no tab and its own session; the parent's transcript must keep rendering
# before, during and after the split, and the child must never take the active tab.
#
# Run: julia --startup-file=no --project=. test/splitChatProbe.jl  (opens a window)
import FlootyPTYLayer
import Webviews
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
const CHILD = Ref("")

function finish()
    try Webviews.close(wv) catch e; L.requestStopEventLoop!(wv) end
    println()
    if isempty(failures)
        println("SPLIT_CHAT_PROBE_OK")
    else
        println("FAILED CHECKS: ", join(failures, ", "))
        exit(1)
    end
    return nothing
end

function report(then)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__split__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        (function () {
            var st = window.flootyChatState();
            var active = st.tabs[st.active] || { chat: [] };
            window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__split__',
                text: JSON.stringify({
                    active: st.active,
                    key: (function () {
                        for (var k in st.tabs) if (st.tabs[k].juliaId === "$(TAB[])") return k;
                        return null;
                    })(),
                    tabs: Object.keys(st.tabs).length,
                    split: splitTerminalId || null,
                    switchErr: window.__switchErr || null,
                    hasTab: (function () {
                        for (var k in st.tabs) if (st.tabs[k].juliaId === "$(TAB[])") return true;
                        return false;
                    })(),
                    chat: (active.chat || []).map(function (m) { return m.role + ':' + m.text; })
                }) })).catch(function () {});
        })();
    """)
    tries = Ref(0)
    poll = function ()
        txt = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__split__", ""), L.TERMINAL_BUFFER_LOCK)
        if isempty(txt) && tries[] < 30
            tries[] += 1
            return later(poll, 0.15)
        end
        then(txt)
    end
    later(poll, 0.15)
    return nothing
end

tabKey(txt) = (m = match(Regex("\"key\":\"([^\"]*)\""), txt); m === nothing ? "" : m.captures[1])

function emit(role, text)
    L.Webviews.eval!(wv, "window.handleAgentEvent(\"$(TAB[])\", {kind:'$(role)', text:'$(text)'});")
    return nothing
end

function step1(tries = 0)
    report() do txt
        if occursin("\"hasTab\":true", txt)
            # tab exists; focus it and start
            # switchToTerminal takes the TAB's KEY, not the session id: resolve it.
            L.Webviews.eval!(wv, "(function () { try { for (var k in terminals) { if (terminals[k].juliaId === \"$(TAB[])\") { switchToTerminal(k); return; } } } catch (e) { window.__switchErr = String(e && e.message || e); return; } })();")
            emit("text", "BEFORE-SPLIT")
            later(step2, 0.5)
            return
        end
        tries > 80 && (check("the adopted tab appeared", false, txt); return finish())
        later(() -> step1(tries + 1), 0.25)
    end
    return nothing
end

function step2()
    report() do txt
        check("the transcript renders before the split", occursin("BEFORE-SPLIT", txt),
              first(txt, 200))
        L.Webviews.eval!(wv, "(function () { window.__child = splitTerminal(); })();")
        later(step3, 0.8)
    end
    return nothing
end

function step3()
    report() do txt
        check("the split opened a child", !occursin("\"split\":null", txt), txt)
        check("the child did NOT become the active tab",
              occursin("\"active\":\"", txt) &&
              occursin("\"active\":\"" * tabKey(txt) * "\"", txt), txt)
        emit("text", "AFTER-SPLIT")
        later(step4, 0.5)
    end
    return nothing
end

function step4()
    report() do txt
        check("the transcript still renders DURING the split",
              occursin("AFTER-SPLIT", txt) && occursin("BEFORE-SPLIT", txt),
              first(txt, 240))
        L.Webviews.eval!(wv, "closeChildTerminal();")
        later(step5, 0.5)
    end
    return nothing
end

function step5()
    report() do txt
        check("closing the child keeps the tab and its transcript",
              occursin("\"active\":\"" * tabKey(txt) * "\"", txt) &&
              occursin("BEFORE-SPLIT", txt), txt)
        emit("text", "AFTER-CLOSE")
        later(step6, 0.5)
    end
    return nothing
end

function step6()
    report() do txt
        check("the transcript renders after the child closes",
              occursin("AFTER-CLOSE", txt), first(txt, 200))
        L.closeSession!(SESS[])
        finish()
    end
    return nothing
end

function run()
    SESS[] = L.startReplSession(`zsh -i`; waitPrompt = false)
    TAB[] = L.adoptSessionTerminal!(SESS[]; name = "split-chat")
    println("tab=", TAB[])
    step1()
    return nothing
end

later(run, 2.0)
Webviews.set_timeout(function (); println("watchdog"); finish() end, wv, 180.0)
L.runEventLoopAndTeardown!(wv)
