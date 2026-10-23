# promptDecision.jl — time-conditioned prompt-state fallback via Ollama
# decision models (`POST /v1/systemone`). Used only when static prompt rules
# are ambiguous; never for command completion.

const PROMPT_DECISION_STUB = Ref{Union{Nothing,Function}}(nothing)
const PROMPT_DECISION_CACHE = Dict{Any,Tuple{Float64,Any}}()
const PROMPT_DECISION_LOCK = ReentrantLock()

promptDecisionModel() = begin
    name = get(ENV, "FLOOTY_DECISION_MODEL", "")
    isempty(name) ? "clef:cloud" : String(name)
end

"Time prior for an unresolved (no-prompt, no-output) state being a PS2 wedge."
function ps2TimeHazard(elapsed_s::Real; grace_s::Real = 3.0, tau_s::Real = 5.0)
    t = Float64(elapsed_s) - Float64(grace_s)
    t <= 0 && return 0.0
    return 1 - exp(-t / max(0.1, Float64(tau_s)))
end

function _posterior(p::Real, h::Real)::Float64
    p = clamp(Float64(p), 0.0, 1.0)
    h = clamp(Float64(h), 0.0, 1.0)
    den = p * h + (1 - p) * (1 - h)
    den <= 0 && return 0.0
    return clamp(p * h / den, 0.0, 1.0)
end

"""
    promptStatusDecision(; tail, kind, pending, at_prompt, ps2, elapsed_s,
                          silence_s, grace_s, tau_s, timeout_s)
        -> NamedTuple | nothing

Ask a decision model whether an ambiguous pane is idle, at PS2, or running.
The returned `ps2_posterior` combines the model's PS2 probability with a
measured time hazard. Cached per time bucket so confidence actually evolves.
"""
function promptStatusDecision(; tail::AbstractString, kind::Symbol,
                              pending::AbstractString = "",
                              at_prompt::Bool = false, ps2::Bool = false,
                              elapsed_s::Real = 0.0, silence_s::Real = 0.0,
                              grace_s::Real = 3.0, tau_s::Real = 5.0,
                              timeout_s::Real = 2.0)
    bucket = floor(Int, Float64(elapsed_s))
    key = (hash(String(tail)), kind, String(pending), at_prompt, ps2, bucket)
    now = time()
    cached = lock(PROMPT_DECISION_LOCK) do
        get(PROMPT_DECISION_CACHE, key, nothing)
    end
    cached !== nothing && (now - cached[1] <= 45.0) && return cached[2]

    raw = nothing
    stub = PROMPT_DECISION_STUB[]
    if stub !== nothing
        raw = try
            stub(; tail, kind, pending, at_prompt, ps2,
                  elapsed_s = Float64(elapsed_s), silence_s = Float64(silence_s))
        catch
            nothing
        end
    else
        raw = try
            root = replace(rtrimSlash(AGENT_CONFIG[].baseUrl), r"/v1$" => "")
            provider = FlootyStreams.OllamaProvider(
                baseURL = root, timeout = Int(round(Float64(timeout_s) * 1000)))
            state = "kind=$(kind), at_prompt=$(at_prompt), ps2_hint=$(ps2), " *
                    "elapsed_s=$(round(Float64(elapsed_s); digits = 1)), " *
                    "silence_s=$(round(Float64(silence_s); digits = 1)), " *
                    "pending=$(repr(String(pending))).\nVISIBLE TAIL:\n" *
                    first(String(tail), 1600)
            questions = [
                "ps2" => FlootyStreams.SystemOneNoulQuestion(
                    "The visible tail is a shell continuation prompt " *
                    "(heredoc>, quote>, cmdsubst>, or bare >), so the command is incomplete."),
                "running" => FlootyStreams.SystemOneNoulQuestion(
                    "A command or foreground program is still running, not waiting for input."),
                "idle" => FlootyStreams.SystemOneNoulQuestion(
                    "The terminal is at an interactive prompt ready for a new command."),
            ]
            resp = FlootyStreams.systemone(provider, promptDecisionModel(), state,
                                           questions; keep_alive = "5m")
            a = resp.answers
            getfield(a["ps2"], :noul), getfield(a["running"], :noul),
            getfield(a["idle"], :noul)
        catch err
            @debug "prompt decision failed" exception = err
            nothing
        end
    end
    raw === nothing && return nothing
    raw isa NamedTuple ||
        throw(ArgumentError("prompt decision stub must return a NamedTuple"))
    p_ps2 = hasproperty(raw, :ps2) ? Float64(raw.ps2) : 0.0
    p_run = hasproperty(raw, :running) ? Float64(raw.running) : 0.0
    p_idle = hasproperty(raw, :idle) ? Float64(raw.idle) : 0.0
    h = ps2TimeHazard(elapsed_s; grace_s = grace_s, tau_s = tau_s)
    out = (ps2 = p_ps2, running = p_run, idle = p_idle,
           hazard = h, ps2_posterior = _posterior(p_ps2, h),
           elapsed_s = Float64(elapsed_s))
    lock(PROMPT_DECISION_LOCK) do
        PROMPT_DECISION_CACHE[key] = (now, out)
        length(PROMPT_DECISION_CACHE) > 128 &&
            delete!(PROMPT_DECISION_CACHE, first(keys(PROMPT_DECISION_CACHE)))
    end
    return out
end
