# chatTerminalLaunchProbe.jl — the CHAT session opens a terminal on its own.
#
# The app boots chat-only. When the user's prompt needs a real terminal, the chat
# driver answers with {"action":"terminal","task":"…"}; the driver must then
#   * create a session-backed terminal and adopt a visible tab named "agent";
#   * seed it with the chat thread;
#   * attach its ambient monitor and standing agent;
#   * commission the task (the standing agent runs it);
# while the chat rail shows a human confirmation, not the raw tool JSON.
#
# Run: julia --startup-file=no --project=. test/chatTerminalLaunchProbe.jl  (opens a window)
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

# The reply protocol: prose and {"reply":…} stay chat; the terminal tool is a
# distinct kind with a task.
p1 = parseChatReply("pong")
check("prose stays chat", p1.kind === :chat && p1.text == "pong", p1)
p2 = parseChatReply("{\"reply\":\"use a Set\"}")
check("a reply wrapper is unwrapped", p2.kind === :chat && p2.text == "use a Set", p2)
p3 = parseChatReply("<thinking>open it</thinking>{\"action\":\"terminal\",\"task\":\"run pwd\"}")
check("the terminal tool is parsed",
      p3.kind === :terminal && p3.task == "run pwd", p3)

# The reported bug: the first reply is REASONING ONLY. The driver must retry,
# never render "<thinking>…</thinking>" as the agent's text, then launch.
const CHAT_CALLS = Ref(0)
CHAT_COMPLETE[] = _ -> begin
    CHAT_CALLS[] += 1
    CHAT_CALLS[] == 1 ?
        "<thinking>The user wants to launch a Julia REPL. I need to open a terminal for this.</thinking>" :
        "{\"action\":\"terminal\",\"task\":\"echo CHAT_LAUNCH\"}"
end
RUNNER_COMPLETE[] = _ -> "{\"action\":\"done\",\"summary\":\"CHAT_LAUNCH_RUN\"}"

wv = L.launchTerminalUI(chatOnly = true)
later(f, s = 0.25) = Webviews.set_timeout(f, wv, s)
const SESS = Ref{Any}(nothing)

function finish()
    SESS[] === nothing || try Flooty.stopAgentRunner!(SESS[]) catch e; nothing end
    SESS[] === nothing || try Flooty.stopMonitor!(SESS[]) catch e; nothing end
    SESS[] === nothing || try L.closeSession!(SESS[]) catch e; nothing end
    try Webviews.close(wv) catch e; L.requestStopEventLoop!(wv) end
    println()
    if isempty(failures)
        println("CHAT_TERMINAL_LAUNCH_PROBE_OK")
    else
        println("FAILED CHECKS: ", join(failures, ", "))
        exit(1)
    end
    return nothing
end

function pageReport(then)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__ctl__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        (function () {
            window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__ctl__',
                text: JSON.stringify({
                    tabs: Object.keys(terminals).length,
                    names: Object.keys(terminals).map(function (k) { return terminals[k].name; }),
                    active: (terminals[activeTerminalId] || {}).name || '',
                    monitor: ((terminals[activeTerminalId] || {}).monitorChat || []).map(
                        function (m) { return m.role + ':' + m.text; }),
                    unread: (terminals[activeTerminalId] || {}).monitorUnread || 0,
                    chatOnlyMonitor: (CHAT_ONLY.monitorChat || []).map(
                        function (m) { return m.role + ':' + m.text; })
                }) })).catch(function () {});
        })();
    """)
    tries = Ref(0)
    poll = function ()
        txt = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__ctl__", ""), L.TERMINAL_BUFFER_LOCK)
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
    check("boot is chat-only (no terminal session)",
          isempty(lock(() -> collect(keys(L.OWNERSHIP_SESSIONS)), L.OWNERSHIP_SESSIONS_LOCK)),
          "")
    # A monitor message in the chat-only rail must move to the new tab's
    # Monitor stream (the reported "monitor tab is empty" case). Confirm the
    # push before launching: page evals and terminal creation are async.
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__pushed__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        (function () {
            pushChatForSession(CHAT_SESSION_ID, 'monitor', 'MONITOR_CHAT_ONLY', 'monitor');
            window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__pushed__',
                text: String((CHAT_ONLY.monitorChat || []).length) })).catch(function(){});
        })();
    """)
    waitPushed(0)
    return nothing
end

function waitPushed(tries)
    n = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__pushed__", ""), L.TERMINAL_BUFFER_LOCK)
    if n == "1"
        # Call the production chat driver directly: the page's submit path is
        # covered by chatOnlyProbe; here the subject is the launch/commission.
        Flooty.chatOnlyTurn!(wv, "open a terminal and run the launch check")
        later(stepLaunched, 0.5)
        return nothing
    end
    tries > 30 && (check("the chat-only monitor message landed", false, n); return finish())
    later(() -> waitPushed(tries + 1), 0.1)
    return nothing
end

const TRIES = Ref(0)
function stepLaunched()
    ids = lock(() -> collect(keys(L.OWNERSHIP_SESSIONS)), L.OWNERSHIP_SESSIONS_LOCK)
    if isempty(ids)
        TRIES[] += 1
        if TRIES[] > 80
            root = Flooty.rootChatSession()
            println("DEBUG root: ",
                    join(Flooty.conversationTranscript(
                        Flooty.conversationOf(root)), " | "))
            check("the chat prompt opened a terminal session", false, "")
            return finish()
        end
        return later(stepLaunched, 0.25)
    end
    SESS[] = L.OWNERSHIP_SESSIONS[ids[end]]
    sess = SESS[]
    check("the chat prompt opened a terminal session", true, ids[end])
    check("…with its ambient monitor attached",
          haskey(Flooty.MONITOR_STATES, sess), "")
    check("…and its standing agent running",
          Flooty.agentRunnerRunning(sess), "")

    root = Flooty.rootChatSession()
    rtr = join(Flooty.conversationTranscript(Flooty.conversationOf(root)), "\n")
    check("the chat rail shows a human confirmation",
          occursin("Opening a terminal", rtr), first(rtr, 200))
    check("…never the raw tool JSON",
          !occursin("\"action\":\"terminal\"", rtr), first(rtr, 200))
    check("…and never raw <thinking>",
          !occursin("<thinking>", rtr), first(rtr, 200))
    check("a reasoning-only reply was retried", CHAT_CALLS[] == 2, CHAT_CALLS[])

    ttr = join(Flooty.conversationTranscript(Flooty.conversationFor(sess)), "\n")
    check("the new terminal was seeded with the chat thread",
          occursin("open a terminal and run the launch check", ttr), first(ttr, 240))

    waitTab(0)
    return nothing
end

"Adoption attaches the tab asynchronously; wait for it before asserting."
function waitTab(tries)
    pageReport() do txt
        if occursin("\"tabs\":1", txt)
            check("a visible tab exists", true, "")
            check("…named agent", occursin("\"agent\"", txt), txt)
            check("…and it is the active tab", occursin("\"active\":\"agent\"", txt), txt)
            check("…and the chat-only MONITOR stream moved with it",
                  occursin("MONITOR_CHAT_ONLY", txt), first(txt, 300))
            return waitRun(0)
        end
        if tries > 80
            check("a visible tab exists", false, txt)
            return finish()
        end
        later(() -> waitTab(tries + 1), 0.25)
    end
    return nothing
end

function waitRun(tries)
    sess = SESS[]
    tr = join(Flooty.conversationTranscript(Flooty.conversationFor(sess)), "\n")
    if occursin("CHAT_LAUNCH_RUN", tr)
        check("the standing agent ran the commissioned task", true, "")
        check("…the task reached it", occursin("echo CHAT_LAUNCH", tr), "")
        check("…and the runner is idle again", !Flooty.agentRunnerBusy(sess), "")
        return finish()
    end
    if tries > 120
        check("the standing agent ran the commissioned task", false, first(tr, 300))
        return finish()
    end
    later(() -> waitRun(tries + 1), 0.25)
    return nothing
end

later(run, 2.0)
Webviews.set_timeout(function ()
    println("watchdog")
    finish()
end, wv, 120.0)
L.runEventLoopAndTeardown!(wv)
