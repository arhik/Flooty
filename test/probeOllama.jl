# probeOllama.jl — one REAL round-trip against the Poolside AI API.
# Skips gracefully (exit 0, SKIP notice) when the server is down so CI-style
# runs stay green on machines without a valid API key / network.
#
# Run: julia --startup-file=no --project=. test/probeOllama.jl
using Flooty
using FlootyStreams: OllamaMessage

cfg = defaultAgentModelConfig()
println("baseUrl=", cfg.baseUrl, " actor=", cfg.actorModel,
        " monitor=", cfg.monitorModel)

ollamaReachable(; baseUrl = cfg.baseUrl, apiKey = cfg.apiKey) || begin
    println("API_DOWN — SKIPPING (probe passes by design)")
    exit(0)
end

println("API up; asking ", cfg.actorModel, " for one JSON action ...")
reply = chatCompletion(cfg.baseUrl, cfg.actorModel, OllamaMessage[
    OllamaMessage(role = "system",
                  content = "Reply with EXACTLY one JSON object and nothing else."),
    OllamaMessage(role = "user",
                  content = "Produce {\"action\":\"done\",\"summary\":\"<one short sentence>\"} " *
                            "where the sentence mentions julia."),
    ]; apiKey = cfg.apiKey)
clean = Flooty.stripThinking(reply)
println("raw: ", first(reply, 200))
println("clean: ", clean)
obj = Flooty.extractActionJson(clean)
obj === nothing && (println("PROBE_OLLAMA_FAILED: no JSON in reply"); exit(1))
Symbol(get(obj, :action, "")) == :done ||
    (println("PROBE_OLLAMA_FAILED: wrong action"); exit(1))
occursin("julia", lowercase(String(get(obj, :summary, "")))) ||
    (println("PROBE_OLLAMA_FAILED: summary missing 'julia'"); exit(1))

# Thinking-model path: if monitor uses a different model, it must still
# yield clean JSON after stripThinking.
if cfg.monitorModel != cfg.actorModel
    println("asking ", cfg.monitorModel, " (thinking model) ...")
    reply2 = chatCompletion(cfg.baseUrl, cfg.monitorModel, OllamaMessage[
        OllamaMessage(role = "system",
                      content = "Reply with EXACTLY one JSON object and nothing else."),
        OllamaMessage(role = "user",
                      content = "{\"decision\":\"insight\",\"title\":\"t\",\"body\":\"b\"} is the " *
                                "required shape. Emit it verbatim."),
    ]; apiKey = cfg.apiKey)
    obj2 = Flooty.extractActionJson(
        Flooty.stripThinking(reply2))
    obj2 === nothing &&
        (println("PROBE_OLLAMA_FAILED: monitor reply unparseable"); exit(1))
    println("monitor decision: ", get(obj2, :decision, "?"))
end

println("PROBE_OLLAMA_OK")
exit(0)
