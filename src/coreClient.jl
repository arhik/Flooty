# coreClient.jl — Flooty as a client of the headless FlootyCore node.
#
# Flooty does not start providers or reach into FlootyHub/FlootyCompute for
# inference. It asks the node for models and sends chat requests to the node's
# HTTP surface; the node owns Hub, P2P, routing, and sharing.
#
# When no node is already listening, Flooty starts one embedded and talks to
# its service object directly. HTTP would deadlock here: the client and the
# server would share a single Julia thread. An externally started node is
# reached over HTTP.

import FlootyCore

const CORE_BASE_URL = Ref{String}("")
const CORE_PORT = Ref{Int}(8081)
const CORE_SERVICE = Ref{Any}(nothing)
const CORE_SERVER = Ref{Any}(nothing)
const CORE_EMBEDDED = Ref{Bool}(false)

function _normalizeCoreUrl(url::AbstractString)::String
    value = rstrip(String(url), '/')
    isempty(value) && return ""
    return value
end

"""
    coreBaseUrl() -> String

URL of the headless node. `FLOOTY_CORE_URL` wins; otherwise the default local
port is used.
"""
function coreBaseUrl()
    configured = strip(get(ENV, "FLOOTY_CORE_URL", ""))
    if !isempty(configured)
        return _normalizeCoreUrl(configured)
    end
    isempty(CORE_BASE_URL[]) || return CORE_BASE_URL[]
    return "http://127.0.0.1:$(CORE_PORT[])"
end

function coreHealthy(; timeout::Real=1.0)
    base = coreBaseUrl()
    isempty(base) && return false
    try
        response = HTTP.get(base * "/health"; readtimeout=Int(round(timeout)),
                            retry=false)
        return response.status == 200
    catch
        return false
    end
end

function _coreRequest(method::AbstractString, path::AbstractString; body=nothing,
                      timeout::Real=10.0)
    url = coreBaseUrl() * path
    headers = ["Content-Type" => "application/json"]
    response = if body === nothing
        HTTP.request(method, url, headers; readtimeout=Int(round(timeout)),
                     retry=false)
    else
        HTTP.request(method, url, headers, JSON.json(body);
                     readtimeout=Int(round(timeout)), retry=false)
    end
    return JSON.parse(String(response.body))
end

function _modelDict(m)
    return Dict{String,Any}(
        "name" => String(m.name),
        "model" => String(m.model),
        "backend" => String(m.backend),
        "peer_id" => m.peer_id === nothing ? nothing : String(m.peer_id),
        "provider" => String(m.provider),
        "roles" => String[String(r) for r in get(m, :roles, String[])],
    )
end

"""
    ensureCoreNode!(; port=8081, hub_port=4434) -> String

Connect to an already-running node or start one embedded. Returns the node
base URL. The node owns the Hub and P2P lifecycle from this point on.
"""
function ensureCoreNode!(; port::Integer=8081, hub_port::Integer=4434)
    if CORE_EMBEDDED[] && CORE_SERVICE[] !== nothing
        FlootyStreams.set_llamacpp_base_url!(coreBaseUrl())
        return coreBaseUrl()
    end

    CORE_PORT[] = Int(port)
    configured = strip(get(ENV, "FLOOTY_CORE_URL", ""))
    CORE_BASE_URL[] = isempty(configured) ? "http://127.0.0.1:$(port)" :
                                           _normalizeCoreUrl(configured)

    # Give an externally starting node a moment before racing it for the port.
    for _ in 1:10
        coreHealthy() && break
        sleep(0.2)
    end

    if coreHealthy()
        CORE_EMBEDDED[] = false
    else
        config = FlootyCore.NodeConfig(host="127.0.0.1", port=Int(port),
                                       hub_host="127.0.0.1", hub_port=Int(hub_port))
        service, server = FlootyCore.start_node_server!(config)
        CORE_SERVICE[] = service
        CORE_SERVER[] = server
        CORE_EMBEDDED[] = true
    end

    FlootyStreams.set_llamacpp_base_url!(coreBaseUrl())
    return coreBaseUrl()
end

"""
    coreChat(model, messages; stream, format, options, tools)

Send a completion through the node. Embedded nodes are called directly; an
external node is reached through its Ollama-compatible HTTP surface.
"""
function coreChat(model::AbstractString, messages; stream::Bool=false,
                  format=nothing, options=nothing, tools=nothing)
    if CORE_EMBEDDED[] && CORE_SERVICE[] !== nothing &&
       CORE_SERVICE[].router !== nothing
        return FlootyStreams.chat(CORE_SERVICE[].router, messages, String(model),
                                  stream, format, options, tools)
    end
    root = coreBaseUrl()
    isempty(strip(root)) && error("FlootyCore is not serving at a known URL")
    provider = FlootyStreams.OllamaProvider(baseURL=root, timeout=120)
    return FlootyStreams.chat(provider, messages, String(model), stream,
                              format, options, tools)
end

function coreStatus()
    if CORE_EMBEDDED[] && CORE_SERVICE[] !== nothing
        service = CORE_SERVICE[]
        status = FlootyCore.node_status(service)
        return Dict{String,Any}(
            "running" => status.running,
            "hub_url" => status.hub_url,
            "node_id" => status.node_id,
            "peers" => status.peers,
            "models" => [_modelDict(FlootyCore._model_status(m)) for m in FlootyCore.node_models(service)],
            "share_url" => status.share_url,
            "share_token" => status.share_token,
        )
    end
    return _coreRequest("GET", "/control/status")
end

function coreModels()
    if CORE_EMBEDDED[] && CORE_SERVICE[] !== nothing
        return [_modelDict(FlootyCore._model_status(m)) for m in FlootyCore.node_models(CORE_SERVICE[])]
    end
    data = _coreRequest("GET", "/control/models")
    return get(data, "models", Any[])
end

"""
    corePeerModels() -> Vector{String}

Models currently reachable through the node's P2P transport, named
`p2p:<peer>/<model>`.
"""
function corePeerModels()::Vector{String}
    try
        return [String(get(m, "name", "")) for m in coreModels()
                if startswith(String(get(m, "name", "")), "p2p:")]
    catch
        return String[]
    end
end

function joinCoreNetwork(ticket::AbstractString)
    if CORE_EMBEDDED[] && CORE_SERVICE[] !== nothing
        ok = FlootyCore.join_network!(CORE_SERVICE[], String(ticket))
        return Dict("ok" => ok, "status" => coreStatus())
    end
    return _coreRequest("POST", "/control/join";
                        body=Dict("ticket" => String(ticket)))
end

function shareCore(; auth::AbstractString="")
    if CORE_EMBEDDED[] && CORE_SERVICE[] !== nothing
        url = FlootyCore.start_share!(CORE_SERVICE[]; auth=String(auth))
        return Dict("url" => url, "token" => CORE_SERVICE[].share_token)
    end
    return _coreRequest("POST", "/control/share";
                        body=Dict("auth" => String(auth)))
end

function stopCoreShare()
    if CORE_EMBEDDED[] && CORE_SERVICE[] !== nothing
        FlootyCore.stop_share!(CORE_SERVICE[])
        return Dict("ok" => true)
    end
    return _coreRequest("POST", "/control/unshare")
end

function stopCoreNode!()
    server = CORE_SERVER[]
    service = CORE_SERVICE[]
    (server === nothing && service === nothing) && return false
    server === nothing || FlootyCore.stop_node_server!(server)
    service === nothing || FlootyCore.stop_node!(service)
    CORE_SERVER[] = nothing
    CORE_SERVICE[] = nothing
    CORE_EMBEDDED[] = false
    return true
end
