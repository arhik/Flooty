# sshProbe.jl — debug why SSH Ollama models don't appear in the picker.
#
# Run: julia --startup-file=no --project=. test/sshProbe.jl  (no window)
using Flooty
using Flooty: registerSshOllamaRemote!, listSshOllamaModels, SSH_OLLAMA_REMOTES,
              SSH_OLLAMA_PROVIDERS, KNOWN_PROVIDERS, resolveProviderForModel,
              stripProviderPrefix, agentModelGroups, providerGroups,
              availableAgentModels, refreshProviderGroups!

remote = "169.254.244.207"

println("=== 1. Register SSH remote ===")
spec = registerSshOllamaRemote!(remote)
println("ProviderSpec: ", spec)
println("SSH_OLLAMA_REMOTES: ", collect(SSH_OLLAMA_REMOTES))
println("SSH_OLLAMA_PROVIDERS keys: ", collect(keys(SSH_OLLAMA_PROVIDERS)))

println("\n=== 2. ListSSH Ollama models (direct call) ===")
models = listSshOllamaModels(remote; refresh = true)
println("Models from listSshOllamaModels: ", models)

println("\n=== 3. resolveProviderForModel on each model ===")
for m in models
    s = resolveProviderForModel(m)
    println("  $m -> spec: ", s === nothing ? "NOTHING" : s.name)
    println("    stripped: ", stripProviderPrefix(m))
end

println("\n=== 4. providerGroups (refresh=true) ===")
# The async won't complete immediately, so we wait for it.
refreshProviderGroups!()
println("Waiting 3s for async refresh...")
sleep(3.0)
groups = providerGroups()
println("Provider groups: ", groups)

println("\n=== 5. availableAgentModels ===")
avail = availableAgentModels()
println("Available models: ", avail)

println("\n=== 6. agentModelGroups ===")
g = agentModelGroups()
println("local_models: ", g.local_models)
println("peer_models: ", g.peer_models)
println("providers: ", g.providers)

println("\n=== 7. Check if SSH models in local_models ===")
ssh_models = filter(m -> startswith(m, "ssh:"), g.local_models)
println("SSH models in local_models: ", ssh_models)

println("\n=== 8. Check if SSH models in providers ===")
for pg in g.providers
    println("  ProviderGroup: name='", pg.name, "' models=", pg.models)
end

println("\nDONE")
