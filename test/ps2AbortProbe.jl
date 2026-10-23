# ps2AbortProbe.jl — incomplete shell input never leaves send "running".
using FlootyPTYLayer
using FlootyPTYLayer: startReplSession, closeSession!, agentWriteAndWait, tagIn

failures = String[]
function check(name, ok, detail = "")
    println(ok ? "PASS  " : "FAIL  ", name, isempty(detail) ? "" : "  [" * string(detail) * "]")
    ok || push!(failures, name)
end

sess = startReplSession(`zsh -i`; waitPrompt = false)
try
    sleep(1.3); tagIn(sess.control; mode = :agent)

    t0 = time()
    out = agentWriteAndWait(sess, "echo 'unterminated"; timeout = 20.0)
    dt = time() - t0
    check("an unclosed quote is refused before typing", dt < 2.0, round(dt; digits = 2))
    check("…the send reports incompleteInput", !out.ok && out.errorKind == :incompleteInput,
          string(out.errorKind))
    check("…and the shell is not at PS2", !FlootyPTYLayer.shellAtPS2(sess))

    # This one is syntactically accepted but opens `case>` PS2; the watchdog
    # must abort it instead of waiting the full timeout.
    t1 = time()
    out2 = agentWriteAndWait(sess, "case x in"; timeout = 20.0)
    dt2 = time() - t1
    check("a PS2-only continuation aborts quickly", dt2 < 8.0, round(dt2; digits = 2))
    check("…with Ctrl+C in the result", occursin("Ctrl+C", out2.excerpt) ||
          occursin("timeout", lowercase(out2.excerpt)), first(out2.excerpt, 240))
    check("…leaving the shell out of PS2", !FlootyPTYLayer.shellAtPS2(sess))
finally
    closeSession!(sess)
end
println()
if isempty(failures)
    println("PS2_ABORT_PROBE_OK")
else
    println("FAILED: ", join(failures, ", ")); exit(1)
end
