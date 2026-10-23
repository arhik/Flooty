# compactionSemanticProbe.jl — compaction carries objective + milestones.
using Flooty
using FlootyStreams: OllamaMessage

failures = String[]
function check(name, ok, detail = "")
    println(ok ? "PASS  " : "FAIL  ", name, isempty(detail) ? "" : "  [" * string(detail) * "]")
    ok || push!(failures, name)
end

msgs = OllamaMessage[
    OllamaMessage(role = "system", content = "SYSTEM"),
    OllamaMessage(role = "user", content = "TASK: port ShadowTerm to a Julia package"),
    OllamaMessage(role = "assistant", content = "{\"action\":\"send\",\"code\":\"cat README.md\"}"),
    OllamaMessage(role = "user", content = "ACTION RESULT: ok\n# ShadowTerm"),
    OllamaMessage(role = "assistant", content = "{\"action\":\"done\",\"summary\":\"surveyed README\"}"),
]
append!(msgs, [OllamaMessage(role = "user", content = "turn $i") for i in 1:30])
removed, kept = Flooty.compactMessages!(msgs; keepLast = 4)
digest = msgs[2].content
check("compaction still creates one digest", removed > 0 && startswith(digest, "[compacted]"))
check("…carries the OBJECTIVE", occursin("OBJECTIVE: TASK: port ShadowTerm", digest), digest)
check("…carries milestone status", occursin("MILESTONES:", digest) &&
      occursin("[ok] ran: send: cat README.md", digest) && occursin("[done] surveyed README", digest))
check("…carries current status and next step",
      occursin("CURRENT STATUS: done", digest) && occursin("NEXT STEP:", digest))
check("…keeps recent messages verbatim", msgs[end].content == "turn 30" && kept == 6,
      (kept, msgs[end].content))
println()
if isempty(failures)
    println("COMPACTION_SEMANTIC_PROBE_OK")
else
    println("FAILED: ", join(failures, ", ")); exit(1)
end
