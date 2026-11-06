# coreClientProbe.jl — Flooty as a client of an external FlootyCore node.
#
# Runs a deterministic mock Core HTTP surface so the client contract can be
# tested without a Hub, models, P2P, or a second Julia process.
#
# Run: julia --startup-file=no --project=. test/coreClientProbe.jl
using Flooty
using FlootyStreams
using HTTP
using JSON

failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = isempty(detail) ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end

function send_json(http, status::Int, obj)
    body = JSON.json(obj)
    HTTP.setstatus(http, status)
    HTTP.setheader(http, "Content-Type" => "application/json")
    HTTP.setheader(http, "Content-Length" => string(sizeof(body)))
    HTTP.startwrite(http)
    write(http, body)
    return nothing
end

function mock_core(http)
    req = http.message
    method = String(req.method)
    path = String(first(split(String(req.target), '?'; limit=2)))
    body = method in ("POST", "PUT", "PATCH") ? String(read(http)) : ""

    if method == "GET" && path == "/health"
        return send_json(http, 200, Dict("status" => "ok", "running" => true))
    elseif method == "GET" && path == "/control/status"
        return send_json(http, 200, Dict("running" => true, "node_id" => "mock",
                                         "peers" => Any[], "models" => Any[],
                                         "share_url" => "", "share_token" => ""))
    elseif method == "GET" && path == "/control/models"
        return send_json(http, 200, Dict("models" => [
            Dict("name" => "hub:d1-2b-gguf:q4_k_m", "model" => "d1-2b-gguf:q4_k_m",
                 "backend" => "local", "peer_id" => nothing, "provider" => "ollama",
                 "roles" => ["decision"]),
            Dict("name" => "hub:chat-model", "model" => "chat-model",
                 "backend" => "local", "peer_id" => nothing, "provider" => "ollama",
                 "roles" => String[]),
            Dict("name" => "p2p:peer/lfm3", "model" => "p2p:peer/lfm3",
                 "backend" => "remote", "peer_id" => "peer",
                 "provider" => "flootycompute", "roles" => String[]),
        ]))
    elseif method == "POST" && path == "/api/chat"
        data = isempty(body) ? Dict() : JSON.parse(body)
        model = String(get(data, "model", ""))
        if occursin("missing", model)
            return send_json(http, 502, Dict("error" => "No FlootyCompute peer available"))
        end
        if Bool(get(data, "stream", false))
            HTTP.setstatus(http, 200)
            HTTP.setheader(http, "Content-Type" => "application/x-ndjson")
            HTTP.startwrite(http)
            for (text, done) in (("mock ", false), ("reply", true))
                chunk = Dict("model" => model, "created_at" => "",
                             "message" => Dict("role" => "assistant", "content" => text),
                             "done" => done)
                write(http, JSON.json(chunk) * "\n")
                try flush(http.stream) catch end
            end
            return nothing
        end
        return send_json(http, 200, Dict(
            "model" => model, "created_at" => "",
            "message" => Dict("role" => "assistant", "content" => "mock reply"),
            "done" => true,
            "prompt_eval_count" => 1, "eval_count" => 2,
        ))
    end
    return send_json(http, 404, Dict("error" => "unknown route: $method $path"))
end

server = HTTP.serve!(mock_core, "127.0.0.1", 0; stream=true, verbose=0,
                      listenany=true)
base = "http://127.0.0.1:$(HTTP.port(server))"

try
    withenv("FLOOTY_CORE_URL" => base) do
        Flooty.CORE_BASE_URL[] = ""
        Flooty.CORE_EMBEDDED[] = false
        Flooty.CORE_SERVICE[] = nothing
        Flooty.CORE_SERVER[] = nothing

        url = Flooty.ensureCoreNode!()
        check("connects to an external node", url == base, url)
        check("does not start an embedded node", !Flooty.CORE_EMBEDDED[])

        models = Flooty.coreModels()
        check("lists models", length(models) == 3, length(models))
        check("carries model roles",
              any(m -> String(get(m, "name", "")) == "hub:d1-2b-gguf:q4_k_m" &&
                       "decision" in get(m, "roles", String[]), models))
        check("lists peer models", Flooty.corePeerModels() == ["p2p:peer/lfm3"],
              Flooty.corePeerModels())
        check("default actor skips decision models",
              Flooty._core_default_actor() == "hub:chat-model",
              Flooty._core_default_actor())
        check("reads node status", get(Flooty.coreStatus(), "running", false) === true)

        messages = [FlootyStreams.OllamaMessage(role="user", content="hello")]
        reply = Flooty.chatCompletion("", "llamacpp:hub:chat-model", messages)
        check("non-streaming chat", reply == "mock reply", reply)
        streamed = Flooty.streamCompletion("", "llamacpp:hub:chat-model", messages)
        check("streaming chat", streamed == "mock reply", streamed)

        threw = false
        try
            Flooty.chatCompletion("", "p2p:dead/missing", messages)
        catch err
            threw = err isa FlootyStreams.OllamaError && err.status == 502
        end
        check("propagates peer errors", threw)
    end
finally
    HTTP.forceclose(server)
    try Flooty.stopCoreNode!() catch end
    Flooty.CORE_BASE_URL[] = ""
    Flooty.CORE_EMBEDDED[] = false
    Flooty.CORE_SERVICE[] = nothing
    Flooty.CORE_SERVER[] = nothing
end

println()
if isempty(failures)
    println("CORE_CLIENT_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
