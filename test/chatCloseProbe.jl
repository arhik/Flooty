# chatCloseProbe.jl — chat sessions are closable, root stays.
#
# Chat tabs previously had no close control. A child chat (and any descendants)
# now closes from its strip/root icon; the backend unlinks the subtree and the
# page removes every returned id and activates a surviving session.
#
# Run: julia --startup-file=no --project=. test/chatCloseProbe.jl  (opens a window)
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
ROOT = Ref{Any}(nothing)
CHILD = Ref{Any}(nothing)
TERM = Ref("")

function finish()
    try Webviews.close(wv) catch e; L.requestStopEventLoop!(wv) end
    println()
    if isempty(failures)
        println("CHAT_CLOSE_PROBE_OK")
    else
        println("FAILED CHECKS: ", join(failures, ", "))
        exit(1)
    end
    return nothing
end

function waitReady(n)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__cc_ready__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__cc_ready__',
            text: String(typeof closeChatSession === 'function' && !!CHAT_SESSION_ID) }))
            .catch(function(){});
    """)
    later(function ()
        ok = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__cc_ready__", ""),
                  L.TERMINAL_BUFFER_LOCK) == "true"
        ok && return makeChild()
        n > 80 && (check("the page became ready", false, ""); return finish())
        waitReady(n + 1)
    end, 0.2)
    return nothing
end

function makeChild()
    ROOT[] = ensureRootChatSession!()
    CHILD[] = launchChildChat!(ROOT[].id; name = "closable")
    later(waitChild, 0.3)
    return nothing
end

function report(then)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__cc__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        (function () {
            var id = "$(CHILD[].id)";
            window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__cc__',
                text: JSON.stringify({
                    childTab: !!chatTabs[id],
                    closeButton: !!document.querySelector('#child-tab-chat-' + id + ' .close-btn'),
                    activeChat: activeChatId,
                    termTab: Object.values(terminals).some(function (i) {
                        return i.juliaId === "$(TERM[])"; }),
                    rootTab: !!chatTabs[CHAT_SESSION_ID]
                }) })).catch(function(){});
        })();
    """)
    later(function ()
        txt = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__cc__", ""), L.TERMINAL_BUFFER_LOCK)
        then(txt)
    end, 0.15)
    return nothing
end

function waitChild(n = 0)
    report() do txt
        if !occursin("\"childTab\":true", txt) && n < 40
            return later(() -> waitChild(n + 1))
        end
        check("the child chat tab exists", occursin("\"childTab\":true", txt), txt)
        check("…with a close control", occursin("\"closeButton\":true", txt), txt)
        # Give it a real terminal child: closing the chat must close the subtree.
        L.Webviews.eval!(wv, "createTerminal({ name: 'close-term', parentSession: \"$(CHILD[].id)\" });")
        waitTerminal(0)
    end
    return nothing
end

function waitTerminal(n)
    ids = lock(() -> collect(keys(L.OWNERSHIP_SESSIONS)), L.OWNERSHIP_SESSIONS_LOCK)
    termids = filter(id -> sessionForId(id) isa TerminalSession &&
                           sessionForId(id).parent == CHILD[].id, ids)
    if isempty(termids) && n < 60
        return later(() -> waitTerminal(n + 1), 0.2)
    end
    check("the child chat has a terminal child", !isempty(termids), termids)
    TERM[] = isempty(termids) ? "" : termids[end]
    # Primary root chat is permanent (backend refuses it).
    check("the primary root chat cannot be closed",
          isempty(closeChatSession!(ROOT[].id)) &&
          sessionForId(ROOT[].id) !== nothing)
    L.Webviews.eval!(wv, "closeChatSession(\"$(CHILD[].id)\");")
    later(verifyClosed, 0.7)
    return nothing
end

function verifyClosed(n = 0)
    # Teardown runs off the binding so it cannot deadlock the WebView response;
    # poll for the backend to catch up with the page removal.
    if (sessionForId(CHILD[].id) !== nothing ||
        (!isempty(TERM[]) && sessionForId(TERM[]) !== nothing)) && n < 40
        return later(() -> verifyClosed(n + 1), 0.1)
    end
    check("the child chat left the session tree",
          sessionForId(CHILD[].id) === nothing &&
          !(CHILD[].id in ROOT[].children), ROOT[].children)
    check("…and its terminal child was closed too",
          isempty(TERM[]) || sessionForId(TERM[]) === nothing, TERM[])
    report() do txt
        check("…and its tab left the page", !occursin("\"childTab\":true", txt), txt)
        check("…terminal tab too", !occursin("\"termTab\":true", txt), txt)
        check("…leaving a live session selected",
              occursin("\"activeChat\":\"$(ROOT[].id)\"", txt), txt)
        finish()
    end
    return nothing
end

later(() -> waitReady(0), 0.3)
Webviews.set_timeout(function (); println("watchdog"); finish() end, wv, 60.0)
L.runEventLoopAndTeardown!(wv)
