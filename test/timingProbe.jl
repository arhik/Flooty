# timingProbe.jl — measure how long the async provider refresh takes.
using Flooty
using Flooty: registerSshOllamaRemote!, agentModelState, refreshProviderGroups!,
              providerGroups, availableAgentModels
using Flooty.FlootyPTYLayer: jsonAgentModelState
using JSON

remote = "169.254.244.207"
registerSshOllamaRemote!(remote)

function measureRefresh()
    t0 = time()
    refreshProviderGroups!()
    # Poll every 100ms
    for i in 1:50
        sleep(0.1)
        elapsed = round((time() - t0) * 1000)
        g = providerGroups()
        sshGroups = filter(gr -> startswith(gr.name, "Ollama (ssh:"), g)
        if !isempty(sshGroups)
println("  Async refresh completed after ", elapsed, "ms")
            println("  SSH models: ", length(sshGroups[1].models))
            return elapsed, length(sshGroups[1].models)
        end
    end
    println("  Async refresh NOT completed after 5000ms")
    return 5000, 0
end

println("=== Measure full refresh time ===")
elapsed, nssh = measureRefresh()

# Clear the cache to simulate the first-call scenario
println("\n=== Simulate first flootyModels call (empty cache) ===")
state1 = agentModelState("")
ssh1 = filter(m -> startswith(m, "ssh:"), state1.available)
println("  available=$(length(state1.available)), ssh=$(length(ssh1))")

sleep(0.7)
println("\n=== Simulate retry at 700ms ===")
state2 = agentModelState("")
ssh2 = filter(m -> startswith(m, "ssh:"), state2.available)
println("  available=$(length(state2.available)), ssh=$(length(ssh2))")
println("  providers count=$(length(state2.providers))")

# JSON serialization check
println("\n=== JSON serialization ===")
jsonStr = jsonAgentModelState(state2)
try
    parsed = JSON.parse(jsonStr)
    println("  Parse: OK")
    println("  providers in JSON: ", parsed["providers"])
catch e
    println("  Parse ERROR: ", e)
    println("  First 500 chars: ", first(jsonStr, 500))
end

println("\n=== Key finding ===")
println("  Full refresh takes ~\$(elapsed)ms")
println("  JS retry interval is 700ms, max 6 retries = 4200ms")
if elapsed > 4200
    println("  >>> Refresh takes longer than JS retry window!")
else
    println("  >>> Refresh should complete within JS retry window")
end
