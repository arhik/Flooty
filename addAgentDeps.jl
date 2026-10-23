# addAgentDeps.jl — add HTTP + JSON3 to the Flooty dev project
# (Ollama HTTP client needs both; JSON3 for defensive action parsing).
using Pkg
Pkg.activate("/Users/arhik/.julia/dev/Flooty")
Pkg.add("HTTP")
Pkg.add("JSON3")
println("DEPS_UPDATED")
