# perTabModelPageProbe.jl — the PICKER addresses its OWN tab, not the process.
#
# The page sends its active tab's terminal id with flootyModels/flootySetModel, so
# choosing a model changes THAT tab's session config and leaves the process
# default alone (the two-tab semantics live in test/perTabModelProbe.jl).
#
# Run: julia --startup-file=no --project=. test/perTabModelPageProbe.jl  (window)
import FlootyPTYLayer
import Flooty
import Webviews
const L = FlootyPTYLayer
const R = Flooty
const DIR = mktempdir()

failures = String[]
const ran = Ref(0)
function check(name::String, ok::Bool, detail = "")
    showed = detail === "" || detail === nothing ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(showed) ? "" : "  [" * showed * "]")
    ok || push!(failures, name)
end

R.agentApp(sessionsDir = DIR, journalPath = joinpath(DIR, "journal.sqlite"))
wv = L.launchTerminalUI()
t0 = time()
say(m) = (println("[PTM] ", round(time() - t0; digits = 2), "s ", m); flush(stdout))
const tab = Ref("")
const target = Ref("")
const monitorTarget = Ref("")
const decisionTarget = Ref("")

function finish()
    R.disableJournalPersistence!()
    try Webviews.close(wv) catch e; L.requestStopEventLoop!(wv) end
    println()
    if ran[] == 0
        println("FAILED CHECKS: the probe never reached its checks")
        exit(1)
    elseif isempty(failures)
        println("PER_TAB_MODEL_PAGE_PROBE_OK")
    else
        println("FAILED CHECKS: ", join(failures, ", "))
        exit(1)
    end
    return nothing
end

"Read the real <select> state off the page."
function pickerValue(then)
    before = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__ptm__", ""), L.TERMINAL_BUFFER_LOCK)
    L.Webviews.eval!(wv, raw"""
        (function () {
            var sel = document.getElementById('modelSelect');
            var active = terminals[activeTerminalId] || {};
            var mon = document.getElementById('monitorSelect');
            var dec = document.getElementById('decisionSelect');
            window.flootyTerminalBufferReport(JSON.stringify({
                terminal_id: '__ptm__',
                text: JSON.stringify({ value: sel ? sel.value : null,
                                       options: sel ? sel.options.length : 0,
                                       monitor: mon ? mon.value : null,
                                       decision: dec ? dec.value : null,
                                       activeId: active.juliaId || null,
                                       tabModel: active.model || null })
            })).catch(function () {});
        })();
    """)
    tries = Ref(0)
    poll = function ()
        txt = lock(() -> get(L.TERMINAL_BUFFER_CACHE, "__ptm__", ""), L.TERMINAL_BUFFER_LOCK)
        if txt != before || tries[] > 40
            return then(txt)
        end
        tries[] += 1
        Webviews.set_timeout(poll, wv, 0.1)
    end
    Webviews.set_timeout(poll, wv, 0.1)
    return nothing
end

function stepChange(txt)
    say("picker state: " * txt)
    check("the picker is bound to THIS tab's session id",
          occursin("\"activeId\":\"" * tab[] * "\"", txt), txt)
    check("the monitor picker shows its OWN model",
          occursin("\"monitor\":\"" * monitorTarget[] * "\"", txt), txt)
    if !isempty(decisionTarget[])
        check("the decision picker shows its OWN model",
              occursin("\"decision\":\"" * decisionTarget[] * "\"", txt), txt)
    end
    # Drive the REAL picker interaction: setting the <select> and firing its
    # change event goes through the page handler (including its generation
    # guard), exactly as a user's click does.
    L.Webviews.eval!(wv, """
        (function () {
            var sel = document.getElementById('modelSelect');
            if (!sel) return;
            sel.value = """ * repr(target[]) * """;
            sel.dispatchEvent(new Event('change', { bubbles: true }));
        })();
    """)
    Webviews.set_timeout(function ()
        # The real picker repaints from a fresh flootyModels read; do the same so
        # the page's per-tab memory is populated.
        L.Webviews.eval!(wv, "if (typeof refreshAgentModels === 'function') refreshAgentModels();")
    end, wv, 0.3)
    Webviews.set_timeout(function ()
        ran[] += 1
        globalDefault = R.AGENT_CONFIG[].actorModel
        current = R.agentModelState(tab[]).current
        check("the page's set-model changed THAT tab", current == target[],
              (current, target[]))
        check("…and left the process default alone", globalDefault != target[],
              (globalDefault, target[]))
        pickerValue() do txt2
            say("picker after change: " * txt2)
            check("the page remembers the model for that tab",
                  occursin("\"tabModel\":\"" * target[] * "\"", txt2), txt2)
            check("choosing a driver leaves the monitor picker alone",
                  occursin("\"monitor\":\"" * monitorTarget[] * "\"", txt2), txt2)
            check("the backend monitor also stayed put",
                  R.agentModelState(tab[]).monitor == monitorTarget[],
                  R.agentModelState(tab[]).monitor)
            if !isempty(decisionTarget[])
                check("choosing a driver leaves the decision picker alone",
                      occursin("\"decision\":\"" * decisionTarget[] * "\"", txt2), txt2)
                check("the backend decision also stayed put",
                      R.agentModelState(tab[]).decision == decisionTarget[],
                      R.agentModelState(tab[]).decision)
            end
            finish()
        end
    end, wv, 1.0)
    return nothing
end

function waitModels(attempt = 0)
    options = R.availableAgentModels()
    if isempty(options)
        if attempt > 40
            check("the endpoint's model list arrived", false, "timeout")
            return finish()
        end
        return Webviews.set_timeout(() -> waitModels(attempt + 1), wv, 0.25)
    end
    say("endpoint models: " * string(options))
    defaultModel = R.AGENT_CONFIG[].actorModel
    others = [m for m in options if m != defaultModel]
    if isempty(others)
        check("the endpoint offers a second model", false, options)
        return finish()
    end
    target[] = others[end]
    monitorTarget[] = others[1]
    R.selectMonitorModel(monitorTarget[], tab[])
    checks = R.agentModelState(tab[])
    if !isempty(checks.decision_models)
        decisionTarget[] = checks.decision_models[1]
        R.selectDecisionModel(decisionTarget[], tab[])
    end
    check("the tab starts on the default", R.agentModelState(tab[]).current == defaultModel,
          R.agentModelState(tab[]).current)
    check("monitor starts on its OWN model",
          R.agentModelState(tab[]).monitor == monitorTarget[], R.agentModelState(tab[]).monitor)
    R.refreshAgentModels!()
    L.Webviews.eval!(wv, "if (typeof refreshAgentModels === 'function') refreshAgentModels();")
    Webviews.set_timeout(function ()
        pickerValue(stepChange)
    end, wv, 1.0)
    return nothing
end

function waitSession(attempt = 0)
    n = lock(() -> length(L.OWNERSHIP_SESSIONS), L.OWNERSHIP_SESSIONS_LOCK)
    if n == 0
        if attempt > 120
            check("a session exists", false, "timeout")
            return finish()
        end
        return Webviews.set_timeout(() -> waitSession(attempt + 1), wv, 0.25)
    end
    tab[] = lock(() -> first(keys(L.OWNERSHIP_SESSIONS)), L.OWNERSHIP_SESSIONS_LOCK) |> String
    say("tab ready: " * tab[])
    R.refreshAgentModels!()
    waitModels()
    return nothing
end

Webviews.set_timeout(waitSession, wv, 2.0)
Webviews.set_timeout(function (); say("watchdog"); finish() end, wv, 120.0)
L.runEventLoopAndTeardown!(wv)
