# childChatProbe.jl — a ChatSession can launch a CHILD chat session.
#
#   * the root chat opens a child ChatSession (its own tab, active);
#   * the child is linked in the session tree (parent = root);
#   * the assist box drives the CHILD (its own conversation), not the root;
#   * switching back to the Chat tab shows the root thread.
#
# Run: julia --startup-file=no --project=. test/childChatProbe.jl  (opens a window)
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

calls = Ref(0)
CHAT_COMPLETE[] = _ -> begin
    calls[] += 1
    calls[] == 1 ? "{\"action\":\"chat\",\"name\":\"Child\"}" : "child reply"
end

wv = L.launchTerminalUI(chatOnly = true)
later(f, s = 0.25) = Webviews.set_timeout(f, wv, s)
const CHILD = Ref{Any}(nothing)

function finish()
    try Webviews.close(wv) catch e; L.requestStopEventLoop!(wv) end
    println()
    if isempty(failures)
        println("CHILD_CHAT_PROBE_OK")
    else
        println("FAILED CHECKS: ", join(failures, ", "))
        exit(1)
    end
    return nothing
end

function pageReport(then)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__cc__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        (function () {
            var ws = document.querySelector('.workspace');
            var root = chatTabs[CHAT_SESSION_ID] || CHAT_ONLY;
            var act = chatTabs[activeChatId] || {};
            window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__cc__',
                text: JSON.stringify({
                    sessions: Object.keys(chatTabs),
                    active: activeChatId,
                    focus: ws.classList.contains('chat-focus'),
                    chatOnly: ws.classList.contains('chat-only'),
                    names: Object.keys(chatTabs).map(function (k) { return chatTabs[k].name || k; }),
                    root: (root.chat || []).map(function (m) { return m.role + ':' + m.text; }),
                    child: (act.chat || []).map(function (m) { return m.role + ':' + m.text; }),
                    rail: Array.from(document.querySelectorAll('#terminal-tabs .root-icon, #childTabs .child-tab'))
                        .map(function (t) { return { text: t.textContent.trim(),
                            cls: t.className }; })
                }) })).catch(function () {});
        })();
    """)
    tries = Ref(0)
    poll = function ()
        txt = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__cc__", ""), L.TERMINAL_BUFFER_LOCK)
        if isempty(txt) && tries[] < 40
            tries[] += 1
            return later(poll, 0.1)
        end
        then(txt)
    end
    later(poll, 0.1)
    return nothing
end

function waitReady(tries)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__cc_ready__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__cc_ready__',
            text: String(typeof submitAssist === 'function' &&
                         typeof window.flootyAddChatTab === 'function') })).catch(function(){});
    """)
    later(function ()
        txt = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__cc_ready__", ""),
                   L.TERMINAL_BUFFER_LOCK)
        txt == "true" && return submitRoot()
        tries > 80 && (check("the page became ready", false, txt); return finish())
        waitReady(tries + 1)
    end, 0.2)
    return nothing
end

function submitRoot()
    L.Webviews.eval!(wv, "assistCm.setValue(\"open a child chat\"); submitAssist();")
    later(() -> waitChild(0), 0.5)
    return nothing
end

function waitChild(tries)
    root = Flooty.rootChatSession()
    child = nothing
    for id in root.children
        s = Flooty.sessionForId(id)
        s isa Flooty.ChatSession && (child = s; break)
    end
    if child === nothing
        tries > 80 && (check("the child ChatSession was created", false, ""); return finish())
        return later(() -> waitChild(tries + 1), 0.15)
    end
    CHILD[] = child
    check("the child ChatSession was created", true, child.id)
    check("…linked to the root", child.parent == root.id, string(child.parent))
    waitTab(child, 0)
    return nothing
end

function waitTab(child, tries)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__cc_tab__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__cc_tab__',
            text: String(!!(chatTabs["$(child.id)"])) })).catch(function(){});
    """)
    later(function ()
        ok = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__cc_tab__", ""),
                  L.TERMINAL_BUFFER_LOCK) == "true"
        if !ok
            tries > 80 && (check("the child chat tab appeared", false, ""); return finish())
            return later(() -> waitTab(child, tries + 1), 0.15)
        end
        check("the child chat tab appeared", true, "")
        pageReport(txt -> verifyTab(child, txt))
        return nothing
    end, 0.1)
    return nothing
end

function verifyTab(child, txt)
    check("two chat tabs exist", occursin("\"sessions\"", txt) &&
          occursin(child.id, txt) && occursin(Flooty.rootChatSession().id, txt),
          first(txt, 240))
    check("the child tab is active and focus is on the chat",
          occursin("\"active\":\"" * child.id * "\"", txt) &&
          occursin("\"focus\":true", txt), first(txt, 240))
    check("the terminal pane is not the chat view",
          occursin("\"chatOnly\":false", txt), "")
    check("the root thread shows the child-chat confirmation",
          occursin("Opened a new chat", txt), first(txt, 240))
    check("the child chat tab is in the child strip",
          occursin("child-tab", txt) && occursin("Child", txt),
          first(txt, 360))
    submitChild()
    return nothing
end

function submitChild()
    L.Webviews.eval!(wv, "assistCm.setValue(\"hello child\"); submitAssist();")
    later(() -> waitReply(0), 0.5)
    return nothing
end

function waitReply(tries)
    child = CHILD[]
    tr = join(Flooty.conversationTranscript(
        Flooty.conversationFor(child.id)), "\n")
    if occursin("child reply", tr)
        check("the assist box drove the CHILD conversation",
              occursin("hello child", tr) && occursin("child reply", tr), first(tr, 200))
        root = Flooty.rootChatSession()
        rtr = join(Flooty.conversationTranscript(
            Flooty.conversationFor(root.id)), "\n")
        check("…and did not write into the root conversation",
              !occursin("hello child", rtr) && !occursin("child reply", rtr), "")
        L.Webviews.eval!(wv, "document.querySelector('#terminal-tabs .root-icon').click();")
        later(function ()
            pageReport() do txt
                check("switching to Chat shows the ROOT thread",
                      occursin("open a child chat", txt) &&
                      occursin("Opened a new chat", txt), first(txt, 240))
                check("…and its active chat is the root",
                      occursin("\"active\":\"" * root.id * "\"", txt), "")
                finish()
            end
        end, 0.4)
        return nothing
    end
    tries > 80 && (check("the child reply arrived", false, first(tr, 200)); return finish())
    later(() -> waitReply(tries + 1), 0.15)
    return nothing
end

later(() -> waitReady(0), 0.5)
Webviews.set_timeout(function (); println("watchdog"); finish() end, wv, 120.0)
L.runEventLoopAndTeardown!(wv)
