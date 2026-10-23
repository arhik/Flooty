# providerCallProbe.jl — a model that answers in a PROVIDER's tool-call syntax must
# still drive the terminal, and must never show that syntax in the chat.
#
# Reported symptom: the chat showed
#
#     <rfl:parameter name="code">names(WGPUCompute, all=true)</rfl:parameter>
#
# and the terminal did nothing — the loop found no JSON action, called the reply
# "unparseable" and stopped. Beam writes its calls this way when it decides to use a
# tool, so both halves matter: TRANSLATE it into our action (so the command runs) and
# HIDE the markup from the user (so the transcript stays readable).
#
# Run: julia --startup-file=no --project=. test/providerCallProbe.jl
import Flooty
import FlootyPTYLayer
using Flooty
using FlootyPTYLayer: startReplSession, closeSession!

failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = isempty(detail) ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end

REPLY = """
Let me look that up.

<rfl:parameter name="code">PROVIDER_MARKER = 6 * 7</rfl:parameter>

Then I will report the value.
"""

println("--- translation (no PTY)")
params = Flooty.providerParameters(REPLY)
check("parameters are extracted from the markup",
      params == [("code", "PROVIDER_MARKER = 6 * 7")], params)
check("the markup is stripped for display",
      !occursin("rfl:", Flooty.stripProviderMarkup(REPLY)) &&
      occursin("Let me look that up.", Flooty.stripProviderMarkup(REPLY)),
      repr(Flooty.stripProviderMarkup(REPLY)))
action = Flooty.extractProviderAction(REPLY)
check("a `code` parameter becomes our send action",
      action !== nothing && action["action"] == "send" &&
      action["code"] == "PROVIDER_MARKER = 6 * 7", action)
check("`keys` becomes a type action",
      (a = Flooty.extractProviderAction("<parameter name=\"keys\">\e[B</parameter>");
       a !== nothing && a["action"] == "type"), "")
check("`seconds` becomes a wait, and `summary` a done",
      (w = Flooty.extractProviderAction("<rfl:parameter name=\"seconds\">3</rfl:parameter>");
       d = Flooty.extractProviderAction("<rfl:parameter name=\"summary\">ok</rfl:parameter>");
       w !== nothing && w["action"] == "wait" && d !== nothing && d["action"] == "done"), "")
check("prose with no markup yields no action",
      Flooty.extractProviderAction("just talking") === nothing)
check("our JSON protocol is untouched",
      Flooty.extractActionJson("{\"action\":\"send\",\"code\":\"pwd\"}") !== nothing)

println()
println("--- end to end: the scripted reply drives a real REPL")
sess = startReplSession(`julia --startup-file=no -q`)
try
    script = [REPLY, "{\"action\":\"done\",\"summary\":\"marker written\"}"]
    completeFn = _ -> isempty(script) ? "{\"action\":\"done\",\"summary\":\"exhausted\"}" :
                                        popfirst!(script)
    r = runTerminalAgent!(sess, "set the provider marker"; completeFn = completeFn,
                          maxTurns = 6)
    transcript = join(r.transcript, "\n")
    check("the run finished (not 'unparseable')", r.ok, r.summary)
    check("the native call was translated, and said so",
          occursin("native tool call translated to send", transcript),
          first(transcript, 120))
    check("the command really ran in the terminal",
          occursin("PROVIDER_MARKER", transcript) &&
          !occursin("unparseable model output: <rfl", transcript),
          first(last(r.transcript, 2), 120))
    conv = Flooty.conversationFor(sess)
    stored = join(Flooty.conversationTranscript(conv), "\n")
    check("the chat transcript has the prose, not the markup",
          !occursin("rfl:parameter", stored) && occursin("look that up", stored),
          first(stored, 160))
    # The loop's own record of the outcome is the proof it really ran (the send is
    # only "logged" before execution; the ACTION RESULT line comes after it).
    check("the translated command's ACTION RESULT is ok",
          occursin(r"-> ok:", transcript), first(transcript[end-200:end], 160))
catch e
    println("PROBE_FAILED: ", sprint(showerror, e))
    push!(failures, "probe error")
finally
    closeSession!(sess)
end

println()
if isempty(failures)
    println("PROVIDER_CALL_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
