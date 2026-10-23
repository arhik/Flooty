# keyScrollProbe.jl — PageUp/PageDown scroll the CHAT and the TERMINAL.
#
# Reported: PageUp/PageDown are not supported for scrolling in either surface. Two
# causes: the chat's scroll box only follows the caret (the assist box has focus,
# so the key never reached the transcript), and in the pane the key tripped the
# "user typed -> take over" path instead of scrolling xterm's scrollback.
#
# Run: julia --startup-file=no --project=. test/keyScrollProbe.jl  (opens a window)
import FlootyPTYLayer
import Flooty
import Webviews
const L = FlootyPTYLayer
const R = Flooty
const DIR = mktempdir()

failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = detail === "" || detail === nothing ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end

R.agentApp(sessionsDir = DIR, journalPath = joinpath(DIR, "journal.sqlite"))
wv = L.launchTerminalUI()
t0 = time()
say(m) = (println("[KEY] ", round(time() - t0; digits = 2), "s ", m); flush(stdout))
const report = Ref("")

function snapshot(then)
    before = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__key__", ""), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, raw"""
        (function () {
            var log = document.getElementById('agentChatLog');
            var info = terminals[activeTerminalId] || {};
            var buf = info.term ? info.term.buffer.active : null;
            var pill = document.getElementById('ownershipLabel');
            window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__key__',
                text: JSON.stringify({
                    chatScroll: log ? Math.round(log.scrollTop) : -1,
                    chatHeight: log ? Math.round(log.clientHeight) : -1,
                    chatMax: log ? Math.round(log.scrollHeight) : -1,
                    termViewportY: buf ? buf.viewportY : -1,
                    termBaseY: buf ? buf.baseY : -1,
                    owner: pill ? pill.textContent : null,
                    active: activeTerminalId || null,
                    focused: (document.activeElement && (document.activeElement.className ||
                              document.activeElement.tagName)) || null
                }) })).catch(function () {});
        })();
    """)
    tries = Ref(0)
    poll = function ()
        txt = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__key__", ""), L.TERMINAL_BUFFER_LOCK)
        if txt != before || tries[] > 40
            report[] = txt
            return then(txt)
        end
        tries[] += 1
        Webviews.set_timeout(poll, wv, 0.1)
    end
    Webviews.set_timeout(poll, wv, 0.1)
    return nothing
end

function finish()
    R.disableJournalPersistence!()
    try Webviews.close(wv) catch e; L.requestStopEventLoop!(wv) end
    println()
    if isempty(failures)
        println("KEY_SCROLL_PROBE_OK")
    else
        println("FAILED CHECKS: ", join(failures, ", "))
        exit(1)
    end
    return nothing
end

num(txt, key) = (m = match(Regex("\"" * key * "\":(-?\\d+)"), txt);
                 m === nothing ? -1 : parse(Int, m.captures[1]))

function stepChat()
    # Fill the transcript so it can actually scroll.
    L.Webviews.eval!(wv, raw"""
        (function () {
            var info = terminals[activeTerminalId];
            for (var i = 1; i <= 40; i++) {
                pushChat(info, i % 2 ? 'text' : 'user',
                         'scroll fixture line ' + i + ' ' + 'x'.repeat(40));
            }
            var ta = document.querySelector('#assistEditor textarea');
            ta.focus();
        })();
    """)
    Webviews.set_timeout(function ()
        snapshot() do before
            startScroll = num(before, "chatScroll")
            maxScroll = num(before, "chatMax") - num(before, "chatHeight")
            check("the chat transcript can scroll (fixture filled it)",
                  maxScroll > 100, (maxScroll, before))
            # PageUp must scroll the transcript even though the ASSIST box has focus.
            L.Webviews.eval!(wv, """
                (function () {
                    var ta = document.querySelector('#assistEditor textarea');
                    ta.dispatchEvent(new KeyboardEvent('keydown', { key: 'PageUp',
                        bubbles: true, cancelable: true }));
                })();
            """)
            Webviews.set_timeout(function ()
                snapshot() do up
                    check("PageUp scrolls the chat transcript up",
                          num(up, "chatScroll") < startScroll ||
                          num(up, "chatScroll") <= maxScroll - 100,
                          (startScroll, num(up, "chatScroll")))
                    L.Webviews.eval!(wv, """
                        (function () {
                            var ta = document.querySelector('#assistEditor textarea');
                            ta.dispatchEvent(new KeyboardEvent('keydown', { key: 'PageDown',
                                bubbles: true, cancelable: true }));
                        })();
                    """)
                    Webviews.set_timeout(function ()
                        snapshot() do down
                            check("PageDown scrolls it back down",
                                  num(down, "chatScroll") > num(up, "chatScroll"),
                                  (num(up, "chatScroll"), num(down, "chatScroll")))
                            stepTerminal()
                        end
                    end, wv, 0.3)
                end
            end, wv, 0.3)
        end
    end, wv, 0.5)
    return nothing
end

function stepTerminal()
    # Fill xterm's scrollback, then check BOTH paths:
    #  * focus in the pane: the native browser paging must be LEFT ALONE (our
    #    handler may not preventDefault), which is what scrolls xterm;
    #  * no focus (body): our handler drives `term.scrollPages` itself.
    L.Webviews.eval!(wv, raw"""
        (function () {
            var info = terminals[activeTerminalId];
            for (var i = 1; i <= 300; i++) info.term.write('scrollback line ' + i + '\r\n');
        })();
    """)
    Webviews.set_timeout(function ()
        # (a) pane focused -> the event must NOT be consumed by our handler
        L.Webviews.eval!(wv, """
            (function () {
                var el = document.getElementById(activeTerminalId);
                var ta = el && el.querySelector('.xterm-helper-textarea');
                if (ta) ta.focus();
                var ev = new KeyboardEvent('keydown', { key: 'PageUp', bubbles: true,
                                                        cancelable: true });
                (ta || document.body).dispatchEvent(ev);
                window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__key2__',
                    text: JSON.stringify({ prevented: ev.defaultPrevented }) })).catch(function () {});
            })();
        """)
        Webviews.set_timeout(function ()
            txt = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__key2__", ""), L.TERMINAL_BUFFER_LOCK)
            check("a focused pane keeps NATIVE page scrolling (our handler stays out)",
                  occursin("\"prevented\":false", txt), txt)
            # (b) nothing focused -> our handler scrolls xterm itself
            snapshot() do before
                y0 = num(before, "termViewportY")
                L.Webviews.eval!(wv, """
                    (function () {
                        if (document.activeElement && document.activeElement.blur)
                            document.activeElement.blur();
                        document.body.dispatchEvent(new KeyboardEvent('keydown',
                            { key: 'PageUp', bubbles: true, cancelable: true }));
                    })();
                """)
                Webviews.set_timeout(function ()
                    snapshot() do up
                        check("PageUp with no focus scrolls the TERMINAL scrollback",
                              num(up, "termViewportY") < y0,
                              (y0, num(up, "termViewportY"), num(up, "termBaseY")))
                        check("…without taking the pane over (owner stays ai)",
                              occursin("\"owner\":\"ai\"", up), up)
                        L.Webviews.eval!(wv, """
                            (function () {
                                document.body.dispatchEvent(new KeyboardEvent('keydown',
                                    { key: 'PageDown', bubbles: true, cancelable: true }));
                            })();
                        """)
                        Webviews.set_timeout(function ()
                            snapshot() do down
                                check("PageDown scrolls the terminal back down",
                                      num(down, "termViewportY") > num(up, "termViewportY"),
                                      (num(up, "termViewportY"), num(down, "termViewportY")))
                                finish()
                            end
                        end, wv, 0.4)
                    end
                end, wv, 0.4)
            end
        end, wv, 0.5)
    end, wv, 1.2)
    return nothing
end

function boot(attempt = 0)
    n = lock(() -> length(L.OWNERSHIP_SESSIONS), L.OWNERSHIP_SESSIONS_LOCK)
    if n == 0
        if attempt > 120
            check("a session exists", false, "timeout")
            return finish()
        end
        return Webviews.set_timeout(() -> boot(attempt + 1), wv, 0.25)
    end
    say("page ready")
    stepChat()
    return nothing
end

Webviews.set_timeout(boot, wv, 2.0)
Webviews.set_timeout(function (); say("watchdog"); finish() end, wv, 120.0)
L.runEventLoopAndTeardown!(wv)
