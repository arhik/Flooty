# linuxRemoteProbe.jl — the SEND path against a real LINUX shell over ssh.
#
# The dispatch ladder (prompt-watch, idle-prompt detection, error classification,
# interactive-command detection) was developed against macOS zsh/bash. A remote
# bash login is the cheapest Linux regression: the pane is a real TTY, the
# prompt differs (`user@host:~$`), and shell errors/`bat`-style pagers behave
# like a Linux box, not like the Mac.
#
# SKIPS (exit 0) when neither known address answers, so the suite works offline.
#
# Run: julia --startup-file=no --project=. test/linuxRemoteProbe.jl
using Flooty
using FlootyPTYLayer: startReplSession, closeSession!, agentWriteAndWait, tailText,
    tagIn, isInteractiveCommand, classifyShellError, _tailAtIdlePrompt

failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = detail === "" || detail === nothing ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end

hostOf() = begin
    for h in ("169.254.244.207", "192.168.0.107")
        out = try
            read(`ssh -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR $("arhik@" * h)
                  "uname -s"`, String)
        catch
            ""
        end
        occursin("Linux", out) && return h
    end
    ""
end

host = hostOf()
if isempty(host)
    println("SKIP: no Linux box reachable on the known addresses")
    println("LINUX_REMOTE_PROBE_SKIPPED")
    exit(0)
end
println("host=", host)

sess = startReplSession(`ssh -o BatchMode=yes -o LogLevel=ERROR $("arhik@" * host)`;
                        waitPrompt = false)
try
    # Wait for the remote shell's idle prompt (the pane has no Julia prompt, so
    # this is exactly the Linux prompt-detection path).
    t0 = time()
    while time() - t0 < 25 && !_tailAtIdlePrompt(tailText(sess.tail))
        sleep(0.25)
    end
    check("a remote bash prompt is recognised as idle",
          _tailAtIdlePrompt(tailText(sess.tail)), last(tailText(sess.tail), 120))
    tagIn(sess.control; mode = :agent)

    r1 = agentWriteAndWait(sess, "echo FL00TY_SEND_OK; uname -s"; timeout = 20.0)
    out1 = string(r1.excerpt)
    check("send resolves ok on Linux", r1.ok === true,
          (ok = r1.ok, kind = r1.errorKind, excerpt = first(out1, 120)))
    check("…and the remote output comes back through the snapshot path",
          occursin("FL00TY_SEND_OK", out1) && occursin("Linux", out1), first(out1, 160))

    r2 = agentWriteAndWait(sess, "ls /definitely-not-here"; timeout = 20.0)
    check("a failing command is reported as an error", r2.ok === false,
          (ok = r2.ok, kind = r2.errorKind, excerpt = first(string(r2.excerpt), 80)))
    check("…with the shell's own message classified",
          occursin("No such file", string(r2.excerpt)) || r2.errorKind !== :none,
          (r2.errorKind, first(string(r2.excerpt), 80)))

    check("a pager command is detected as interactive on Linux",
          isInteractiveCommand("bat /etc/hostname"))
    check("…while the non-paging form is not",
          !isInteractiveCommand("bat --paging=never /etc/hostname"))

    # END TO END: the model drives the remote shell through the same loop the app
    # uses, including its per-turn `send`/`ok` feedback lines.
    res = runTerminalAgent!(sess, "Run uname -a in the terminal, then stop.";
                            maxTurns = 5, evalTimeoutS = 40.0)
    tr = join(res.transcript, "\n")
    check("the agent loop finishes against a remote Linux shell", res.ok, res.summary)
    check("…it executed at least one send", occursin("send:", tr), first(tr, 200))
    check("…and reported the send's result (the feedback line)",
          occursin("-> ok:", tr) || occursin("-> ERR:", tr), "")
    check("…with the remote uname output visible to the model",
          occursin("Linux", tr), "")
    check("…and no idle-prompt refusal", !occursin("not at an idle prompt", tr), "")
finally
    try closeSession!(sess) catch e; nothing end
end

println()
if isempty(failures)
    println("LINUX_REMOTE_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
