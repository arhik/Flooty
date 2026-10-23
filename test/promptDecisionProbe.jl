# promptDecisionProbe.jl — decision-model PS2 confidence evolves with time.
#
# Run: julia --startup-file=no --project=. test/promptDecisionProbe.jl
using Flooty

failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = detail === "" || detail === nothing ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end

calls = Ref(0)
PROMPT_DECISION_STUB[] = (; kwargs...) -> (calls[] += 1;
    (ps2 = 0.7, running = 0.1, idle = 0.2))
tail = "heredoc> " * string(time_ns())
a = promptStatusDecision(tail = tail, kind = :unknown, at_prompt = false,
                         elapsed_s = 3.0, grace_s = 3.0, tau_s = 5.0)
b = promptStatusDecision(tail = tail, kind = :unknown, at_prompt = false,
                         elapsed_s = 5.0, grace_s = 3.0, tau_s = 5.0)
c = promptStatusDecision(tail = tail, kind = :unknown, at_prompt = false,
                         elapsed_s = 15.0, grace_s = 3.0, tau_s = 5.0)
check("decision model called", calls[] >= 2, calls[])
check("hazard rises with elapsed time", a.hazard < b.hazard < c.hazard,
      (a.hazard, b.hazard, c.hazard))
check("posterior PS2 confidence rises with time",
      a.ps2_posterior < b.ps2_posterior < c.ps2_posterior,
      (a.ps2_posterior, b.ps2_posterior, c.ps2_posterior))
check("…crossing a useful threshold by 15s", c.ps2_posterior > 0.8,
      c.ps2_posterior)
# Same elapsed bucket is cached: confidence does not change without time.
before = calls[]
_ = promptStatusDecision(tail = tail, kind = :unknown, at_prompt = false,
                         elapsed_s = 15.2, grace_s = 3.0, tau_s = 5.0)
check("same time bucket is cached", calls[] == before, calls[])

println()
if isempty(failures)
    println("PROMPT_DECISION_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
