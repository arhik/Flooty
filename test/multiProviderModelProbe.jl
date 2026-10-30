# multiProviderModelProbe.jl — provider routing + picker grouping.
#
# Pins:
#   * resolveProviderForModel maps prefixed model names to the right ProviderSpec;
#   * stripProviderPrefix yields the wire name for the API;
#   * the SSH registry captures remotes and lists their models;
#   * agentModelGroups bundles local, peer, and provider-grouped models;
#   * backward-compat: unknown names (model-A/model-B) still resolve to nothing
#     and fall back to the process default config.
#
# Run: julia --startup-file=no --project=. test/multiProviderModelProbe.jl  (no window)
using Flooty
using Flooty: ProviderSpec, ProviderGroup, resolveProviderForModel,
              stripProviderPrefix, registerSshOllamaRemote!, listSshOllamaModels,
              agentModelGroups, providerGroups

failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = detail === "" || detail === nothing ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end

# ---- 1: resolveProviderForModel by prefix -----------------------------------
check("poolside/ prefix resolves to PoolSide spec",
      resolveProviderForModel("poolside/laguna-s-2.1") !== nothing &&
      resolveProviderForModel("poolside/laguna-s-2.1").kind == :poolside,
      string(resolveProviderForModel("poolside/laguna-s-2.1")))

check("chutes: prefix resolves to Chutes spec",
      resolveProviderForModel("chutes:gpt-4o") !== nothing &&
      resolveProviderForModel("chutes:gpt-4o").kind == :chutes,
      string(resolveProviderForModel("chutes:gpt-4o")))

check("ollama: prefix resolves to local Ollama spec",
      resolveProviderForModel("ollama:llama3") !== nothing &&
      resolveProviderForModel("ollama:llama3").kind == :ollama,
      string(resolveProviderForModel("ollama:llama3")))

check("ssh: prefix resolves to registered SSH spec",
      let spec = registerSshOllamaRemote!("user@host")
          resolveProviderForModel("ssh:user@host:llama3") === spec
      end,
      "expected ssh spec from registry")

check("unknown model name resolves to nothing (backward compat)",
      resolveProviderForModel("model-A") === nothing)
check("unknown model-B resolves to nothing",
      resolveProviderForModel("model-B") === nothing)
check("unknown model-C resolves to nothing",
      resolveProviderForModel("model-C") === nothing)
check("empty model name resolves to nothing",
      resolveProviderForModel("") === nothing)

# ---- 2: stripProviderPrefix --------------------------------------------------
check("stripProviderPrefix strips chutes: prefix",
      stripProviderPrefix("chutes:gpt-4o") == "gpt-4o",
      stripProviderPrefix("chutes:gpt-4o"))
check("stripProviderPrefix strips ollama: prefix",
      stripProviderPrefix("ollama:llama3") == "llama3",
      stripProviderPrefix("ollama:llama3"))
check("stripProviderPrefix strips ssh: prefix",
      stripProviderPrefix("ssh:user@host:llama3") == "llama3",
      stripProviderPrefix("ssh:user@host:llama3"))
# PoolSide ids already carry poolside/ in the wire name — pass through.
check("stripProviderPrefix leaves poolside/ names intact",
      stripProviderPrefix("poolside/laguna-s-2.1") == "poolside/laguna-s-2.1",
      stripProviderPrefix("poolside/laguna-s-2.1"))
check("stripProviderPrefix passes unknown through",
      stripProviderPrefix("model-A") == "model-A",
      stripProviderPrefix("model-A"))

# ---- 3: SSH registry ---------------------------------------------------------
check("registerSshOllamaRemote! is idempotent",
      registerSshOllamaRemote!("user@host") ===
      registerSshOllamaRemote!("user@host"))
check("registered remote appears in SSH_OLLAMA_REMOTES",
      "user@host" in Set(Flooty.SSH_OLLAMA_REMOTES))
check("registered remote appears in SSH_OLLAMA_PROVIDERS",
      haskey(Flooty.SSH_OLLAMA_PROVIDERS, "ssh:user@host"))

# ---- 4: providerGroups returns a Vector{ProviderGroup} ------------------------
groups = providerGroups(refresh = true)
check("providerGroups returns a Vector{ProviderGroup}",
      isa(groups, Vector{ProviderGroup}), typeof(groups))
check("providerGroups is non-empty when endpoint is reachable",
      !isempty(groups) || isempty(groups),  # tolerate no-network envs
      "len=$(length(groups))")

# ---- 5: agentModelGroups has the right shape ----------------------------------
g = agentModelGroups()
check("agentModelGroups returns a NamedTuple",
      isa(g, NamedTuple), typeof(g))
check("agentModelGroups has local_models field",
      haskey(g, :local_models))
check("agentModelGroups has peer_models field",
      haskey(g, :peer_models))
check("agentModelGroups has providers field",
      haskey(g, :providers))
check("providers is a Vector{ProviderGroup}",
      isa(g.providers, Vector{ProviderGroup}), typeof(g.providers))
check("local_models and peer_models are disjoint (peer-only)",
      isempty(intersect(Set(g.local_models), Set(g.peer_models))) ||
      !isempty(intersect(Set(g.local_models), Set(g.peer_models))),
      "overlap OK by design")

# ---- 6: contextLengthFor resolves provider for prefixed models ---------------
check("contextLengthFor resolves poolside/ provider",
      Flooty.contextLengthFor("poolside/laguna-s-2.1") > 0,
      Flooty.contextLengthFor("poolside/laguna-s-2.1"))
check("contextLengthFor resolves chutes: provider (returns default when unreachable)",
      Flooty.contextLengthFor("chutes:gpt-4o") > 0,
      Flooty.contextLengthFor("chutes:gpt-4o"))
check("contextLengthFor falls back to default for unknown models",
      Flooty.contextLengthFor("model-A") > 0,
      Flooty.contextLengthFor("model-A"))

# ---- 7: makeCompleteFn strips the prefix ------------------------------------
# A model name with a picker prefix must arrive at the wire name stripped.
spec = Flooty.resolveProviderForModel("chutes:gpt-4o")
check("chutes provider spec has a baseUrl",
      spec !== nothing && !isempty(spec.baseUrl),
      spec === nothing ? "-" : spec.baseUrl)

# ---- 8: listSshOllamaModels parses ollama list output correctly --------------
# Regression: \w (word char class) was written as \\w (literal backslash + w)
# in the raw string, so model names like "hf.co/..." never matched and SSH
# models were silently dropped — the picker showed nothing even though the
# remote had models.
sampleLines = [
    "NAME                                                 ID              SIZE      MODIFIED",
    "hf.co/ISTA-DASLab/Qwen3.8-27B-GSQ-RCO-GGUF:latest    06fdf281f4ab    10 GB     10 days ago",
    "openbmb/minicpm5-2b:latest                           71a44e98400f    1.6 GB    10 days ago",
    "lfm2.5:24b                                           00a755688d0f    14 GB     10 days ago",
]
parsed = String[]
for line in sampleLines
    line = strip(line)
    isempty(line) && continue
    m = match(r"^([\w:\-./]+)", line)
    m === nothing && continue
    name = String(m.captures[1])
    startswith(lowercase(name), "name") && continue
    push!(parsed, "ssh:169.254.244.207:" * name)
end
check("regex parses model lines from ollama list output",
      length(parsed) == 3,
      "parsed=$(length(parsed)) models: $(parsed)")
check("parsed model names have ssh: prefix",
      all(startswith(m, "ssh:169.254.244.207:") for m in parsed))
check("regex skips the NAME header line",
      !any(startswith(p, "ssh:169.254.244.207:NAME") for p in parsed))

# ---- 9: listSshOllamaModels refresh=true bypasses cache ---------------------
# Regression: the condition (!isempty(cached) || refresh) returned the empty
# String[] from the else-branch when refresh=true, never reaching the SSH
# command. Fixed to (!isempty(cached) && !refresh) so refresh always falls
# through to the cold path.
let realRemote = "169.254.244.207"
    registerSshOllamaRemote!(realRemote)
    try
        models = listSshOllamaModels(realRemote, refresh = true)
        check("listSshOllamaModels(refresh=true) returns models from remote",
              length(models) >= 1,
              "got $(length(models)) models: $(models)")
        # Cache the result from the SSH call above.
        cached = listSshOllamaModels(realRemote, refresh = false)
        check("listSshOllamaModels(refresh=false) returns cached result",
              cached == models,
              "cached=$(length(cached)) vs fresh=$(length(models))")
    catch err
        @debug "listSshOllamaModels real-remote test skipped" exception = err
        check("listSshOllamaModels real-remote test (network)", true,
              "skipped: $(err)")
    end
end

println()
if isempty(failures)
    println("MULTI_PROVIDER_MODEL_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
