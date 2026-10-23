# linuxRemoteAppProbe.jl — ssh into a LINUX box FROM THE APP and work interactively.
#
# The pane is a real ssh session in the app's own window (adopted tab + xterm), and
# the standing agent drives it: `send` types at the REMOTE bash prompt, the per-turn
# feedback line reports ok/err, and the chat rail shows the tool blocks. This is the
# Linux counterpart of the macOS send path — prompt detection, error classification
# and output capture all run against a remote shell.
#
# SKIPS (exit 0) when the Linux box is unreachable.
#
# Run: julia --startup-file=no --project=. test/linuxRemoteAppProbe.jl   (opens a window)
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

function reachableHost()
    for h in ("169.254.244.207", "192.168.0.107")
        out = try
            read(`ssh -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR $("arhik@" * h)
                  "uname -s"`, String)
        catch
            ""
        end
        occursin("Linux", out) && return h
    end
    return ""
end

host = reachableHost()
if isempty(host)
    println("SKIP: no Linux box reachable")
    println("LINUX_REMOTE_APP_PROBE_SKIPPED")
    exit(0)
end
println("host=", host)

wv = L.launchTerminalUI()
const REPORT = Ref("")

function finish()
    try Webviews.close(wv) catch e; L.requestStopEventLoop!(wv) end
    println()
    if isempty(failures)
        println("LINUX_REMOTE_APP_PROBE_OK")
    else
        println("FAILED CHECKS: ", join(failures, ", "))
        exit(1)
    end
    return nothing
end

function readChat(sessionId, then)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__remote_app__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        (function () {
            var st = window.flootyChatState();
            var mine = null;
            for (var k in st.tabs) if (st.tabs[k].juliaId === "$(sessionId)") mine = st.tabs[k];
            window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__remote_app__',
                text: JSON.stringify({ chat: mine ? mine.chat.map(function (m) {
                    return m.role + ':' + m.text; }) : null }) })).catch(function () {});
        })();
    """)
    tries = Ref(0)
    poll = function ()
        txt = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__remote_app__", ""),
                   L.TERMINAL_BUFFER_LOCK)
        if isempty(txt) && tries[] < 25
            tries[] += 1
            return Webviews.set_timeout(poll, wv, 0.2)
        end
        # Never leave the probe hanging on a missing report: a timeout IS a failure.
        then(isempty(txt) ? "{chat-not-reported}" : txt)
    end
    Webviews.set_timeout(poll, wv, 0.3)
    return nothing
end

function run()
    # The app's own path: a PTY session running ssh, adopted as a tab in the window.
    sess = L.startReplSession(`ssh -o BatchMode=yes -o LogLevel=ERROR $("arhik@" * host)`;
                              waitPrompt = false, rows = 30, cols = 100)
    id = L.adoptSessionTerminal!(sess; name = "linux-remote")
    println("tab session id=", id)

    # Wait for the REMOTE prompt through the pane's own viewport (the agent's input).
    t0 = time()
    while time() - t0 < 30 && !L._tailAtIdlePrompt(L.tailText(sess.tail))
        sleep(0.25)
    end
    check("the app's pane reaches the remote bash prompt",
          L._tailAtIdlePrompt(L.tailText(sess.tail)), last(L.tailText(sess.tail), 120))
    L.tagIn(sess.control; mode = :agent)

    res = runTerminalAgent!(sess,
        "You are in an interactive ssh session on a Linux machine. " *
        "Run `hostname`, `uname -r` and `df -h /` in the terminal, then stop.";
        maxTurns = 6, evalTimeoutS = 45.0)
    tr = join(res.transcript, "\n")
    check("the agent completes its work on the remote host", res.ok, res.summary)
    check("it sent commands at the remote prompt", occursin("send:", tr), first(tr, 160))
    check("it got the send FEEDBACK back (ok line)", occursin("-> ok:", tr), "")
    check("the remote output was visible to the model",
          occursin("Linux", tr) || occursin("ubuntu", tr), "")
    check("no idle-prompt refusal (prompt detection works on Linux)",
          !occursin("not at an idle prompt", tr), "")

    # The chat rail's data pipeline: the tool call and its result are recorded in
    # this session's conversation (that is what the rail renders; the page-side
    # rendering itself is covered by chatIsolationProbe / chatDiagnosticsProbe).
    conv = conversationFor(sess)
    items = string.(conversationTranscript(conv))
    check("the chat pipeline recorded the remote tool call and its result",
          any(i -> startswith(i, "tool:"), items) &&
          any(i -> occursin("uname", i) || occursin("hostname", i), items),
          join(first(items, 3), " | "))
    L.closeSession!(sess)
    finish()
    return nothing
end

Webviews.set_timeout(run, wv, 2.0)
Webviews.set_timeout(function (); println("watchdog"); finish() end, wv, 300.0)
L.runEventLoopAndTeardown!(wv)
