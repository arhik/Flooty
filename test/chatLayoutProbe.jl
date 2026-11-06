# chatLayoutProbe.jl — chat-only boot, draggable chat pane, lazy terminal.
#
# Verifies, against the REAL page (and the app wiring):
#   * chatOnly boot: no terminal tab, the conversation takes the whole window,
#     the resize grip is hidden;
#   * creating a terminal restores the split; the grip then resizes the chat
#     pane (dragging LEFT widens it) and the width is persisted;
#   * closing the last terminal returns to chat-only.
#
# Run: julia --startup-file=no --project=. test/chatLayoutProbe.jl
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
wv = L.launchTerminalUI(chatOnly = true)
t0 = time()
say(m) = (println("[LAYOUT] ", round(time() - t0; digits = 2), "s ", m); flush(stdout))

const report = Ref("")

"Read the live layout from the page into `report` (binding round-trip)."
function snapshot(then)
    before = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__layout__", ""), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, raw"""
        (function () {
            var ws = document.querySelector('.workspace');
            var panel = document.getElementById('thinkingPanel');
            var grip = document.getElementById('chatResizer');
            var out = {
                tabs: Object.keys(terminals).length,
                chatOnly: ws ? ws.classList.contains('chat-only') : null,
                chatWidth: panel ? Math.round(panel.getBoundingClientRect().width) : -1,
                gripVisible: grip ? (grip.offsetParent !== null) : false,
                windowWidth: window.innerWidth,
                stored: (function () {
                    try { return localStorage.getItem('flooty.chatWidth'); }
                    catch (e) { return null; }
                })(),
                ownershipLabel: (function () {
                    var el = document.getElementById('ownershipLabel');
                    return el ? el.textContent : null;
                })(),
                placeholder: !!document.getElementById('no-terminal')
            };
            window.flootyTerminalBufferReport(JSON.stringify({
                terminal_id: "__layout__", text: JSON.stringify(out)
            })).catch(function () {});
        })();
    """)
    tries = Ref(0)
    poll = function ()
        txt = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__layout__", ""), L.TERMINAL_BUFFER_LOCK)
        if txt != before || tries[] > 40
            report[] = txt
            return then()
        end
        tries[] += 1
        Webviews.set_timeout(poll, wv, 0.1)
    end
    Webviews.set_timeout(poll, wv, 0.1)
    return nothing
end

"Drag the chat rail's grip LEFT by `dx` px (dragging left makes the pane wider)."
function dragGrip(dx)
    L.Webviews.eval!(wv, """
        (function () {
            var g = document.getElementById('chatResizer');
            var r = g.getBoundingClientRect();
            var x = r.left + 3, y = r.top + 40;
            var mk = (type, cx) => new PointerEvent(type, { clientX: cx, clientY: y,
                bubbles: true, cancelable: true, pointerId: 1, pointerType: 'mouse' });
            g.dispatchEvent(mk('pointerdown', x));
            g.dispatchEvent(mk('pointermove', x - """ * string(dx) * """));
            g.dispatchEvent(mk('pointerup', x - """ * string(dx) * """));
        })();
    """)
    return nothing
end

function finish()
    say("closing")
    R.disableJournalPersistence!()
    try
        Webviews.close(wv)
    catch e
        L.requestStopEventLoop!(wv)
    end
    return nothing
end

function stepChatOnly(attempt = 0)
    snapshot() do
        text = report[]
        if !occursin("\"chatOnly\":true", text) && attempt < 30
            return Webviews.set_timeout(() -> stepChatOnly(attempt + 1), wv, 0.2)
        end
        say("chat-only boot: " * text)
        check("no terminal tab on load", occursin("\"tabs\":0", text), first(text, 160))
        check("workspace is in chat-only mode", occursin("\"chatOnly\":true", text))
        m = match(r"\"chatWidth\":(\d+)", text)
        w = match(r"\"windowWidth\":(\d+)", text)
        check("the chat pane fills the window",
              m !== nothing && w !== nothing &&
              parse(Int, m.captures[1]) >= parse(Int, w.captures[1]) - 40, text)
        check("the resize grip is hidden while chat-only",
              occursin("\"gripVisible\":false", text))
        check("there is no 'New Terminal' placeholder page",
              occursin("\"placeholder\":false", text), last(text, 120))
        stepOwnershipLabels()
    end
end

# The status pill must say WHO owns input: "user" or "ai" (not "julia").
function stepOwnershipLabels()
    L.Webviews.eval!(wv, "setOwnershipUi('user');")
    Webviews.set_timeout(function ()
        snapshot() do
            text = report[]
            check("the pill says 'user' when the user owns the pane",
                  occursin("\"ownershipLabel\":\"user\"", text), last(text, 140))
            L.Webviews.eval!(wv, "setOwnershipUi('agent');")
            Webviews.set_timeout(function ()
                snapshot() do
                    text2 = report[]
                    check("the pill says 'ai' when the agent owns the pane",
                          occursin("\"ownershipLabel\":\"ai\"", text2), last(text2, 140))
                    L.Webviews.eval!(wv, "setOwnershipUi('user');")
                    stepTerminalFirst()
                end
            end, wv, 0.2)
        end
    end, wv, 0.2)
end

function stepTerminalFirst()
    say("creating a terminal from the page (split layout)")
    L.Webviews.eval!(wv, "createTerminal();")
    Webviews.set_timeout(function ()
        snapshot() do
            text = report[]
            say("with a terminal: " * text)
            check("a terminal tab appears", occursin("\"tabs\":1", text), first(text, 160))
            check("the split layout returns", occursin("\"chatOnly\":false", text))
            check("the resize grip is visible again", occursin("\"gripVisible\":true", text))
            stepDrag()
        end
    end, wv, 2.5)
end

function stepDrag()
    dragGrip(140)
    Webviews.set_timeout(function ()
        snapshot() do
            text = report[]
            say("after drag: " * text)
            m = match(r"\"chatWidth\":(\d+)", text)
            s = match(r"\"stored\":\"?(\d+)\"?", text)
            check("dragging left widens the chat pane",
                  m !== nothing && parse(Int, m.captures[1]) >= 380,
                  m === nothing ? text : m.captures[1])
            check("the width is persisted to localStorage",
                  s !== nothing && parse(Int, s.captures[1]) >= 380,
                  s === nothing ? text : s.captures[1])
            stepCloseTerminal()
        end
    end, wv, 0.5)
end

function stepCloseTerminal()
    say("closing the only terminal")
    L.Webviews.eval!(wv, "closeTerminal(activeTerminalId);")
    Webviews.set_timeout(function ()
        snapshot() do
            text = report[]
            say("after closing: " * text)
            check("closing the last terminal returns to chat-only",
                  occursin("\"chatOnly\":true", text) && occursin("\"tabs\":0", text),
                  last(text, 140))
            finish()
        end
    end, wv, 1.5)
end

function boot()
    n = lock(() -> length(L.OWNERSHIP_SESSIONS), L.OWNERSHIP_SESSIONS_LOCK)
    say("page up (adopted sessions: " * string(n) * ")")
    Webviews.set_timeout(stepChatOnly, wv, 1.0)
end

Webviews.set_timeout(boot, wv, 2.0)
Webviews.set_timeout(function ()
    say("watchdog")
    finish()
end, wv, 150.0)
L.runEventLoopAndTeardown!(wv)

println()
if isempty(failures)
    println("CHAT_LAYOUT_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
