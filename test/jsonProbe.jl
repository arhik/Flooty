# jsonProbe.jl — verify JSON serialization of provider groups
using Flooty
using Flooty: registerSshOllamaRemote!, listSshOllamaModels, AgentModelConfig,
              _buildKnownProviders, KNOWN_PROVIDERS, PROVIDER_GROUPS_CACHE,
              PROVIDER_GROUPS_AT, PROVIDER_GROUPS_LOCK, PROVIDER_GROUPS_TTL,
              refreshProviderGroups!, providerGroups, availableAgentModels,
              agentModelGroups, agentModelState, _providerGroupJson
using FlootyPTYLayer: jsonAgentModelState, _providerGroupJson as _pgj
using JSON

remote = "169.254.244.207"
registerSshOllamaRemote!(remote)

# Build a fake state with providers to test JSON serialization
state = (current = "test", monitor = "test",
         available = ["ssh:169.254.244.207:laya:latest", "poolside/laguna-s-2.1"],
         local_models = ["ssh:169.254.244.207:laya:latest", "poolside/laguna-s-2.1"],
         peer_models = String[],
         providers = [Flooty.ProviderGroup("Ollama (ssh:169.254.244.207)",
                   ["ssh:169.254.244.207:laya:latest"]),
                 Flooty.ProviderGroup("PoolSide", ["poolside/laguna-s-2.1"])])

println("=== jsonAgentModelState output ===")
jsonStr = jsonAgentModelState(state)
println(jsonStr)

println("\n=== Try JSON.parse ===")
try
    parsed = JSON.parse(jsonStr)
    println("Parsed OK: ", parsed)
catch e
    println("PARSE ERROR: ", e)
end

println("\n=== _providerGroupJson output ===")
progs = _pgj(state.providers)
println("progs = ", repr(progs))

println("\n=== Manual test: build a simple provider group and serialize ===")
g = Flooty.ProviderGroup("Test", ["model1", "model2"])
progs2 = _pgj([g])
println("progs2 = ", repr(progs2))

# Wrap in a full JSON and try to parse
fullJson = "{\"success\":true,\"current\":\"\",\"monitor\":\"\",\"available\":[]*" * progs2 * "}"
println("fullJson = ", fullJson)
try
    parsed = JSON.parse(fullJson)
    println("Parsed OK: ", parsed)
catch e
    println("PARSE ERROR: ", e)
end
