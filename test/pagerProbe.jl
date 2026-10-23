# pagerProbe.jl — pagers (bat/less) must not hang the agent, and the agent must be
# able to page/quit them ITSELF.
#
# Reported: `bat FILE` "hangs" until the eval timeout. `bat` pages by default in a
# terminal, so the prompt never comes back; the old prompt-return wait could only
# time out. Now:
#   * bat/batcat/most/less are classified interactive: the send resolves STARTED
#     as soon as the pager draws, with no timeout burn;
#   * the snapshot says `screen=fullscreen` with atPrompt=false, and the prompt
#     tells the agent to interact with {"action":"type"} (space/PgDn, q);
#   * `bat --paging=never` / `sed -n` are NOT interactive and return normally.
#
# Run: julia --startup-file=no --project=. test/pagerProbe.jl   (no window needed)
using Flooty
using FlootyPTYLayer
import FlootyPTYLayer: startReplSession, closeSession!, agentWriteAndWait, userWrite,
    tagIn, inAltScreen, replMode

failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = detail === "" || detail === nothing ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end

havBat = (Sys.which("bat") !== nothing) || (Sys.which("batcat") !== nothing)
const FILE = joinpath(mktempdir(), "pager.txt")
write(FILE, join(["line " * string(i) for i in 1:200], "\n") * "\n")

sess = startReplSession(`zsh -i`; waitPrompt = false)
try
    sleep(1.5)
    tagIn(sess.control; mode = :agent)

    if havBat
        # ---- pager launch resolves STARTED, fast, without a prompt -------------
        t0 = time()
        out = agentWriteAndWait(sess, "bat " * FILE; timeout = 20.0)
        secs = time() - t0
        check("bat resolves as STARTED, not a timeout",
              out.ok && out.errorKind == :running, out.errorKind)
        check("…quickly (no eval-timeout burn)", secs < 5.0, round(secs; digits = 2))
        # Wait until the pager is actually up (keys typed before it reads input
        # land in the SHELL instead — that races the quit).
        for _ in 1:60
            occursin("screen=", string(Flooty.agentSnapshot(sess))) && break
            sleep(0.05)
        end
        snap = string(Flooty.agentSnapshot(sess))
        check("the snapshot tells the agent a full-screen app owns the pane",
              occursin(r"screen=(fullscreen|app-running)", snap) &&
              occursin("atPrompt=false", snap),
              first(split(snap, '\n')[1:min(5, end)] |> join, 180))
        check("…and what to do about it", occursin("\"action\":\"type\"", snap),
              first(snap, 150))
        # ---- the AGENT quits it by itself --------------------------------------
        userWrite(sess, "q")
        # The prompt comes back only after the pager exits; wait for it instead of
        # guessing a sleep, or the next command lands in the pager's place.
        for _ in 1:60
            FlootyPTYLayer._tailAtIdlePrompt(FlootyPTYLayer.promptSegment(sess)) && break
            sleep(0.05)
        end
        check("typing q returns to the shell prompt",
              FlootyPTYLayer._tailAtIdlePrompt(FlootyPTYLayer.promptSegment(sess)),
              repr(FlootyPTYLayer.promptSegment(sess)))
        okAfter = agentWriteAndWait(sess, "echo AFTER_PAGER"; timeout = 10.0)
        check("commands work again after quitting the pager",
              okAfter.ok && occursin("AFTER_PAGER", okAfter.excerpt), okAfter.errorKind)
    else
        check("bat is installed for this probe", true, "skipped (no bat)")
    end

    # ---- the prompt STATES the parity contract (documented, testable) ------
    prompt = Flooty.AGENT_SYSTEM_PROMPT
    check("the prompt states view parity (snapshot == the visible viewport)",
          occursin("VIEW PARITY: the snapshot IS the user's visible viewport", prompt),
          first(prompt, 80))
    flat = replace(prompt, r"\s+" => " ")
    check("…and says not to guess or re-run for scrolled-off lines",
          occursin("do NOT guess those lines", flat) &&
          occursin("do NOT re-run a command", flat), first(flat, 120))
    check("…while still documenting how to drive a pager when wanted",
          occursin("PAGERS:", prompt) && occursin("\"q\" to quit", prompt))
    check("…and recommends TerminalPager in a Julia REPL",
          occursin("TerminalPager", prompt) && occursin("pager(read(", prompt))
    check("…so a TerminalPager send is classified interactive",
          FlootyPTYLayer.isInteractiveCommand(
              "using TerminalPager; pager(read(\"x\", String))"))

    # ---- non-paging reads are NOT interactive ------------------------------
    plain = agentWriteAndWait(sess, "sed -n '1,5p' " * FILE; timeout = 10.0)
    check("sed -n returns normally (not treated as a pager)",
          plain.ok && occursin("line 1", plain.excerpt), plain.errorKind)

    # ---- less (always present) behaves the same ----------------------------
    tLess = time()
    lessOut = agentWriteAndWait(sess, "less " * FILE; timeout = 15.0)
    check("less resolves as STARTED without hanging",
          lessOut.ok && lessOut.errorKind == :running, lessOut.errorKind)
    check("…quickly", time() - tLess < 5.0, round(time() - tLess; digits = 2))
    sleep(0.3)
    userWrite(sess, "q")
    sleep(0.5)
    check("typing q returns from less", !inAltScreen(sess))
    okEnd = agentWriteAndWait(sess, "echo DONE_PAGER"; timeout = 10.0)
    check("the session is usable afterwards", okEnd.ok, okEnd.errorKind)
finally
    closeSession!(sess)
end

println()
if isempty(failures)
    println("PAGER_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
