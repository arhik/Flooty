# staleExcerptProbe.jl — each eval's excerpt is ITS OWN command region.
#
# Reported live: after a file containing "ERROR:" had been printed, every later
# `send` reported err and the model saw a previous command's output, so it re-sent
# commands until the run produced no new state. The OSC 133 resolver built the
# excerpt from the WHOLE display tail; it now starts after the shell's C mark.
#
# Run: julia --startup-file=no --project=. test/staleExcerptProbe.jl
using Flooty
using FlootyPTYLayer: startReplSession, closeSession!, tagIn, agentWriteAndWait

failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = detail === "" || detail === nothing ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end

sess = startReplSession(`zsh -i`; waitPrompt = false, rows = 45, cols = 69)
try
    sleep(1.5)
    tagIn(sess.control; mode = :agent)

    bad = agentWriteAndWait(sess, "echo 'ERROR: fake old failure'"; timeout = 10.0)
    check("a command whose OWN output has ERROR: reports err", bad.ok === false,
          (ok = bad.ok, kind = bad.errorKind, excerpt = String(bad.excerpt)))
    check("…its excerpt is only its own output",
          occursin("ERROR: fake old failure", String(bad.excerpt)) &&
          !occursin("zsh", String(bad.excerpt)), first(String(bad.excerpt), 100))

    clean = agentWriteAndWait(sess, "echo CLEAN_OK"; timeout = 10.0)
    check("a later CLEAN command reports ok (old ERROR: is not inherited)",
          clean.ok === true, (ok = clean.ok, kind = clean.errorKind))
    check("…and its excerpt is exactly its own output",
          strip(String(clean.excerpt)) == "CLEAN_OK", repr(clean.excerpt))

    listing = agentWriteAndWait(sess, "printf 'AAA\\nBBB\\n'"; timeout = 10.0)
    check("multi-line output is the command's region",
          strip(replace(String(listing.excerpt), "\r\n" => "\n")) == "AAA\nBBB",
          repr(listing.excerpt))
finally
    closeSession!(sess)
end

println()
if isempty(failures)
    println("STALE_EXCERPT_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
