# perTabModelProbe.jl — a DIFFERENT model per tab.
#
# The process default stays the fallback (headless runs, tabs that never chose),
# but each live session can pin its own model: the loop, the context window and
# the monitor read the SESSION's config, the transcript is tagged with it, and
# the picker (page) addresses its tab by terminal id.
#
# Run: julia --startup-file=no --project=. test/perTabModelProbe.jl   (no window)
using Flooty
using FlootyPTYLayer
import FlootyPTYLayer: startReplSession, closeSession!, adoptSessionTerminal!
import FlootyAbstract

failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = detail === "" || detail === nothing ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end

s1 = startReplSession(`julia --startup-file=no -q`)
s2 = startReplSession(`julia --startup-file=no -q`)
try
    sleep(2.0)
    id1 = adoptSessionTerminal!(s1; name = "tab one")
    id2 = adoptSessionTerminal!(s2; name = "tab two")
    defaultModel = Flooty.AGENT_CONFIG[].actorModel
    check("both tabs start on the process default",
          Flooty.agentModelState(id1).current == defaultModel &&
          Flooty.agentModelState(id2).current == defaultModel,
          (Flooty.agentModelState(id1).current, defaultModel))

    # ---- pin a DIFFERENT model per tab ------------------------------------
    st1 = Flooty.selectAgentModel("model-A", id1)
    st2 = Flooty.selectAgentModel("model-B", id2)
    check("tab one reports its own model", st1.current == "model-A", st1.current)
    check("tab two reports a DIFFERENT model", st2.current == "model-B", st2.current)
    check("the two tabs really differ",
          Flooty.agentModelState(id1).current != Flooty.agentModelState(id2).current,
          (Flooty.agentModelState(id1).current, Flooty.agentModelState(id2).current))
    check("the per-session config carries it",
          sessionModelConfig(s1).actorModel == "model-A" &&
          sessionModelConfig(s2).actorModel == "model-B")
    check("the process default is untouched",
          Flooty.AGENT_CONFIG[].actorModel == defaultModel,
          Flooty.AGENT_CONFIG[].actorModel)

    # ---- the run is tagged with the tab's model ---------------------------
    fake = messages -> "{\"action\":\"done\",\"summary\":\"noop\"}"
    runTerminalAgent!(s1, "tag the transcript"; completeFn = fake, maxTurns = 2,
                      evalTimeoutS = 20.0)
    items = FlootyAbstract.get_messages(conversationFor(s1))
    check("the tab's transcript is tagged with ITS model",
          !isempty(items) && items[end].model == "model-A",
          isempty(items) ? "-" : items[end].model)

    # ---- unknown id / no id = the process default -------------------------
    check("an unknown terminal id answers with the default",
          Flooty.agentModelState("no-such-tab").current == defaultModel)
    check("setting with no id changes the process default",
          Flooty.selectAgentModel("model-C", "").current == "model-C" &&
          Flooty.agentModelState(id1).current == "model-A" &&
          Flooty.agentModelState("").current == "model-C",
          (Flooty.agentModelState(id1).current, Flooty.agentModelState("").current))

    # ---- dropping the per-tab choice falls back to the default ------------
    forgetSessionModel!(s1)
    check("forgetting a tab's model falls back to the process default",
          sessionModelConfig(s1).actorModel == "model-C",
          sessionModelConfig(s1).actorModel)
finally
    closeSession!(s1)
    closeSession!(s2)
end

println()
if isempty(failures)
    println("PER_TAB_MODEL_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
