# heredocProbe.jl — a shell PS2 `>` is not an idle prompt.
#
# Live: after `cat <<'EOF' … EOF`, the snapshot/guard occasionally still said
# atPrompt=false (bare `>` is also Node's prompt), or a stale atPrompt captured
# before the model call refused the next verification send. Shell PS2 is now
# excluded, and the send guard re-checks the LIVE prompt.
#
# Run: julia --startup-file=no --project=. test/heredocProbe.jl
import FlootyPTYLayer
using Flooty
using FlootyPTYLayer: startReplSession, closeSession!, userWrite, tagIn,
    tailText, agentWriteAndWait

failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = detail === "" || detail === nothing ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end

check("a delimiter with punctuation is recognized",
      FlootyPTYLayer.unterminatedHeredoc("cat <<'END-EOF'\nbody") == "END-EOF")
check("…and a complete one is accepted",
      FlootyPTYLayer.unterminatedHeredoc("cat <<'END-EOF'\nbody\nEND-EOF") === nothing)

sess = startReplSession(`zsh -i`; waitPrompt = false)
try
    sleep(1.4)
    tagIn(sess.control; mode = :agent)
    userWrite(sess, "cat <<'EOF'\nhello\n")
    sleep(0.5)
    check("a heredoc continuation is NOT an idle prompt",
          !Flooty.atIdlePrompt(sess), repr(last(tailText(sess.tail), 120)))
    check("…and the session is still classified as a shell, not node",
          FlootyPTYLayer.sessionKind(sess) === :shell,
          string(FlootyPTYLayer.sessionKind(sess)))
    snap = agentSnapshot(sess)
    check("…and the snapshot says atPrompt=false", !snap.atPrompt,
          string(snap)[1:min(end, 140)])
    check("…and explicitly says ps2=true", snap.ps2 &&
          occursin("ps2=true", string(snap)), string(snap)[1:min(end, 160)])

    userWrite(sess, "EOF\n")
    sleep(0.6)
    check("closing the heredoc restores the idle prompt",
          Flooty.atIdlePrompt(sess), repr(last(tailText(sess.tail), 120)))
    out = agentWriteAndWait(sess, "echo AFTER_HEREDOC"; timeout = 5.0)
    check("a send after the heredoc runs", out.ok &&
          occursin("AFTER_HEREDOC", out.excerpt), first(out.excerpt, 140))

    # The agent itself sends a COMPLETE heredoc: it must run and return output.
    out = agentWriteAndWait(sess, "cat <<'EOF'\nHELLO_FROM_AGENT\nEOF";
                            timeout = 5.0)
    check("an agent-sent complete heredoc runs and returns output", out.ok &&
          occursin("HELLO_FROM_AGENT", out.excerpt), first(out.excerpt, 160))

    # A heredoc whose terminator was truncated must NOT be typed: otherwise the
    # shell sits at heredoc> forever and every later send is just heredoc body.
    before = tailText(sess.tail)
    out = agentWriteAndWait(sess, "cat <<'EOF'\nNO_TERMINATOR";
                            timeout = 1.0)
    check("an unterminated heredoc is refused before writing", !out.ok &&
          occursin("heredoc", lowercase(out.excerpt)), first(out.excerpt, 180))
    check("…and the terminal is still at a prompt", Flooty.atIdlePrompt(sess),
          repr(last(tailText(sess.tail), 120)))
    check("…with none of its body typed", !occursin("NO_TERMINATOR", tailText(sess.tail)),
          repr(last(tailText(sess.tail), 120)))
finally
    closeSession!(sess)
end

println()
if isempty(failures)
    println("HEREDOC_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
