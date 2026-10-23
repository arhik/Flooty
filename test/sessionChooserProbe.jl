# sessionChooserProbe.jl — one shortcut, choose the session TYPE to spawn.
#
#   * Ctrl+Shift+T opens the SIBLING chooser for the current arena parent;
#   * Ctrl+Shift+R opens the NEW ROOT chooser (terminal / chat, no split);
#   * Ctrl+Shift+O toggles the tree-map overlay (no permanent top tabs);
#   * choosing Chat creates the right ChatSession (child or root).
#
# Run: julia --startup-file=no --project=. test/sessionChooserProbe.jl  (opens a window)
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

function finish()
    try Webviews.close(wv) catch e; L.requestStopEventLoop!(wv) end
    println()
    if isempty(failures)
        println("SESSION_CHOOSER_PROBE_OK")
    else
        println("FAILED CHECKS: ", join(failures, ", "))
        exit(1)
    end
    return nothing
end

function report(then)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__sc__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        (function () {
            var el = document.getElementById('sessionChooser');
            window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__sc__',
                text: JSON.stringify({
                    hidden: el ? !!el.hidden : null,
                    title: (document.getElementById('sessionChooserTitle') || {}).textContent || '',
                    splitHidden: (function () {
                        var b = el && el.querySelector('[data-session-kind="split"]');
                        return b ? !!b.hidden : null;
                    })(),
                    wheel: !!document.getElementById('sessionWheel'),
                    items: (function () {
                        return Array.from(document.querySelectorAll(
                            '#sessionWheel [data-session-kind]')).filter(function (b) {
                            return !b.hidden; }).length;
                    })(),
                    icons: document.querySelectorAll(
                        '#sessionWheel [data-session-kind]:not([hidden]) svg').length,
                    positions: Array.from(document.querySelectorAll(
                        '#sessionWheel [data-session-kind]')).filter(function (b) {
                        return !b.hidden; }).map(function (b) {
                        var r = b.getBoundingClientRect();
                        return [Math.round(r.left), Math.round(r.top),
                                Math.round(r.width)];
                    }),
                    chatTabs: Object.keys(chatTabs),
                    terms: Object.keys(terminals).length,
                    split: (function () {
                        var c = document.getElementById('terminal-container');
                        return !!c && c.classList.contains('split');
                    })(),
                    horizontal: (function () {
                        var c = document.getElementById('terminal-container');
                        return !!c && c.classList.contains('split-horizontal');
                    })(),
                    treeMap: (function () {
                        var e = document.getElementById('childTabs');
                        return e ? getComputedStyle(e).display : null;
                    })(),
                    arena: (function () {
                        var kids = (splitPools[activeTerminalId] || []).slice();
                        var p = document.getElementById(activeTerminalId);
                        return {
                            parent: p ? [p.style.gridColumn, p.style.gridRow] : null,
                            kids: kids.map(function (kid) {
                                var el = document.getElementById(kid);
                                return el ? [el.style.gridColumn, el.style.gridRow] : null;
                            })
                        };
                    })()
                }) })).catch(function () {});
        })();
    """)
    tries = Ref(0)
    poll = function ()
        txt = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__sc__", ""), L.TERMINAL_BUFFER_LOCK)
        if isempty(txt) && tries[] < 40
            tries[] += 1
            return later(poll, 0.1)
        end
        then(txt)
    end
    later(poll, 0.1)
    return nothing
end

key(k) = L.Webviews.eval!(wv, """
    document.dispatchEvent(new KeyboardEvent('keydown',
        { key: "$(k)", ctrlKey: true, shiftKey: true, bubbles: true }));
""")

function waitReady(tries)
    lock(() -> delete!(L.TERMINAL_BUFFER_CACHE, "__sc_ready__"), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, """
        window.flootyTerminalBufferReport(JSON.stringify({ terminal_id: '__sc_ready__',
            text: String(typeof openSessionChooser === 'function' &&
                         typeof chooseSession === 'function') })).catch(function(){});
    """)
    later(function ()
        ok = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__sc_ready__", ""),
                  L.TERMINAL_BUFFER_LOCK) == "true"
        ok && return run()
        tries > 80 && (check("the page became ready", false, ""); return finish())
        waitReady(tries + 1)
    end, 0.2)
    return nothing
end

function run()
    key("R")
    report() do txt
        check("Ctrl+Shift+R opens the NEW ROOT chooser",
              occursin("\"hidden\":false", txt) &&
              occursin("New root session", txt), txt)
        check("…without a split option", occursin("\"splitHidden\":true", txt), txt)
        check("…the chooser is a radial wheel", occursin("\"wheel\":true", txt), txt)
        check("…with five root icons", occursin("\"items\":5", txt) &&
              occursin("\"icons\":5", txt), txt)
        m = match(r"\"positions\":\[\[(\d+),(\d+),(\d+)\]", txt)
        check("…icons are laid out at real positions",
              m !== nothing && parse(Int, m.captures[3]) >= 40 &&
              (parse(Int, m.captures[1]) > 0 || parse(Int, m.captures[2]) > 0),
              m === nothing ? txt : m.captures)
        L.Webviews.eval!(wv,
            "document.querySelector('#sessionChooser [data-session-kind=\"terminal\"]').click();")
        waitTerminal(0)
    end
    return nothing
end

function waitTerminal(tries)
    ids = lock(() -> collect(keys(L.OWNERSHIP_SESSIONS)), L.OWNERSHIP_SESSIONS_LOCK)
    if isempty(ids)
        tries > 80 && (check("a root terminal was spawned", false, ""); return finish())
        return later(() -> waitTerminal(tries + 1), 0.15)
    end
    check("a root terminal was spawned", true, ids)
    root = Flooty.rootChatSession()
    ts = Flooty.sessionForId(ids[end])
    check("…as a child of the root chat",
          ts isa Flooty.TerminalSession && ts.parent == root.id,
          string(ts isa Flooty.TerminalSession ? ts.parent : "?"))
    key("R")
    report() do txt
        check("Ctrl+Shift+R again opens the root chooser",
              occursin("New root session", txt), txt)
        L.Webviews.eval!(wv,
            "document.querySelector('#sessionChooser [data-session-kind=\"chat\"]').click();")
        waitRootChat(0)
    end
    return nothing
end

function waitRootChat(tries)
    root_ids = [s.id for s in collect(values(Flooty.SESSIONS))
                if s isa Flooty.ChatSession]
    newroot = filter(id -> id != Flooty.rootChatSession().id, root_ids)
    if isempty(newroot)
        tries > 80 && (check("a new root ChatSession was created", false, root_ids);
                       return finish())
        return later(() -> waitRootChat(tries + 1), 0.15)
    end
    cs = Flooty.sessionForId(newroot[end])
    check("a new root ChatSession was created", true, cs.id)
    check("…with no parent", cs.parent === nothing, string(cs.parent))
    report() do txt
        check("…and its chat tab is present", occursin(cs.id, txt), first(txt, 240))
        # Ctrl+Shift+T is the sibling chooser (same arena parent).
        key("T")
        report() do sib
            check("Ctrl+Shift+T opens the SIBLING radial",
                  occursin("\"hidden\":false", sib) &&
                  occursin("Sibling session", sib), sib)
            check("…and the permanent top tabs stay hidden",
                  occursin("\"treeMap\":\"none\"", sib), sib)
            L.Webviews.eval!(wv, "closeSessionChooser();")
        end
        # Alt+D: the radial SPLIT chooser. Nothing is spawned until a type is
        # chosen; the chosen session is a child of the active context.
        L.Webviews.eval!(wv, """
            document.dispatchEvent(new KeyboardEvent('keydown',
                { key: '∂', code: 'KeyD', altKey: true, bubbles: true }));
        """)
        report() do sc
            check("Alt+D opens the SPLIT radial", occursin("\"hidden\":false", sc) &&
                  occursin("Sibling session", sc), sc)
            check("…without a redundant split item",
                  occursin("\"splitHidden\":true", sc), sc)
            check("…and no child is spawned before choosing",
                  !occursin("\"split\":true", sc), sc)
            L.Webviews.eval!(wv,
                "document.querySelector('#sessionChooser [data-session-kind=\"terminal\"]').click();")
            waitSplit(0, false)
        end
    end
    return nothing
end

function waitSplit(tries, horizontal)
    child = L.splitSession()
    if child === nothing
        tries > 80 && (check("Alt+D opened a split child", false, "");
                       return finish())
        return later(() -> waitSplit(tries + 1, horizontal), 0.15)
    end
    check("Alt+D opened a split child", true, L.sessionIdFor(child))
    report() do txt
        check("…as the parent-left arena", occursin("\"split\":true", txt) &&
              occursin("\"horizontal\":false", txt), txt)
        # Alt+Shift+D opens the same radial (geometry stays constant).
        L.Webviews.eval!(wv, """
            document.dispatchEvent(new KeyboardEvent('keydown',
                { key: 'Î', code: 'KeyD', altKey: true, shiftKey: true,
                  bubbles: true }));
        """)
        later(function ()
            report() do sc2
                check("Alt+Shift+D opens the same split radial",
                      occursin("Sibling session", sc2), sc2)
                L.Webviews.eval!(wv,
                    "document.querySelector('#sessionChooser [data-session-kind=\"terminal\"]').click();")
                later(function ()
                    report() do txt2
                        check("…and the arena keeps parent left / children stacked",
                              occursin("\"split\":true", txt2) &&
                              occursin("\"horizontal\":false", txt2) &&
                              occursin("\"arena\":{\"parent\":[\"1\",\"1 / span 2\"]", txt2),
                              txt2)
                        finish()
                    end
                end, 0.5)
            end
        end, 0.3)
    end
    return nothing
end

later(() -> waitReady(0), 0.5)
Webviews.set_timeout(function (); println("watchdog"); finish() end, wv, 120.0)
L.runEventLoopAndTeardown!(wv)
