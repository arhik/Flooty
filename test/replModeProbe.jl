# replModeProbe.jl — Julia REPL MODES: switch them, and make `send` behave per mode.
#
# Reported: `send ]` (enter Pkg mode) stayed "running" forever. A mode switch is a
# BARE keystroke; the prompt does not "come back", it CHANGES shape, so the old
# prompt-return wait could never finish. This probe pins:
#   * replMode()/promptSegment() reading `julia>`, `shell>`, `(@v1.x) pkg>`, `help?>`;
#   * a bare `;` / `]` / `?` / backspace sent as `send` types the key RAW (no Enter)
#     and resolves on the PROMPT CHANGE, quickly;
#   * `send` in each mode runs that mode's language, with mode-appropriate failure
#     classification (shell: command not found; Julia: MethodError);
#   * the snapshot exposes `mode=` so the model knows what a send will mean.
#
# Run: julia --startup-file=no --project=. test/replModeProbe.jl   (no window needed)
using Flooty
using FlootyPTYLayer
import FlootyPTYLayer: startReplSession, closeSession!, agentWriteAndWait, tagIn,
    replMode, promptSegment

failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = detail === "" || detail === nothing ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end

"Send a bare mode key and return (ok, seconds, excerpt)."
function switch!(sess, key)
    t0 = time()
    out = agentWriteAndWait(sess, key; timeout = 6.0)
    return (out.ok, time() - t0, out.excerpt, out.errorKind)
end

sess = startReplSession(`julia --startup-file=no -q`; waitPrompt = false)
try
    sleep(2.0)
    tagIn(sess.control; mode = :agent)
    check("a fresh Julia REPL is in julia> mode", replMode(sess) == :julia, replMode(sess))
    check("the prompt segment is the live prompt",
          occursin("julia>", promptSegment(sess)), promptSegment(sess))

    # ---- snapshot carries the mode ------------------------------------------
    snap = string(Flooty.agentSnapshot(sess))
    check("the snapshot tells the model the mode",
          occursin(r"mode=julia\b", snap), first(split(snap, '\n')[1:2] |> join, 90))

    # ---- ] : julia> -> pkg> --------------------------------------------------
    (ok, secs, excerpt, kind) = switch!(sess, "]")
    check("send \"]\" enters Pkg mode", ok && replMode(sess) == :pkg, excerpt)
    check("…and it does NOT hang (was: running forever)", secs < 2.0,
          round(secs; digits = 2))
    check("the snapshot mode follows the switch",
          occursin(r"mode=pkg\b", string(Flooty.agentSnapshot(sess))))

    # `send` in pkg> runs a Pkg command (not Julia)
    pkgOut = agentWriteAndWait(sess, "st"; timeout = 25.0)
    check("send in pkg> runs a Pkg command", pkgOut.ok, pkgOut.errorKind)
    badPkg = agentWriteAndWait(sess, "rm NoSuchPackage_zzz"; timeout = 25.0)
    check("a failing Pkg command is reported as a failure", !badPkg.ok, badPkg.errorKind)

    # ---- backspace : pkg> -> julia> ----------------------------------------
    (ok, secs, excerpt, _) = switch!(sess, "\x7f")
    check("backspace leaves Pkg mode", ok && replMode(sess) == :julia, excerpt)
    check("…promptly", secs < 2.0, round(secs; digits = 2))
    (ok, secs, excerpt, _) = switch!(sess, "\x7f")
    check("backspace at julia> answers immediately (no timeout)",
          !ok && secs < 0.5 && occursin("already at julia>", excerpt), (round(secs; digits = 2), excerpt))

    # ---- ; : julia> -> shell> ----------------------------------------------
    (ok, secs, excerpt, _) = switch!(sess, ";")
    check("send \";\" enters shell mode", ok && replMode(sess) == :shell, excerpt)
    shellOut = agentWriteAndWait(sess, "echo MODE_OK"; timeout = 10.0)
    check("send in shell> runs a shell command",
          shellOut.ok && occursin("MODE_OK", shellOut.excerpt), shellOut.errorKind)
    badShell = agentWriteAndWait(sess, "nosuchcmd_zzz"; timeout = 10.0)
    check("a failing shell command is reported as a failure", !badShell.ok,
          badShell.errorKind)
    (ok, _, excerpt, _) = switch!(sess, "\x7f")
    check("backspace leaves shell mode", ok && replMode(sess) == :julia, excerpt)

    # ---- ? : julia> -> help?> ----------------------------------------------
    (ok, secs, excerpt, _) = switch!(sess, "?")
    check("send \"?\" enters help mode", ok && replMode(sess) == :help, excerpt)
    helpOut = agentWriteAndWait(sess, "println"; timeout = 15.0)
    check("send in help?> searches the help", helpOut.ok &&
          occursin("println", helpOut.excerpt), helpOut.errorKind)
    # Julia's help mode EXITS after answering a query (Enter submits it), so the
    # prompt is already back at julia> — assert that instead of sending backspace.
    check("a help query returns to julia>", replMode(sess) == :julia, replMode(sess))

    # ---- normal Julia sends still work -------------------------------------
    okEval = agentWriteAndWait(sess, "1 + 1"; timeout = 10.0)
    check("a normal Julia send works after all that", okEval.ok, okEval.errorKind)
    bad = agentWriteAndWait(sess, "nosuchfn_zzz(1)"; timeout = 10.0)
    check("a failing Julia statement is classified", !bad.ok && bad.errorKind == :methodError,
          bad.errorKind)
finally
    closeSession!(sess)
end

println()
if isempty(failures)
    println("REPL_MODE_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
