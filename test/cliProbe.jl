# cliProbe.jl — `flooty` argument handling, without opening a window.
#
# Reported: launching `flooty` with no arguments printed the usage block
# instead of opening the app, which read as "you still have to pass width and
# height". Every option is optional; only an explicit --help/-h asks for usage.
#
# Run: julia --startup-file=no --project=. test/cliProbe.jl
using Flooty
using Flooty: agentCliArgs

failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = detail === "" || detail === nothing ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end

# ---- bare invocation means LAUNCH ------------------------------------------
opts = agentCliArgs(String[])
check("bare invocation does not ask for help", opts.help == false)
check("bare invocation carries no instruction and no geometry",
      opts.task == "" && opts.width === nothing && opts.height === nothing,
      (opts.task, opts.width, opts.height))

# ---- only an explicit flag asks for usage ----------------------------------
check("--help asks for usage", agentCliArgs(["--help"]).help == true)
check("-h asks for usage", agentCliArgs(["-h"]).help == true)

# ---- geometry is optional, independently ------------------------------------
w = agentCliArgs(["--width", "900"])
check("--width alone is accepted (height stays the layer default)",
      w.width == 900 && w.height === nothing && w.help == false, (w.width, w.height))
h = agentCliArgs(["--height", "620"])
check("--height alone is accepted", h.height == 620 && h.width === nothing)
both = agentCliArgs(["--width", "980", "--height", "620"])
check("both geometry flags are accepted", both.width == 980 && both.height == 620)

# ---- instruction + stores ---------------------------------------------------
task = agentCliArgs(["print", "1", "and", "stop"])
check("positional words become the instruction", task.task == "print 1 and stop", task.task)
stores = agentCliArgs(["--sessions", "/tmp/s", "--journal", "/tmp/j.sqlite", "do", "it"])
check("--sessions/--journal are carried through",
      stores.sessions == "/tmp/s" && stores.journal == "/tmp/j.sqlite" &&
      stores.task == "do it", (stores.sessions, stores.journal, stores.task))

# ---- bad input is a clean ArgumentError (main prints usage) ----------------
function raises(argv)
    try
        agentCliArgs(argv)
        return ""
    catch err
        return err isa ArgumentError ? String(err.msg) : "wrong error type: " *
                                                          sprint(showerror, err)
    end
end
check("a flag without a value reports itself",
      occursin("--width needs a value", raises(["--width"])), raises(["--width"]))
check("a non-integer geometry value is rejected",
      occursin("needs an integer", raises(["--width", "x"])), raises(["--width", "x"]))
check("an unknown option is rejected",
      occursin("unknown option", raises(["--bogus"])), raises(["--bogus"]))

println()
if isempty(failures)
    println("CLI_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
