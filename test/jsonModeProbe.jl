# jsonModeProbe.jl — action/monitor completions request JSON at the wire level.
using Flooty
import FlootyStreams
using FlootyStreams: JSON3

failures = String[]
function check(name, ok, detail = "")
    println(ok ? "PASS  " : "FAIL  ", name, isempty(detail) ? "" : "  [" * string(detail) * "]")
    ok || push!(failures, name)
end

req = FlootyStreams.ChatRequest(
    model = "fake",
    messages = [FlootyStreams.OllamaMessage(role = "user", content = "go")],
    stream = false,
    format = "json",
)
wire = JSON3.write(req)
check("ChatRequest serializes Ollama's format=json", occursin("\"format\":\"json\"", wire), wire)
println()
if isempty(failures)
    println("JSON_MODE_PROBE_OK")
else
    println("FAILED: ", join(failures, ", ")); exit(1)
end
