# chatOnlyProbe.jl — CHAT FIRST, terminal on demand.
#
# The app boots with no terminal: the assist box talks to the agent MODEL, and
# Ctrl+Shift+T opens the first terminal, whose standing agent continues from the
# chat-only thread (page transcript migrated + session conversation seeded).
#
# SKIPS when the endpoint is unreachable.
#
# Run: julia --startup-file=no --project=. test/chatOnlyProbe.jl  (opens a window)
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

# Deterministic model stubs: the PRODUCTION driver records the turn in the chat
# session's conversation and the PRODUCTION monitor turns a pause trace into a note.
Flooty.CHAT_COMPLETE[] = _ -> "pong"
Flooty.CHAT_MONITOR_COMPLETE[] =
    _ -> "{\"decision\":\"insight\",\"body\":\"the user wants a parser\"}"

wv = L.launchTerminalUI(chatOnly = true)
later(f, s = 0.25) = Webviews.set_timeout(f, wv, s)

function finish()
    try Webviews.close(wv) catch e; L.requestStopEventLoop!(wv) end
    println()
    if isempty(failures)
        println("CHAT_ONLY_PROBE_OK")
    else
        println("FAILED CHECKS: ", join(failures, ", "))
        exit(1)
    end
    return nothing
end

function pageReport(then)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__co__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        (function () {
            window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__co__',
                text: JSON.stringify({
                    tabs: Object.keys(terminals).length,
                    chatSession: CHAT_SESSION_ID,
                    dom: (document.getElementById('agentChatLog') || {}).textContent || '',
                    chat: CHAT_ONLY.chat.map(function (m) { return m.role + ':' + m.text; }),
                    tabChat: ((terminals[activeTerminalId] || {}).chat || []).map(
                        function (m) { return m.role + ':' + m.text; }),
                    tabMonitor: ((terminals[activeTerminalId] || {}).monitorChat || []).map(
                        function (m) { return m.role + ':' + m.text; }),
                    names: Object.keys(terminals).map(function (k) { return terminals[k].name; })
                }) })).catch(function () {});
        })();
    """)
    tries = Ref(0)
    poll = function ()
        txt = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__co__", ""), L.TERMINAL_BUFFER_LOCK)
        if isempty(txt) && tries[] < 30
            tries[] += 1
            return later(poll, 0.15)
        end
        then(txt)
    end
    later(poll, 0.15)
    return nothing
end

function run()
    check("boot is chat-only (no terminal, no session)",
          isempty(lock(() -> collect(keys(L.OWNERSHIP_SESSIONS)), L.OWNERSHIP_SESSIONS_LOCK)),
          "")
    L.Webviews.eval!(wv, "assistCm.setValue(\"hi\"); submitAssist();")
    later(stepReply, 2.0)
    return nothing
end

function stepReply(tries = 0)
    pageReport() do txt
        # The reply is asynchronous; poll instead of trusting one timer.
        if !occursin("text:pong", txt) && tries < 60
            return later(() -> stepReply(tries + 1), 0.15)
        end
        check("the chat-only thread got the reply", occursin("text:pong", txt),
              first(txt, 200))
        dompos = findfirst("\"dom\":\"", txt)
        domtxt = dompos === nothing ? "" : txt[last(dompos)+1:end]
        check("…and the RAIL rendered it (no terminal needed)",
              occursin("pong", domtxt), first(domtxt, 160))
        check("…and no terminal was created for it", occursin("\"tabs\":0", txt), txt)
        check("…with no session either",
              isempty(lock(() -> collect(keys(L.OWNERSHIP_SESSIONS)),
                           L.OWNERSHIP_SESSIONS_LOCK)), "")
        sess = Flooty.rootChatSession()
        check("the app owns a ROOT chat session", sess !== nothing &&
              startswith(sess.id, "chat-"), sess === nothing ? "" : sess.id)
        check("the page knows that session id", occursin(sess.id, txt), txt)
        # CHAT INTERFACE trace: a pause must become an advisory MONITOR NOTE.
        # TIMERS, not sleep: sleeping inside a callback blocks the run loop and the
        # monitor's task never gets to run.
        Flooty.chatInteractionTrace!(sess.id, "pause", "I want a parser", 3.0)
        later(function ()
            # chatTurnMessages DRAINS the note: assert delivery, not the queue.
            msgs = Flooty.chatTurnMessages(sess)
            check("a pause trace became a MONITOR NOTE on the next chat turn",
                  any(m -> occursin("MONITOR NOTE", String(m.content)) &&
                           occursin("parser", String(m.content)), msgs),
                  length(msgs))
            L.Webviews.eval!(wv, "createTerminal({ name: \"agent\" });")
            later(handoff, 2.0)
        end, 1.2)
    end
    return nothing
end

function handoff()
    ids = lock(() -> collect(keys(L.OWNERSHIP_SESSIONS)), L.OWNERSHIP_SESSIONS_LOCK)
    check("the shortcut path opened a terminal session", length(ids) == 1, ids)
    if !isempty(ids)
        sess = L.OWNERSHIP_SESSIONS[ids[end]]
        tr = Flooty.conversationTranscript(Flooty.conversationFor(sess))
        check("its agent conversation was seeded from the chat thread",
              length(tr) == 2 && any(l -> occursin("pong", l), tr),
              join(tr, " | "))
    end
    # ONE watcher for the adopted surface: the root-chat monitor is moved to
    # the terminal id, not left running beside a second one.
    rootid = Flooty.ensureRootChatSession!().id
    check("the root chat watcher was migrated to the terminal",
          !haskey(Flooty.CHAT_MONITORS, rootid) &&
          haskey(Flooty.CHAT_MONITORS, ids[end]),
          (rootid, ids[end], collect(keys(Flooty.CHAT_MONITORS))))
    # Re-open the terminal Chat surface after adoption. The root monitor was
    # migrated to the terminal, so this must NOT add a second attachment line.
    Flooty.chatInteractionTrace!(ids[end], "attach", "", 0.0)
    later(function ()
    pageReport() do txt
        check("the tab is named agent", occursin("\"agent\"", txt), txt)
        check("…and its transcript kept the thread",
              occursin("user:hi", txt) && occursin("text:pong", txt), txt)
        check("…and its MONITOR stream moved too",
              occursin("monitor:the user wants a parser", txt), first(txt, 240))
        attachments = length(split(txt, "user monitor attached")) - 1
        check("…with exactly ONE chat-monitor attachment", attachments == 1,
              attachments)
        finish()
    end
    end, 0.45)
    return nothing
end

later(run, 6.0)
Webviews.set_timeout(function (); println("watchdog"); finish() end, wv, 180.0)
L.runEventLoopAndTeardown!(wv)
