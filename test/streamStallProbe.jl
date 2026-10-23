# streamStallProbe.jl — a stream that stops sending must FAIL, not hang forever.
#
# Reported: after the story was typed into micro, the next completion produced its
# thinking and then nothing — the app sat there with a stale "running" tool. Both
# streaming transports opened the socket without a read timeout, so a provider that
# stops sending (cloud model under load, dropped FIN) blocked the run forever.
#
# A local socket server sends ONE frame and then stalls; both transports must raise
# within the configured silence budget.
#
# Run: julia --startup-file=no --project=. test/streamStallProbe.jl
using Flooty
using Flooty: streamCompletion, OllamaMessage
import FlootyStreams
using Sockets

failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = detail === "" || detail === nothing ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end

server = Sockets.listen(ip"127.0.0.1", 0)
port = Sockets.getsockname(server)[2]
stopServer = Ref(false)
@async while !stopServer[]
    sock = try
        accept(server)
    catch
        break
    end
    @async try
        readline(sock)                                   # request line
        while true                                       # headers
            l = readline(sock)
            isempty(strip(l)) && break
        end
        write(sock, "HTTP/1.1 200 OK\r\n")
        write(sock, "Content-Type: text/event-stream\r\n\r\n")
        # ONE frame, then silence — exactly the observed stall.
        write(sock, "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n")
        flush(sock)
        sleep(30)
        close(sock)
    catch
        try close(sock) catch end
    end
end
println("stall server on 127.0.0.1:", port)

msgs = [OllamaMessage(role = "user", content = "hello")]
elapsed(f) = (t0 = time(); err = nothing; try f() catch e; err = e end; (time() - t0, err))

# --- OpenAI-compatible SSE path (any port that is not 11434) -----------------
dt, err = elapsed() do
    streamCompletion("http://127.0.0.1:$port/v1", "fake-model", msgs;
                     timeoutS = 5.0, streamTimeoutS = 2.0)
end
check("the SSE stream raises instead of hanging", err !== nothing,
      err === nothing ? "returned after $(round(dt; digits=1))s" : sprint(showerror, err))
check("…within the silence budget (< 8 s)", dt < 8.0, round(dt; digits = 2))

# --- native NDJSON transport (FlootyStreams) ---------------------------------
prov = FlootyStreams.OllamaProvider(baseURL = "http://127.0.0.1:$port", timeout = 2)
dt2, err2 = elapsed() do
    ch = FlootyStreams.chat(prov, msgs, "fake-model", true)
    for _ in ch
    end
end
check("the native stream raises instead of hanging", err2 !== nothing,
      err2 === nothing ? "returned after $(round(dt2; digits=1))s" : sprint(showerror, err2))
check("…within the provider timeout (< 8 s)", dt2 < 8.0, round(dt2; digits = 2))

stopServer[] = true
try close(server) catch end
println()
if isempty(failures)
    println("STREAM_STALL_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
