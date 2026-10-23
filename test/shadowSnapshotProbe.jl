# shadowSnapshotProbe.jl - agentSnapshot must read the server-side shadow model.
# Run as a script:
#   julia --startup-file=no --project=. test/shadowSnapshotProbe.jl
using Pkg
if Base.identify_package("Flooty") === nothing
    Pkg.develop(; path = dirname(@__DIR__), io = devnull)
end

using Flooty
import FlootyPTYLayer

failures = String[]
function check(name::String, ok::Bool)
    println(ok ? "PASS  " : "FAIL  ", name)
    ok || push!(failures, name)
end

let s = FlootyPTYLayer.startReplSession(`/bin/sh -i`; rows = 8, cols = 40, waitPrompt = false)
    id, e = FlootyPTYLayer.registerAdoptedSession!(s)
    sleep(0.7)
    FlootyPTYLayer.writeToPty(s.pty, Vector{UInt8}(codeunits("echo SNAP_SHADOW_MARK\n")))
    sleep(0.7)
    shadow = FlootyPTYLayer.shadowTextFor(s)
    check("shadow model has the marker", occursin("SNAP_SHADOW_MARK", shadow))
    snap = Flooty.agentSnapshot(s)
    check("agentSnapshot carries the marker", occursin("SNAP_SHADOW_MARK", snap.outputTail))
    check("agentSnapshot rows match the shadow", snap.rows == 8)
    FlootyPTYLayer.closeSession!(s)
end

# Independent oracle: assert LITERAL expected screen content, not the shadow.
let s = FlootyPTYLayer.startReplSession(`/bin/sh -i`; rows = 8, cols = 40, waitPrompt = false)
    id, e = FlootyPTYLayer.registerAdoptedSession!(s)
    sleep(0.7)
    FlootyPTYLayer.writeToPty(s.pty, Vector{UInt8}(codeunits("echo LITERAL_ORACLE
")))
    sleep(0.7)
    snap = Flooty.agentSnapshot(s)
    lines = split(snap.outputTail, '\n')
    check("snapshot has the literal output line",
          any(==("LITERAL_ORACLE"), strip.(lines)))
    check("snapshot has the literal echoed command",
          any(l -> occursin("echo LITERAL_ORACLE", l), lines))
    FlootyPTYLayer.closeSession!(s)
end

println()
if isempty(failures)
    println("ALL SNAPSHOT CHECKS PASSED")
else
    println(length(failures), " FAILURE(S):")
    foreach(f -> println("  - ", f), failures)
    exit(1)
end
