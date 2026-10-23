# modelPickerProbe.jl — the status-bar model picker, end to end.
#
# FlootyPTYLayer owns the webview bindings but knows nothing about models; the
# agent package installs the controller (`addAgentModelHooks!`) and answers. This
# probe drives the REAL page against the REAL endpoint:
#   * the select is populated from `GET /v1/models` (and shows the model in force),
#   * choosing an entry switches the process-wide config (actor AND monitor),
#   * the page reflects the new choice,
#   * and the original model is restored afterwards.
#
# Requires a desktop session (opens the native window, like the other UI probes).
#
# Run: julia --startup-file=no --project=. test/modelPickerProbe.jl
# Verdict line on stdout: [MODEL-PROBE] {"failed":N,"checks":M}
import FlootyPTYLayer
using FlootyPTYLayer
import Flooty
import Webviews

failures = String[]
checks = Ref(0)
function check(name::String, ok::Bool; detail::String = "")
    checks[] += 1
    println(ok ? "PASS  " : "FAIL  ", name, isempty(detail) ? "" : "  [$detail]")
    ok || push!(failures, name)
end

before = Flooty.agentModelState()
println("endpoint models: ", join(before.available, ", "), "   in force: ", repr(before.current))
if isempty(before.available)
    println("[MODEL-PROBE] {\"failed\":0,\"checks\":0,\"skipped\":\"endpoint lists no models\"}")
    exit(0)
end

wv = launchTerminalUI()
report = Ref("")
Webviews.bind(wv, "probeModelReport") do args
    report[] = args isa Tuple && !isempty(args) ? String(args[1]) : ""
    return "{\"success\":true}"
end
closeWv() = (try Webviews.close(wv) catch e; FlootyPTYLayer.requestStopEventLoop!(wv) end; nothing)

function stepRead()
    Webviews.eval!(wv, """
    (function () {
      const sel = document.getElementById('modelSelect');
      return probeModelReport(JSON.stringify({
        disabled: sel.disabled,
        current: sel.value,
        options: [...sel.options].map(o => o.value)
      }));
    })()
    """)
    Webviews.set_timeout(stepCheck, wv, 3.0)
end

function stepCheck()
    payload = report[]
    check("picker is enabled and lists the endpoint's models",
          !occursin("\"disabled\":true", payload) &&
          all(m -> occursin("\"" * m * "\"", payload), before.available);
          detail = String(first(payload, 240)))
    check("picker shows the model in force",
          occursin("\"current\":\"" * before.current * "\"", payload);
          detail = String(first(payload, 240)))
    others = filter(m -> m != before.current, before.available)
    if isempty(others)
        println("SKIP  only one model on offer — nothing to switch to")
        closeWv()
        return
    end
    target = String(first(others))
    println("switching to ", target)
    Webviews.eval!(wv, """
    (function () {
      const sel = document.getElementById('modelSelect');
      sel.value = "$(target)";
      sel.dispatchEvent(new Event('change'));
    })()
    """)
    Webviews.set_timeout(() -> stepVerify(target), wv, 3.0)
end

function stepVerify(target::String)
    now = Flooty.agentModelState()
    check("choosing a model switches the agent config (actor)", now.current == target;
          detail = "config says " * now.current)
    cfg = Flooty.AGENT_CONFIG[]
    check("the monitor follows the actor", cfg.monitorModel == target;
          detail = "monitor says " * cfg.monitorModel)
    Webviews.eval!(wv, """
    (function () {
      const sel = document.getElementById('modelSelect');
      return probeModelReport(JSON.stringify({ current: sel.value }));
    })()
    """)
    Webviews.set_timeout(() -> stepFinish(target), wv, 1.5)
end

function stepFinish(target::String)
    check("the page shows the new model",
          occursin("\"current\":\"" * target * "\"", report[]);
          detail = String(first(report[], 200)))
    Flooty.selectAgentModel(before.current)      # leave the machine as found
    println("restored ", repr(Flooty.agentModelState().current))
    closeWv()
end

Webviews.set_timeout(stepRead, wv, 3.0)
Webviews.set_timeout(() -> (println("WATCHDOG: closing the window"); closeWv()), wv, 90.0)
FlootyPTYLayer.runEventLoopAndTeardown!(wv)

println("[MODEL-PROBE] {\"failed\":", length(failures), ",\"checks\":", checks[], "}")
isempty(failures) || (println("FAILED CHECKS: ", join(failures, ", ")); exit(1))
println("MODEL_PICKER_PROBE_OK")
exit(0)
