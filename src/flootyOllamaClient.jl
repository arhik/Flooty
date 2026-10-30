# flootyOllamaClient.jl — inference client for the Flooty agent.
#
# Talks an OpenAI-compatible inference endpoint (default: Poolside AI)
# (/v1/chat/completions, non-streaming). Models and endpoint are
# user-configurable via env vars with a remote default:
#   base URL = https://inference.poolside.ai/v1
#   actor    model = configurable via FLOOTY_ACTOR_MODEL
#   monitor  model = configurable via FLOOTY_MONITOR_MODEL
#   api key       = configurable via FLOOTY_API_KEY (falls back to POOLSIDE_API_KEY)
#
# Everything downstream takes an injectable `completeFn(messages)::String`
# so probes run deterministically WITHOUT a live endpoint; these helpers
# are just the default implementation of that seam.
#
using HTTP
using BufferedStreams: BufferedInputStream
import FlootyStreams
|
"""
Config for remote agent models. Construct via `defaultAgentModelConfig()` so
env overrides (`FLOOTY_INFERENCE_URL`, `FLOOTY_ACTOR_MODEL`,
`FLOOTY_MONITOR_MODEL`, `FLOOTY_API_KEY` or `POOLSIDE_API_KEY`) are honored;
fields stay mutable for `configureAgent!`.
"""
Base.@kwdef mutable struct AgentModelConfig
    baseUrl::String = "https://inference.poolside.ai/v1"
    actorModel::String = "poolside/laguna-s-2.1"
    monitorModel::String = "poolside/laguna-s-2.1"
    apiKey::String = ""
    # Which JSON field carries an assistant turn's REASONING on the REQUEST side.
    # Providers disagree (DeepSeek/Poolside/OpenRouter `reasoning_content`,
    # Ollama `thinking`); "" disables it. The response side already reads all
    # three back — see `providerReasoning` — so the request side is the only
    # half that needs configuring.
    reasoningField::String = "reasoning_content"
    # Output budget per completion. Thinking models spend tokens on reasoning
    # BEFORE the JSON action; a small default truncated the action mid-string
    # (ShadowTerm run: five "unparseable" turns in a row, then a 3-strike stop).
    # Laguna S 2.1's theoretical max output is 131072, but the PoolSide API
    # currently enforces max_tokens <= 32768 (free developer tier; documented
    # range is 1–262144). 32768 is the largest value the live endpoint accepts.
    maxOutputTokens::Int = 32768
    # P2P: when true, route completions through FlootyCompute peers instead of
    # talking to a remote endpoint over HTTP.
    p2p::Bool = false
    discoveryTopic::String = "flooty"
    bootstrapPeers::Vector{String} = String[]
    p2pPort::Int = 0
    p2pApiPort::Int = 0
end
const DEFAULT_BASE_URL = "https://inference.poolside.ai/v1"
const DEFAULT_ACTOR_MODEL = "poolside/laguna-s-2.1"
const DEFAULT_MONITOR_MODEL = "poolside/laguna-s-2.1"
const DEFAULT_API_KEY = ""
const DEFAULT_REASONING_FIELD = "reasoning_content"
const DEFAULT_MAX_OUTPUT_TOKENS = 32768

# ---- multi-provider model aggregation ---------------------------------------
# Flooty treats PoolSide as just another named provider (like Chutes) so the
# picker can list models from ALL known endpoints under <optgroup> labels and
# route a chosen model to the right baseUrl/apiKey/reasoningField at selection
# time. SSH Ollama hosts join the same registry when a terminal with
# `kind=:ssh` is created.

"""
    ProviderSpec

Static description of a model provider: its display name (for the picker's
`<optgroup>` label), the API endpoint (`baseUrl`), the key it needs
(`apiKey`), the prefix that IDENTIFIES models belonging to it in the picker
(`prefix` — e.g. `"chutes:"`, `"ssh:user@host:"`; empty for PoolSide whose
model ids already start with `poolside/`), and the JSON field that carries
reasoning on the REQUEST side (`reasoningField`). `kind` and `remote` drive
routing: `:poolside/:chutes/:ollama` use HTTP; `:ssh` runs `ollama` over an
SSH session and the local Ollama native path kicks in when the model was
listed from a `:11434` endpoint.
"""
struct ProviderSpec
    name::String           # display name for the picker group
    baseUrl::String        # API endpoint URL (root or /v1)
    apiKey::String         # bearer token for this provider
    prefix::String         # picker-side prefix that identifies this provider
    defaultModel::String   # provider default if any
    reasoningField::String # request-side reasoning field (e.g. "reasoning_content", "thinking", "")
    contextLength::Int     # default context window for models from this provider
    kind::Symbol         # :poolside, :chutes, :ollama, :ssh
    remote::String         # for SSH: "user@host", empty otherwise
end

"""
    ProviderGroup

A display row in the picker: a provider (or peer) name plus the model names it
offers. The JS builds one `<optgroup>` per group, falling back to flat
`<option>` rendering when the list is empty.
 """
struct ProviderGroup
    name::String
    models::Vector{String}
end

# Dynamic registry: `Symbol -> ProviderSpec` for the static providers
# (PoolSide, Chutes, local Ollama) and `ssh:remote -> ProviderSpec` for SSH
# hosts discovered at runtime.
const KNOWN_PROVIDERS = Dict{Symbol,ProviderSpec}()
const KNOWN_PROVIDERS_LOCK = ReentrantLock()
const SSH_OLLAMA_PROVIDERS = Dict{String,ProviderSpec}()

# SSH Ollama remotes registered by the session-terminal hook.
const SSH_OLLAMA_REMOTES = Set{String}()
const SSH_REMOTES_LOCK = ReentrantLock()

# TTL caches for multi-provider discovery.
const PROVIDER_GROUPS_CACHE = Ref{Vector{ProviderGroup}}(ProviderGroup[])
const PROVIDER_GROUPS_AT = Ref(0.0)
const PROVIDER_GROUPS_LOCK = ReentrantLock()
const PROVIDER_GROUPS_TTL = 60.0

# TTL cache for SSH Ollama model lists (so we don't re-ssh on every picker open).
const SSH_OLLAMA_MODELS_CACHE = Dict{String,Vector{String}}()
const SSH_OLLAMA_MODELS_AT = Dict{String,Float64}()
const SSH_OLLAMA_MODELS_LOCK = ReentrantLock()

"""
    registerSshOllamaRemote!(remote) -> ProviderSpec

Register an SSH target (e.g. "user@host") as an Ollama provider and return
its `ProviderSpec`. Called from Flooty's session-terminal hook when
`kind=:ssh`. Idempotent: registering the same remote twice returns the
existing spec without re-running discovery.
 """
function registerSshOllamaRemote!(remote::AbstractString)
    r = String(remote)
    isempty(r) && return nothing
    lock(SSH_REMOTES_LOCK) do
        push!(SSH_OLLAMA_REMOTES, r)
        key = "ssh:" * r
        if !haskey(SSH_OLLAMA_PROVIDERS, key)
            # The baseUrl points at the user's machine on the standard Ollama
            # port; port-forwarding (ssh -L) or an SSH proxy must carry traffic.
            SSH_OLLAMA_PROVIDERS[key] = ProviderSpec(
                "Ollama (ssh:$(r))", "http://127.0.0.1:11434/v1", "",
                key * ":", "", "thinking", DEFAULT_CONTEXT_LENGTH, :ssh, r)
        end
        return SSH_OLLAMA_PROVIDERS[key]
    end
end

"""
    listSshOllamaModels(remote; refresh=false) -> Vector{String}

Model names from `ssh user@host ollama list`, cached with a TTL. Each name is
prefixed with `ssh:user@host:` so the picker groups it under the right remote
and `resolveProviderForModel` can route it.
 """
function listSshOllamaModels(remote::AbstractString; refresh::Bool = false)
    r = String(remote)
    isempty(r) && return String[]
    cached = lock(SSH_OLLAMA_MODELS_LOCK) do
        if !refresh && haskey(SSH_OLLAMA_MODELS_CACHE, r)
            age = time() - get(SSH_OLLAMA_MODELS_AT, r, 0.0)
            age < PROVIDER_GROUPS_TTL ? copy(SSH_OLLAMA_MODELS_CACHE[r]) : String[]
        else
            String[]
        end
    end
    (!isempty(cached) && !refresh) && return cached
    # Cold path: shell out to ssh. Runs off the UI thread.
    out = String[]
    try
        cmd = `ssh -o ConnectTimeout=5 -o BatchMode=yes $r ollama list`
        raw = read(cmd, String)
        for line in split(raw, '\n')
            line = strip(line)
            isempty(line) && continue
            m = match(r"^([\w:\-./]+)", line)
            m === nothing && continue
            name = String(m.captures[1])
            # ollama list header line looks like "NAME ID SIZE MODIFIED"
            startswith(lowercase(name), "name") && continue
            push!(out, "ssh:" * r * ":" * name)
        end
    catch err
        @debug "listSshOllamaModels failed" remote = r exception = err
    end
    lock(SSH_OLLAMA_MODELS_LOCK) do
        SSH_OLLAMA_MODELS_CACHE[r] = out
        SSH_OLLAMA_MODELS_AT[r] = time()
    end
    return out
end

"""
    _buildKnownProviders() -> Dict{Symbol,ProviderSpec}

Construct the static provider specs from env vars / constants. PoolSide is
the default (DEFAULT_BASE_URL, DEFAULT_REASONING_FIELD, the key fallback
chain). Chutes reads CHUTES_API_TOKEN. Local Ollama defaults to 127.0.0.1:11434.
 """
function _buildKnownProviders()
    d = Dict{Symbol,ProviderSpec}()
    poolsideKey = something(nonempty(get(ENV, "FLOOTY_API_KEY", "")),
                             nonempty(get(ENV, "POOLSIDE_API_KEY", "")),
                             DEFAULT_API_KEY)
    d[:poolside] = ProviderSpec("PoolSide",
        DEFAULT_BASE_URL, poolsideKey, "", DEFAULT_ACTOR_MODEL,
        DEFAULT_REASONING_FIELD, DEFAULT_CONTEXT_LENGTH, :poolside, "")
    chutesKey = something(nonempty(get(ENV, "FLOOTY_API_KEY", "")),
                           nonempty(get(ENV, "CHUTES_API_TOKEN", "")), "")
    d[:chutes] = ProviderSpec("Chutes",
        "https://llm.chutes.ai/v1", chutesKey, "chutes:", "",
        "reasoning_content", DEFAULT_CONTEXT_LENGTH, :chutes, "")
    localUrl = normalizeOllamaUrl(get(ENV, "FLOOTY_OLLAMA_URL", "http://127.0.0.1:11434"))
    localUrl === nothing && (localUrl = "http://127.0.0.1:11434/v1")
    d[:ollama] = ProviderSpec("Ollama (local)",
        localUrl, "", "ollama:", "", "thinking",
        DEFAULT_CONTEXT_LENGTH, :ollama, "")
    return d
end

function defaultAgentModelConfig()
    return AgentModelConfig(
        baseUrl = something(normalizeOllamaUrl(get(ENV, "FLOOTY_INFERENCE_URL", "")),
                            DEFAULT_BASE_URL),
        actorModel = something(nonempty(get(ENV, "FLOOTY_ACTOR_MODEL", "")),
                               DEFAULT_ACTOR_MODEL),
        monitorModel = something(nonempty(get(ENV, "FLOOTY_MONITOR_MODEL", "")),
                                 DEFAULT_MONITOR_MODEL),
        # `FLOOTY_API_KEY` is the generic override; `POOLSIDE_API_KEY` is the
        # provider-specific one — check it second so it acts as a fallback when
        # the generic var is unset.
        apiKey = something(nonempty(get(ENV, "FLOOTY_API_KEY", "")),
                           nonempty(get(ENV, "POOLSIDE_API_KEY", "")),
                           DEFAULT_API_KEY),
        # `FLOOTY_REASONING_FIELD` distinguishes "unset" from "explicitly empty":
        # empty means do not send reasoning at all (strict endpoints).
        reasoningField = haskey(ENV, "FLOOTY_REASONING_FIELD") ?
                         String(ENV["FLOOTY_REASONING_FIELD"]) : DEFAULT_REASONING_FIELD,
        maxOutputTokens = something(tryparse(Int, get(ENV, "FLOOTY_MAX_OUTPUT_TOKENS", "")),
                                   DEFAULT_MAX_OUTPUT_TOKENS),
    )
end
|
nonempty(s::AbstractString) = isempty(strip(s)) ? nothing : String(strip(s))
|
# Accept bare root URLs and ones already ending in /v1; always yield root/v1.
function normalizeOllamaUrl(s::AbstractString)
    s = strip(s)
    isempty(s) && return nothing
    s = String(s)
    endswith(s, "/") && (s = chop(s))
    endswith(s, "/v1") || (s *= "/v1")
    return s
end

"""
    requestMessages(messages::Vector{OllamaMessage};
                    reasoningField = DEFAULT_REASONING_FIELD) :: Vector{Dict{String,Any}}

The OpenAI-compatible WIRE form of an agent conversation. Three details are
load-bearing:

  * `content` is ALWAYS a string. A reply that was nothing but provider-side
    reasoning strips to empty content (`stripThinking`), and
    `StructTypes.omitempties(::Type{OllamaMessage})` then DROPS the field —
    the endpoint reads a nil content and answers
    `400 invalid message content type: <nil>`, which kills the run on the turn
    right after the model thinks without acting (and the pane is handed back to
    the user before any work happens).
  * REASONING IS SERIALIZED, under the provider's own field name (`reasoning`,
    `reasoning_content`, `thinking` — `reasoningField`, disabled by ""). An
    assistant turn's `thinking` is its own channel, so it travels as that field
    and never as prose inside `content` (re-feeding reasoning as text inflates
    the prompt and biases the next reply toward monologue). Verified against the
    live endpoint: all three names are accepted, none is required.
  * the internal `_type` tag stays OFF the wire: it is bookkeeping.

`tool_calls`/`tool_name`/`tool_call_id` are forwarded when present so native
tool-call turns survive the round trip.
"""
function requestMessages(messages::Vector{OllamaMessage};
                         reasoningField::AbstractString = DEFAULT_REASONING_FIELD
                         )::Vector{Dict{String,Any}}
    thinkKey = String(reasoningField)
    wire = Vector{Dict{String,Any}}(undef, length(messages))
    for (i, m) in enumerate(messages)
        d = Dict{String,Any}(
            "role" => String(m.role),
            "content" => (m.content === nothing ? "" : String(m.content)),
        )
        if !isempty(thinkKey) && m.thinking !== nothing && !isempty(strip(m.thinking))
            d[thinkKey] = String(m.thinking)
        end
        m.tool_calls === nothing || (d["tool_calls"] = m.tool_calls)
        m.tool_name === nothing || (d["tool_name"] = m.tool_name)
        m.tool_call_id === nothing || (d["tool_call_id"] = m.tool_call_id)
        wire[i] = d
    end
    return wire
end

"""
    chatCompletion(baseUrl, model, messages::Vector{OllamaMessage}; temperature = 0.2,
                   apiKey = "", timeoutS = 120.0) :: String

One non-streaming chat round-trip against an OpenAI-compatible endpoint.
If `apiKey` is non-empty, an `Authorization: Bearer <key>` header is sent.
Messages go through `requestMessages` (never `JSON.json` of the structs, which
omits an empty `content` and produces an invalid request).
Returns the assistant message content string; throws on HTTP/transport
failure so callers decide retry policy.
"""
function chatCompletion(baseUrl::AbstractString, model::AbstractString,
                        messages::Vector{OllamaMessage};
                        temperature::Real = 0.2, apiKey::AbstractString = "",
                        timeoutS::Real = 120.0,
                        reasoningField::AbstractString = DEFAULT_REASONING_FIELD,
                        maxTokens::Integer = DEFAULT_MAX_OUTPUT_TOKENS, jsonMode::Bool = false)
    # P2P mode: route through FlootyCompute peers instead of HTTP.
    if AGENT_CONFIG[].p2p
        return p2pChatCompletion(model, messages; maxTokens = maxTokens, jsonMode = jsonMode)
    end
    # llamacpp models: route through FlootyStreams' Ollama provider (FlootyHub
    # is Ollama-compatible), so streaming/thinking handling is unified.
    if startswith(String(model), "llamacpp:")
        root = FlootyStreams.LLAMACPP_BASE_URL[]
        isempty(strip(root)) && error(
            "no base URL for model '$model' — FlootyHub is not serving " *
            "(run `flootyhub serve`)")
        provider = FlootyStreams.OllamaProvider(baseURL = root,
                                                timeout = Int(round(timeoutS)))
        wire = stripProviderPrefix(model)
        opts = Dict{String,Any}("temperature" => Float64(temperature),
                                 "num_predict" => Int(maxTokens))
        resp = FlootyStreams.chat(provider, messages, wire, false, nothing, opts)
        return String(something(resp.message.content, ""))
    end
    isempty(strip(baseUrl)) && error(
        "no base URL for model '$model' — the provider is not registered or its " *
        "server is not running (for local GGUF models run `flootyhub serve`)")
    url = rtrimSlash(baseUrl) * "/chat/completions"
    bodyDict = Dict{String,Any}(
        "model" => String(model),
        "messages" => requestMessages(messages; reasoningField = reasoningField),
        "temperature" => Float64(temperature),
        "max_tokens" => Int(maxTokens),
        "stream" => false,
    )
    jsonMode && (bodyDict["response_format"] = Dict("type" => "json_object"))
    body = JSON.json(bodyDict)
    headers = ["Content-Type" => "application/json"]
    if !isempty(apiKey)
        push!(headers, "Authorization" => "Bearer " * String(apiKey))
    end
    resp = HTTP.post(url, headers, body;
                     readtimeout = Int(timeoutS * 1000), retry = false)
    parsed = JSON.parse(String(resp.body))
    message = parsed.choices[1].message
    content = message.content === nothing ? "" : String(message.content)
    return withReasoning(content, providerReasoning(message))
end

"""
    providerReasoning(message) :: String

Reasoning an OpenAI-compatible endpoint returns in a field of its OWN instead of
inline in the content: `reasoning_content` (Poolside/DeepSeek/OpenRouter),
`reasoning` (Ollama cloud), or Ollama's native `thinking`. Empty when the reply carries
none. Dropping these was why "thinking" never reached the UI on models that
reason without emitting `<thinking>` tags.
"""
function providerReasoning(message)::String
    for field in ("reasoning", "reasoning_content", "thinking")
        raw = get(message, Symbol(field), nothing)
        raw === nothing && continue
        text = String(raw)
        isempty(strip(text)) || return text
    end
    return ""
end

"""
    withReasoning(content, reasoning) -> String

Fold provider-side reasoning into the INLINE `<thinking>…</thinking>` convention
the rest of the agent already speaks (`extractThinking` shows it in the UI,
`stripThinking` keeps it out of the action JSON) so reasoning reaches the chat
whichever field the endpoint used. Content that already carries a thinking block
wins; a stray closing tag inside the reasoning is dropped so it cannot end the
block early.
"""
function withReasoning(content::AbstractString, reasoning::AbstractString)
    isempty(strip(reasoning)) && return String(content)
    occursin("<thinking>", content) && return String(content)
    occursin("<cot>", content) && return String(content)
    safe = replace(String(reasoning), "</thinking>" => "")
    safe = replace(safe, "</cot>" => "")
    return "<thinking>" * safe * "</thinking>\n" * String(content)
end
|
# ---- available-model list (cached, refreshed OFF the UI thread) --------------
# `listAgentModels` does HTTP. Webviews BINDINGS run on the main thread inside the
# Cocoa loop, where a synchronous request can stall the whole window (observed:
# the picker's change handler never returned). Bindings therefore read this cache
# and a background task refreshes it.
const MODEL_LIST_CACHE = Ref{Vector{String}}(String[])
const MODEL_LIST_AT = Ref(0.0)
const MODEL_LIST_LOCK = ReentrantLock()
const MODEL_LIST_TTL = 60.0

"""
    availableAgentModels(; refresh = false) :: Vector{String}

The endpoint's model list, from cache (refreshed in a background task when stale
or when `refresh` is set). Never blocks: an empty list on the first call is fine,
the UI simply populates a moment later.
"""
function refreshAgentModels!(cfg::AgentModelConfig = AGENT_CONFIG[])
    @async begin
        list = listAgentModels(cfg)
        isempty(list) || lock(MODEL_LIST_LOCK) do
            MODEL_LIST_CACHE[] = list
            MODEL_LIST_AT[] = time()
        end
    end
    @async refreshProviderGroups!()
    return nothing
end

function availableAgentModels(; refresh::Bool = false)::Vector{String}
    pCached, pAge = lock(MODEL_LIST_LOCK) do
        (copy(MODEL_LIST_CACHE[]), isempty(MODEL_LIST_CACHE[]) ? Inf :
                                  time() - MODEL_LIST_AT[])
    end
    (refresh || isempty(pCached) || pAge > MODEL_LIST_TTL) && refreshAgentModels!()
    groups, age = lock(PROVIDER_GROUPS_LOCK) do
        (copy(PROVIDER_GROUPS_CACHE[]), isempty(PROVIDER_GROUPS_CACHE[]) ? Inf :
                                  time() - PROVIDER_GROUPS_AT[])
    end
    (isempty(groups) || age > PROVIDER_GROUPS_TTL) && refreshProviderGroups!()
    out = String[]
    for g in groups
        append!(out, g.models)
    end
    return sort!(unique!(vcat(pCached, out)))
end

# ---- per-tab models ---------------------------------------------------------
# ONE process, MANY tabs: each live session may run a different model. The
# process default (AGENT_CONFIG[]) stays the fallback for sessions that never
# chose one, and for headless runs.
const MODEL_BY_SESSION = IdDict{Any,AgentModelConfig}()
const MODEL_BY_SESSION_LOCK = ReentrantLock()

"Model configuration for `sess`: its own choice, else the process default."
function sessionModelConfig(sess)::AgentModelConfig
    return lock(MODEL_BY_SESSION_LOCK) do
        get(MODEL_BY_SESSION, sess, AGENT_CONFIG[])
    end
end

"Pin the AMBIENT MONITOR of `sess` to `model`; the actor keeps its own model."
function setSessionMonitorModel!(sess, model::AbstractString)::AgentModelConfig
    base = sessionModelConfig(sess)
    spec = resolveProviderForModel(model)
    if spec === nothing
        cfg = AgentModelConfig(baseUrl = base.baseUrl, actorModel = base.actorModel,
                               monitorModel = String(model), apiKey = base.apiKey,
                               reasoningField = base.reasoningField,
                               maxOutputTokens = base.maxOutputTokens)
    else
        cfg = AgentModelConfig(baseUrl = spec.baseUrl, actorModel = base.actorModel,
                               monitorModel = String(model), apiKey = spec.apiKey,
                               reasoningField = spec.reasoningField,
                               maxOutputTokens = base.maxOutputTokens)
    end
    lock(MODEL_BY_SESSION_LOCK) do
        MODEL_BY_SESSION[sess] = cfg
    end
    return cfg
end

"Pin `sess` to `model` (name from the picker); returns the config in force."
function setSessionModel!(sess, model::AbstractString)::AgentModelConfig
    base = sessionModelConfig(sess)
    spec = resolveProviderForModel(model)
    if spec === nothing
        cfg = AgentModelConfig(baseUrl = base.baseUrl, actorModel = String(model),
                               monitorModel = base.monitorModel, apiKey = base.apiKey,
                               reasoningField = base.reasoningField,
                               maxOutputTokens = base.maxOutputTokens)
    else
        cfg = AgentModelConfig(baseUrl = spec.baseUrl, actorModel = String(model),
                               monitorModel = base.monitorModel, apiKey = spec.apiKey,
                               reasoningField = spec.reasoningField,
                               maxOutputTokens = base.maxOutputTokens)
    end
    lock(MODEL_BY_SESSION_LOCK) do
        MODEL_BY_SESSION[sess] = cfg
    end
    return cfg
end

"Drop `sess`'s per-tab choice (teardown); no-op when it never had one."
function forgetSessionModel!(sess)
    lock(MODEL_BY_SESSION_LOCK) do
        pop!(MODEL_BY_SESSION, sess, nothing)
    end
    return nothing
end

"""
    listAgentModels(cfg::AgentModelConfig = defaultAgentModelConfig()) :: Vector{String}

Model ids the endpoint offers (`GET /v1/models`), sorted. Best-effort: an
unreachable endpoint or an unexpected payload yields an empty list, so the UI's
picker simply has nothing to offer instead of erroring.
"""
function listAgentModels(cfg::AgentModelConfig = defaultAgentModelConfig())::Vector{String}
    url = rtrimSlash(cfg.baseUrl) * "/models"
    headers = Pair{String,String}[]
    isempty(cfg.apiKey) ||
        push!(headers, "Authorization" => "Bearer " * cfg.apiKey)
    try
        resp = HTTP.get(url, headers; readtimeout = 15_000, retry = false)
        parsed = JSON.parse(String(resp.body))
        ids = String[]
        for m in get(parsed, :data, ())
            id = get(m, :id, nothing)
            (id === nothing || isempty(strip(String(id)))) && continue
            push!(ids, String(id))
        end
        return sort!(ids)
    catch err
        @debug "flootyOllamaClient: listAgentModels failed" exception = err
        return String[]
    end
end

rtrimSlash(s::AbstractString) =
    endswith(s, "/") ? String(chop(s)) : String(s)
|
"""
    stripThinking(text) -> String

Remove `<thinking>...</thinking>` reasoning blocks (thinking models like
lfm2.5-thinking emit them before the answer). An unbalanced trailing
`<thinking>...` (still open at end) is dropped as well.
"""
function stripThinking(text::AbstractString)
    s = stripInvisible(String(text))
    s = replace(s, r"<thinking>.*?</thinking>"s => "")
    s = replace(s, r"<thinking>.*$"s => "")
    s = replace(s, r"<cot>.*?</cot>"s => "")
    s = replace(s, r"<cot>.*$"s => "")
    s = replace(s, r"<think>.*?</think>"s => "")
    s = replace(s, r"<think>.*$"s => "")
    s = replace(s, r"<\|thought_begin\|>.*?<\|thought_end\|>"s => "")
    s = replace(s, r"<\|thought_begin\|>.*$"s => "")
    # Orphan close markers (open/close spelling mismatch, e.g. <cot>...</cot><​/think>)
    s = replace(s, r"</?thinking>" => "")
    s = replace(s, r"</?cot>" => "")
    s = replace(s, r"</?think>" => "")
    s = replace(s, r"<\|thought_end\|>" => "")
    s = replace(s, r"<\|thought_begin\|>" => "")
    return strip(s)
end
|
"""
    extractThinking(text) -> String

Return the raw content of the FIRST `<thinking>...</thinking>` reasoning
block in `text`, or "" when none is present. Unlike `stripThinking` (which
discards the block), this captures it for display — so the side panel can
show what the model reasoned before acting.
"""
function extractThinking(text::AbstractString)
    s = stripInvisible(String(text))
    m = match(r"<thinking>(.*?)</thinking>"s, s)
    m === nothing && (m = match(r"<cot>(.*?)</cot>"s, s))
    m === nothing && (m = match(r"<​think>(.*?)<​/think>"s, s))
    m === nothing && (m = match(r"<\|thought_begin\|>(.*?)<\|thought_end\|>"s, s))
    m === nothing && (m = match(r"<(?:thinking|cot)>\s*(.*?)\s*</?[^>]*>"s, s))
    return m === nothing ? "" : String(m.captures[1])
end
|
"""
    ollamaReachable(; baseUrl, timeoutS = 2.0) :: Bool

Probe the inference server's root endpoint. Cheap gate so
probes/scripts can degrade gracefully when the server is down.
"""
function ollamaReachable(; baseUrl::AbstractString = defaultAgentModelConfig().baseUrl,
                         apiKey::AbstractString = "",
                         timeoutS::Real = 2.0)
    root = rtrimSlash(baseUrl)
    headers = ["Content-Type" => "application/json"]
    if !isempty(apiKey)
        push!(headers, "Authorization" => "Bearer " * String(apiKey))
    end
    try
        resp = HTTP.get(root * "/models", headers;
                        readtimeout = Int(timeoutS * 1000),
                        retry = false)
        return resp.status == 200
    catch
        return false
    end
end
|
"""
    streamCompletion(baseUrl, model, messages; onThinking = nothing, …) :: String

STREAMING chat round-trip (OpenAI-compatible SSE). Thinking arrives chunk by
chunk while the model is still generating: `onThinking(text)` is called for every
reasoning delta in arrival order, so the UI shows the monologue live instead of
one big block at the end. Returns the SAME folded string `chatCompletion`
returns (`withReasoning(content, reasoning)`), so the loop is unchanged.

Transport notes: `HTTP.open` keeps the body streaming; `data: [DONE]` ends it; a
body that is not SSE (some proxies ignore `stream`) is answered by the one-shot
path, so streaming degrades instead of failing.
"""
# A streaming reply that stops sending bytes is DEAD: without a per-read timeout
# `readline`/`readavailable` block forever and the run hangs with no status, no
# error and a stale "running" tool (observed: after typing into micro, the next
# completion stalled and the app sat there). 45 s of total silence is far beyond a
# reasoning model's longest pause, and bytes arriving keep the stream alive.
const STREAM_READ_TIMEOUT_S = 45.0

function streamCompletion(baseUrl::AbstractString, model::AbstractString,
                          messages::Vector{OllamaMessage};
                          temperature::Real = 0.2, apiKey::AbstractString = "",
                          timeoutS::Real = 120.0,
                          streamTimeoutS::Real = STREAM_READ_TIMEOUT_S,
                          reasoningField::AbstractString = DEFAULT_REASONING_FIELD,
                          maxTokens::Integer = DEFAULT_MAX_OUTPUT_TOKENS, jsonMode::Bool = false,
                          onThinking = nothing)::String
    # llamacpp models: route through FlootyStreams' Ollama provider.
    if startswith(String(model), "llamacpp:")
        root = FlootyStreams.LLAMACPP_BASE_URL[]
        isempty(strip(root)) && error(
            "no base URL for model '$model' — FlootyHub is not serving " *
            "(run `flootyhub serve`)")
        provider = FlootyStreams.OllamaProvider(baseURL = root,
                                                timeout = Int(round(timeoutS)))
        wire = stripProviderPrefix(model)
        opts = Dict{String,Any}("temperature" => Float64(temperature),
                                 "num_predict" => Int(maxTokens))
        ch = FlootyStreams.chat(provider, messages, wire, true, nothing, opts)
        out = IOBuffer()
        for resp in ch
            c = resp.message.content
            if c !== nothing && c isa AbstractString && !isempty(c)
                print(out, c)
            end
        end
        return String(take!(out))
    end
    isempty(strip(baseUrl)) && error(
        "no base URL for model '$model' — the provider is not registered or its " *
        "server is not running (for local GGUF models run `flootyhub serve`)")
    url = rtrimSlash(baseUrl) * "/chat/completions"
    bodyDict = Dict{String,Any}(
        "model" => String(model),
        "messages" => requestMessages(messages; reasoningField = reasoningField),
        "temperature" => Float64(temperature),
        "max_tokens" => Int(maxTokens),
        "stream" => true,
    )
    jsonMode && (bodyDict["response_format"] = Dict("type" => "json_object"))
    body = JSON.json(bodyDict)
    headers = ["Content-Type" => "application/json", "Accept" => "text/event-stream"]
    isempty(apiKey) || push!(headers, "Authorization" => "Bearer " * String(apiKey))
    # NATIVE OLLAMA FIRST: its /api/chat streams `message.thinking` deltas and its
    # transport is FlootyStreams' (one `readavailable` frame at a time — the same
    # code path FlootyTUI/FlootyApp use), and it speaks `OllamaMessage` directly.
    # For any other OpenAI-compatible endpoint the SSE path below is used.
    root = replace(rtrimSlash(baseUrl), r"/v1$" => "")
    @debug "streamCompletion path" jsonMode = jsonMode native = (occursin(r":11434\b", root) && !jsonMode) model = model
    if occursin(r":11434\b", root) && !jsonMode
        try
            provider = FlootyStreams.OllamaProvider(baseURL = root,
                                                    timeout = Int(round(streamTimeoutS)))
            # FlootyStreams.chat takes format/options POSITIONALLY; keyword
            # arguments silently fell back to the SSE path (no format control).
            channel = FlootyStreams.chat(provider, messages, model, true,
                                         jsonMode ? "json" : nothing,
                                         Dict{String,Any}("num_predict" => Int(maxTokens)))
            nativeContent = IOBuffer()
            nativeThink = IOBuffer()
            for resp in channel
                # FlootyStreams.ChatResponse is a struct, not a dict: the old
                # get(resp, :message) always threw and silently forced every
                # completion onto the SSE fallback (so format=json never reached
                # the model).
                msg = resp.message
                t = msg.thinking
                if t !== nothing && !isempty(t)
                    print(nativeThink, t)
                    onThinking === nothing || onThinking(String(t))
                end
                c = msg.content
                (c === nothing || isempty(c)) || print(nativeContent, c)
                resp.done && break
            end
            return withReasoning(String(take!(nativeContent)),
                                 String(take!(nativeThink)))
        catch err
            @debug "native ollama streaming failed; using the SSE path" exception = err
        end
    end
    # OpenAI-compatible SSE path (used for any non-Ollama endpoint).
    content = IOBuffer()
    reasoning = IOBuffer()
    saw_sse = false
    # DEADLINE ENFORCED HERE: `readtimeout` on HTTP.open is NOT applied to streamed
    # reads (measured: a stalled peer blocked ~33 s regardless). A watchdog measures
    # SILENCE (time since the last data line, so a slow but live stream is fine) and
    # CLOSES the socket, which unblocks the read and fails the run instead of
    # hanging it forever.
    lastFrameAt = Ref(time())
    stalled = Ref(false)
    finished = Ref(false)
    ioRef = Ref{Any}(nothing)
    watchdog = @async begin
        while !finished[]
            sleep(0.25)
            finished[] && break
            if time() - lastFrameAt[] > Float64(streamTimeoutS)
                stalled[] = true
                try close(ioRef[]) catch end
                break
            end
        end
    end
    try
        HTTP.open("POST", url; headers = headers) do io
            ioRef[] = io
            write(io, body)
            closewrite(io)
            startread(io)
            # HTTP.Stream falls back to one-byte reads for readline/eof, which
            # floods the log and is slow. A buffered view fixes both without
            # changing the streaming contract.
            buffered = BufferedInputStream(io)
            saw_sse = consumeSSEFrames(buffered, onThinking;
                                       reasoningField = reasoningField,
                                       content = content, reasoning = reasoning,
                                       onFrame = () -> (lastFrameAt[] = time()))
        end
        stalled[] && error("stream stalled: no data for " *
                           "$(round(streamTimeoutS; digits = 1))s " *
                           "(model/endpoint stopped sending)")
    catch err
        stalled[] && error("stream stalled: no data for " *
                           "$(round(streamTimeoutS; digits = 1))s " *
                           "(model/endpoint stopped sending)")
        rethrow()
    finally
        finished[] = true
        try close(ioRef[]) catch end
    end
    full = String(take!(content))
    think = String(take!(reasoning))
    if !saw_sse
        return chatCompletion(baseUrl, model, messages; temperature = temperature,
                              apiKey = apiKey, timeoutS = timeoutS,
                              reasoningField = reasoningField,
                              maxTokens = maxTokens, jsonMode = jsonMode)
    end
    return withReasoning(full, think)
end

"""
    consumeSSEFrames(io, onThinking; reasoningField, content, reasoning) :: Bool

Read one OpenAI-compatible SSE body. Reasoning deltas go to `onThinking` (and to
`reasoning`), content deltas to `content`; returns whether any SSE frame was seen
(false means the peer ignored `stream` and answered with one plain JSON body, so
the caller falls back to the one-shot path). Pure I/O — unit-testable.
"""
function consumeSSEFrames(io::IO, onThinking;
                          reasoningField::AbstractString = DEFAULT_REASONING_FIELD,
                          content::IOBuffer = IOBuffer(),
                          reasoning::IOBuffer = IOBuffer(),
                          onFrame = nothing)::Bool
    saw = false
    while !eof(io)
        line = String(readline(io))
        onFrame === nothing || onFrame()
        startswith(line, "data:") || continue
        payload = strip(line[6:end])
        isempty(payload) && continue
        payload == "[DONE]" && break
        obj = try
            JSON.parse(payload)
        catch err
            continue
        end
        saw = true
        choices = get(obj, :choices, nothing)
        (choices === nothing || isempty(choices)) && continue
        delta = get(choices[1], :delta, nothing)
        delta === nothing && continue
        # Field order = preference; DEDUPED, or `reasoning` would count twice when
        # `reasoningField` is its default.
        think = ""
        fields = Symbol[]
        isempty(reasoningField) || push!(fields, Symbol(reasoningField))
        for f in (:reasoning, :reasoning_content, :thinking)
            f in fields || push!(fields, f)
        end
        for field in fields
            v = get(delta, field, nothing)
            (v === nothing || !(v isa AbstractString) || isempty(v)) && continue
            think *= String(v)
        end
        if !isempty(think)
            print(reasoning, think)
            onThinking === nothing || onThinking(think)
        end
        c = get(delta, :content, nothing)
        (c === nothing || !(c isa AbstractString)) && continue
        print(content, String(c))
    end
    return saw
end

"""
    makeCompleteFn(cfg, model; temperature, timeoutS, onThinking = nothing,
                   stream = true)

Build a `completeFn(messages)::String` bound to one configured model — the
default backend handed to the agent loop / monitor. With `stream` (default) the
reply is read as it is generated and `onThinking(chunk)` receives every reasoning
delta; any streaming failure falls back to the one-shot call, so a provider that
cannot stream still answers.
"""
makeCompleteFn(cfg::AgentModelConfig, model::AbstractString;
               temperature::Real = 0.2, timeoutS::Real = 120.0,
               maxTokens::Integer = cfg.maxOutputTokens,
               jsonMode::Bool = false,
               onThinking = nothing, stream::Bool = true) =
    messages -> begin
        wire = stripProviderPrefix(model) # picker prefix → raw model id for the API
        # Resolve the provider endpoint for prefixed models (poolside/, ollama:,
        # chutes:, ssh:, llamacpp:); unknown names keep the caller-supplied default.
        spec = resolveProviderForModel(String(model))
        baseUrl = spec === nothing ? String(cfg.baseUrl) : String(spec.baseUrl)
        apiKey = spec === nothing ? String(cfg.apiKey) : String(spec.apiKey)
        reasoningField = spec === nothing ? String(cfg.reasoningField) : String(spec.reasoningField)
        # llamacpp models are served by FlootyHub, whose address can change
        # (port fallback, restart). Re-resolve on every call instead of
        # trusting a baseUrl that may have been pinned while the server was
        # down or on a different port.
        if startswith(String(model), "llamacpp:")
            baseUrl = String(FlootyStreams.LLAMACPP_BASE_URL[])
        end
        if stream
            try
                return streamCompletion(baseUrl, wire, messages;
                                        temperature = temperature, apiKey = apiKey,
                                        timeoutS = timeoutS,
                                        reasoningField = reasoningField,
                                        maxTokens = maxTokens,
                                        jsonMode = jsonMode,
                                        onThinking = onThinking)
            catch err
                @debug "streamCompletion failed; falling back to one-shot" exception = err
            end
        end
        return chatCompletion(baseUrl, wire, messages;
                              temperature = temperature, apiKey = apiKey,
                              timeoutS = timeoutS,
                              reasoningField = reasoningField,
                              maxTokens = maxTokens, jsonMode = jsonMode)
    end

actorCompleteFn(cfg::AgentModelConfig = defaultAgentModelConfig();
                kwargs...) = makeCompleteFn(cfg, cfg.actorModel; jsonMode = true, kwargs...)
monitorCompleteFn(cfg::AgentModelConfig = defaultAgentModelConfig();
                  kwargs...) = makeCompleteFn(cfg, cfg.monitorModel; jsonMode = true, kwargs...)
const _P2P_PROVIDER = Ref{Any}(nothing)

"""
    p2pProvider() -> FlootyComputeProvider

Process-wide singleton P2P provider. Wraps a local OllamaProvider so the node
can both serve its own models and route to peers. Mirrors PeerCompute, where
`wrapped` supplies serialization helpers and the self-target fallback.
"""
function p2pProvider()
    cfg = AGENT_CONFIG[]
    existing = _P2P_PROVIDER[]
    if existing !== nothing && existing.nodeRunning
        return existing
    end
    # No `wrapped` provider: Flooty is a pure client here. Setting one makes
    # start_provider list the wrapped models over HTTP, which blocks while a
    # large model is loading. Add `wrapped` only when this node must serve.
    p = FlootyAbstract.create_provider_instance(:flootycompute; config = Dict{Symbol,Any}(
        :p2pPort => cfg.p2pPort,
        :apiPort => cfg.p2pApiPort,
        :discovery_topic => cfg.discoveryTopic,
        :bootstrap_peers => cfg.bootstrapPeers,
        :enable_mdns => true,
    ))
    FlootyStreams.start_provider(p)
    _P2P_PROVIDER[] = p
    return p
end
function p2pChatCompletion(model::AbstractString, messages::Vector{OllamaMessage};
                           maxTokens::Integer = DEFAULT_MAX_OUTPUT_TOKENS, jsonMode::Bool = false)
    p = p2pProvider()
    format = jsonMode ? "json" : nothing
    options = Dict{String,Any}("num_predict" => Int(maxTokens))
    resp = FlootyStreams.chat(p, messages, String(model), false, format, options, nothing)
    content = resp.message.content === nothing ? "" : String(resp.message.content)
    return withReasoning(content, "")
end

# ---- peer models -----------------------------------------------------------
# The picker above lists what the LOCAL endpoint serves. Peers advertise their
# own models over FlootyCompute, so when P2P is on we merge those in and keep
# the two sets separate so the UI can group them.

"Models advertised by reachable FlootyCompute peers (empty when P2P is off)."
function peerAgentModels()::Vector{String}
    cfg = AGENT_CONFIG[]
    cfg.p2p || return String[]
    # NEVER start a node here: this runs on the UI thread and start_provider is
    # a blocking ccall. Only read a provider that is already running.
    p = _P2P_PROVIDER[]
    (p === nothing || !p.nodeRunning) && return String[]
    out = String[]
    try
        for peer in FlootyStreams.discover_peers(p)
            append!(out, peer.models)
        end
    catch err
        @debug "peerAgentModels: discovery failed" exception = err
    end
    return sort!(unique!(out))
end

function _queryProviderModels(spec::ProviderSpec)::Vector{String}
    cfg = AgentModelConfig(baseUrl = spec.baseUrl, apiKey = spec.apiKey)
    return listAgentModels(cfg)
end

function _listLocalOllamaModels()::Vector{String}
    spec = get(KNOWN_PROVIDERS, :ollama, nothing)
    spec === nothing && return String[]
    root = replace(rtrimSlash(spec.baseUrl), r"/v1$" => "")
    ollamaReachable(baseUrl = spec.baseUrl, apiKey = spec.apiKey, timeoutS = 2.0) || return String[]
    try
        resp = HTTP.get(root * "/api/tags"; readtimeout = 10_000, retry = false)
        parsed = JSON.parse(String(resp.body))
        ids = String[]
        for m in get(parsed, :models, ())
            id = get(m, :name, nothing)
            (id === nothing || isempty(strip(String(id)))) && continue
            push!(ids, String(id))
        end
        return ["ollama:" * id for id in sort!(ids)]
    catch err
        @debug "_listLocalOllamaModels failed" exception = err
        return String[]
    end
end

function _listChutesModels()::Vector{String}
    spec = get(KNOWN_PROVIDERS, :chutes, nothing)
    spec === nothing && return String[]
    isempty(spec.apiKey) && return String[]
    models = _queryProviderModels(spec)
    return ["chutes:" * id for id in models]
end

function _listSshOllamaModels()::Vector{String}
    out = String[]
    for r in lock(SSH_REMOTES_LOCK) do; collect(SSH_OLLAMA_REMOTES); end
        append!(out, listSshOllamaModels(r))
    end
    return out
end

"""
    _listLocalLlamaModels() -> Vector{String}

List locally downloaded GGUF models via FlootyHub or FlootyLlamaModels (if loaded).
Each name is prefixed with `llamacpp:` so the picker groups it and
resolveProviderForModel can route it.
"""
function _listLocalLlamaModels()::Vector{String}
    # FlootyHub is a direct dependency here; FlootyLlamaModels remains an
    # optional legacy source loaded into Main.
    try
        models = FlootyHub.downloadedModels()
        return ["llamacpp:" * String(k) for k in keys(models)]
    catch err
        @debug "FlootyHub.downloadedModels() failed" exception = err
    end
    isdefined(Main, :FlootyLlamaModels) || return String[]
    mod = getfield(Main, :FlootyLlamaModels)
    isdefined(mod, :downloadedModels) || return String[]
    try
        models = mod.downloadedModels()
        return ["llamacpp:" * String(k) for k in keys(models)]
    catch err
        @debug "_listLocalLlamaModels via FlootyLlamaModels failed" exception = err
    end
    return String[]
end

function _allProviderGroups()::Vector{ProviderGroup}
    if isempty(KNOWN_PROVIDERS)
        merge!(KNOWN_PROVIDERS, _buildKnownProviders())
    end
    groups = ProviderGroup[]
    # PoolSide: models already carry the poolside/ namespace.
    psSpec = KNOWN_PROVIDERS[:poolside]
    psModels = _queryProviderModels(psSpec)
    isempty(psModels) || push!(groups, ProviderGroup(psSpec.name, psModels))
    # Chutes
    chModels = _listChutesModels()
    isempty(chModels) || push!(groups, ProviderGroup("Chutes", chModels))
    # Local Ollama
    loModels = _listLocalOllamaModels()
    isempty(loModels) || push!(groups, ProviderGroup("Ollama (local)", loModels))
    # Local Llama.cpp models (via FlootyHub/FlootyLlamaModels)
    lcModels = _listLocalLlamaModels()
    isempty(lcModels) || push!(groups, ProviderGroup("Llama.cpp (local)", lcModels))
    # SSH Ollama remotes
    for r in lock(SSH_REMOTES_LOCK) do; collect(SSH_OLLAMA_REMOTES); end
        m = listSshOllamaModels(r)
        isempty(m) || push!(groups, ProviderGroup("Ollama (ssh:$(r))", m))
    end
    return groups
end

function refreshProviderGroups!()
    @async begin
        groups = try
            _allProviderGroups()
        catch err
            @debug "refreshProviderGroups! failed" exception = err
            ProviderGroup[]
        end
        lock(PROVIDER_GROUPS_LOCK) do
            PROVIDER_GROUPS_CACHE[] = groups
            PROVIDER_GROUPS_AT[] = time()
        end
        return nothing
    end
    return nothing
end

providerGroups(; refresh::Bool = false)::Vector{ProviderGroup} =
    let (g, age) = lock(PROVIDER_GROUPS_LOCK) do
        (copy(PROVIDER_GROUPS_CACHE[]), isempty(PROVIDER_GROUPS_CACHE[]) ? Inf :
                                  time() - PROVIDER_GROUPS_AT[])
    end
        (refresh || isempty(g) || age > PROVIDER_GROUPS_TTL) && refreshProviderGroups!()
        g
    end

"""
    resolveProviderForModel(model) -> Union{ProviderSpec,Nothing}

Map a model name to its `ProviderSpec` by checking picker-side prefixes
(`ssh:`, `chutes:`, `poolside/`, `ollama:`). Models with no known prefix
return `nothing`, so the caller falls back to the process default config
(backward compat with `perTabModelProbe.jl`'s `model-A`/`model-B`/`model-C`).
"""
function resolveProviderForModel(model::AbstractString)::Union{ProviderSpec,Nothing}
    m = String(model)
    if startswith(m, "ssh:")
        rest = m[5:end]            # after "ssh:"
        idx = findfirst(":", rest)
        if idx !== nothing
            remote = rest[1:idx.start-1]
            key = "ssh:" * remote
            return get(SSH_OLLAMA_PROVIDERS, key, nothing)
        end
        return nothing
    end
    startswith(m, "chutes:") && return get(KNOWN_PROVIDERS, :chutes, nothing)
    startswith(m, "poolside/") && return get(KNOWN_PROVIDERS, :poolside, nothing)
    startswith(m, "ollama:") && return get(KNOWN_PROVIDERS, :ollama, nothing)
    # llamacpp: prefix — local GGUF models managed by FlootyHub.
    # Re-register the spec on each resolve so the base URL stays current:
    # the hub's address can change when the port falls back or the server
    # restarts. If FlootyHub is unavailable, guess the default port rather
    # than baking an empty URL (which fails far downstream with a cryptic
    # "missing or unsupported scheme in URL" error).
    if startswith(m, "llamacpp:")
        spec = get(KNOWN_PROVIDERS, :llamacpp, nothing)
        spec === nothing && (spec = ProviderSpec(
            "Llama.cpp (local)", FlootyStreams.LLAMACPP_BASE_URL[] * "/v1", "", "llamacpp:", "",
            "thinking", DEFAULT_CONTEXT_LENGTH, :llamacpp, ""))
        return spec
    end
    return nothing
end

"""
    stripProviderPrefix(model) -> String

Remove the picker-side prefix (`chutes:`, `ollama:`, `ssh:user@host:`) so the
raw model id reaches the API; PoolSide ids already include `poolside/` in
the wire name, so they pass through untouched.
"""
function stripProviderPrefix(model::AbstractString)::String
    spec = resolveProviderForModel(String(model))
    spec === nothing && return String(model)
    prefix = spec.prefix
    startswith(model, prefix) && return String(model[length(prefix)+1:end])
    return String(model)
end

"Local vs peer model groups for the picker. A model served both ways stays local."
function agentModelGroups()
    local_models = availableAgentModels()
    peer_only = [m for m in peerAgentModels() if !(m in local_models)]
    return (local_models = local_models, peer_models = peer_only,
            providers = providerGroups())
end
