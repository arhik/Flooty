# chatDiagnosticsProbe.jl — WARNINGS AND ERRORS BELONG IN THE CHAT.
#
# The status strip shows one live line; an unparseable reply or a provider refusal
# was gone the moment the next turn overwrote the strip. Reported: "I was seeing some
# unresolved parse error in the status bar… it would help to see them in chat".
#
# Covered end to end:
#   * page: a status event with level warn/error becomes a chat message (role warn /
#     error) AND still updates the status strip; plain info stays status-only;
#   * app: the ChatLogLogger forwards @warn/@error from Flooty into the chat,
#     ignores other modules (HTTP is noisy), and de-duplicates.
#
# Run: julia --startup-file=no --project=. test/chatDiagnosticsProbe.jl  (opens a window)
import FlootyPTYLayer
import Flooty
import Webviews
const L = FlootyPTYLayer
const R = Flooty

failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = detail === "" || detail === nothing ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end

wv = L.launchTerminalUI()
const REPORT = Ref("")

function readChat(then)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__diag__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        (function () {
            var st = window.flootyChatState();
            var active = st.tabs[st.active] || { chat: [] };
            window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__diag__',
                text: JSON.stringify({
                    chat: (active.chat || []).map(function (m) { return m.role + ':' + m.text; }),
                    status: (document.getElementById('status-agent') || {}).textContent || '',
                    statusClass: (document.getElementById('status-agent') || {}).className || ''
                }) })).catch(function () {});
        })();
    """)
    poll = function ()
        txt = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__diag__", ""), L.TERMINAL_BUFFER_LOCK)
        if isempty(txt)
            return Webviews.set_timeout(poll, wv, 0.2)
        end
        then(txt)
    end
    Webviews.set_timeout(poll, wv, 0.3)
    return nothing
end

function finish()
    R.uninstallChatLogBridge!()
    try Webviews.close(wv) catch e; L.requestStopEventLoop!(wv) end
    println()
    if isempty(failures)
        println("CHAT_DIAGNOSTICS_PROBE_OK")
    else
        println("FAILED CHECKS: ", join(failures, ", "))
        exit(1)
    end
    return nothing
end

function run()
    check("the log bridge installs", R.installChatLogBridge!(),
          "already installed")
    http = Base.require(Base.PkgId(Base.UUID("cd3eb016-35fb-5094-929b-558a96fad6f3"),
                                   "HTTP"))
    check("…and its source rule covers this stack, not HTTP",
          R.chatLogSource(R) && !R.chatLogSource(http))
    # Wait for the page's script (the chat hook + the report binding).
    Webviews.set_timeout(function ()
        L.pushAgentEventToWindow(wv, L.AgentStatusEvent("", "WARN-IN-STATUS", :warn))
        L.pushAgentEventToWindow(wv, L.AgentStatusEvent("", "ERROR-IN-STATUS", :error))
        L.pushAgentEventToWindow(wv, L.AgentStatusEvent("", "INFO-IN-STATUS", :info))
        Webviews.set_timeout(function ()
            readChat() do txt
                check("a warn status line becomes a chat message (role warn)",
                      occursin("warn:WARN-IN-STATUS", txt), first(txt, 200))
                check("an error status line becomes a chat message (role error)",
                      occursin("error:ERROR-IN-STATUS", txt), "")
                check("a plain info status line stays OUT of the transcript",
                      !occursin("info:INFO-IN-STATUS", txt), "")
                check("the status strip still shows the latest line",
                      occursin("INFO-IN-STATUS", txt), txt)
                # Real Julia logging through the bridge.
                Base.eval(R, :(@warn "LOG-PROBE from the app"))
                Base.eval(Base.require(Base.PkgId(
                    Base.UUID("cd3eb016-35fb-5094-929b-558a96fad6f3"), "HTTP")),
                    :(@warn "HTTP-PROBE should not be forwarded"))
                Webviews.set_timeout(function ()
                    readChat() do t2
                        check("@warn from the app lands in the chat",
                              occursin("warn:", t2) && occursin("LOG-PROBE", t2),
                              first(t2, 300))
                        check("…and another module's warning does not",
                              !occursin("HTTP-PROBE", t2), "")
                        check("@warn deduplicates identical text",
                              begin
                                  # Back-to-back, no round trip: the dedup window is
                                  # wall-clock, so measuring it across page reads is
                                  # not a test of the rule.
                                  R.chatLogEvent(:warn, "DEDUP-PROBE")
                                  R.chatLogEvent(:warn, "DEDUP-PROBE")
                                  true
                              end, "")
                        Webviews.set_timeout(function ()
                            readChat() do t3
                                count = length(collect(eachmatch(r"warn:DEDUP-PROBE", t3)))
                                check("…so the duplicate was not appended", count == 1,
                                      (count, first(t3, 300)))
                                finish()
                            end
                        end, wv, 1.0)
                    end
                end, wv, 1.0)
            end
        end, wv, 0.6)
    end, wv, 6.0)
    return nothing
end

Webviews.set_timeout(run, wv, 2.0)
Webviews.set_timeout(function (); println("watchdog"); finish() end, wv, 180.0)
L.runEventLoopAndTeardown!(wv)
