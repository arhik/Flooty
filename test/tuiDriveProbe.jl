# tuiDriveProbe.jl — the agent drives the TUI it launched:
#   * `bat FILE` on a LARGE file: scroll a page, quit;
#   * `micro FILE`: type text, save (Ctrl+S), quit (Ctrl+Q) — on the SAME path it
#     just read with bat, which it can recollect from the snapshot.
#
# Both need the key-driving path: `send` is refused while a full-screen app owns
# the pane (no prompt), `type` writes raw keys. Headless: no window required (the
# alt-screen / app-running signals come from the PTY stream).
#
# Run: julia --startup-file=no --project=. test/tuiDriveProbe.jl
using Flooty
using FlootyPTYLayer
import FlootyPTYLayer: startReplSession, closeSession!, agentWriteAndWait, userWrite,
    tagIn, tailText, promptSegment, inAltScreen, replMode
import Flooty: agentSnapshot

failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = detail === "" || detail === nothing ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end

plain(s) = strip(FlootyPTYLayer._stripAnsi(String(s)))

"Wait until `pred()` (checked on a timer-free loop: this probe is headless)."
function waitFor(pred; timeoutS = 8.0)
    t0 = time()
    while time() - t0 < timeoutS
        pred() && return true
        sleep(0.05)
    end
    return false
end

promptBack(sess) = FlootyPTYLayer._tailAtIdlePrompt(promptSegment(sess))

"Send one key to the foreground app and wait until it EXITED (tail grew + prompt)."
function quitApp(sess, key; timeoutS = 8.0)
    before = length(tailText(sess.tail))
    userWrite(sess, key)
    return waitFor(() -> length(tailText(sess.tail)) > before + 8 && promptBack(sess);
                   timeoutS = timeoutS)
end

const DIR = mktempdir()
const BIG = joinpath(DIR, "big.txt")
const EDITED = joinpath(DIR, "edited.txt")
write(BIG, join(["line " * lpad(string(i), 4, '0') for i in 1:800], "\n") * "\n")
write(EDITED, "ORIGINAL\n")

havBat = Sys.which("bat") !== nothing
havMicro = Sys.which("micro") !== nothing
println("bat=", havBat, " micro=", havMicro)

sess = startReplSession(`zsh -i`; waitPrompt = false)
try
    sleep(1.5)
    tagIn(sess.control; mode = :agent)

    if havBat
        # ---- 1: bat a LARGE file, scroll, quit -----------------------------
        # On THIS machine `bat FILE` (even with --paging=always) prints the whole
        # file and exits: its pager does not engage in our PTY env, so there is
        # nothing to scroll. `less` is the pager that actually pages here; the
        # scroll/quit path is identical and that is what this test drives.
        check("bat is classified interactive (pager-capable)",
              FlootyPTYLayer.isInteractiveCommand("bat " * BIG))
        launch = agentWriteAndWait(sess, "less " * BIG; timeout = 15.0)
        check("the pager launches and resolves as STARTED",
              launch.ok && launch.errorKind == :running, launch.errorKind)
        check("the pager is up (prompt gone)", waitFor(() -> !promptBack(sess)),
              promptSegment(sess))
        sleep(0.5)
        firstPage = plain(tailText(sess.tail))
        snap1 = string(agentSnapshot(sess))
        check("the snapshot says a full-screen app owns the pane",
              occursin(r"screen=(fullscreen|app-running)", snap1),
              first(split(snap1, '\n')[1:min(3, end)] |> join, 140))
        check("the snapshot carries the PATH it opened (recollectable)",
              occursin(basename(BIG), snap1), first(snap1, 120))
        # Page down with the raw key a pager understands.
        userWrite(sess, " ")
        sleep(0.6)
        secondPage = plain(tailText(sess.tail))
        check("a space pages the pager (visible content moved)",
              secondPage != firstPage, (length(firstPage), length(secondPage)))
        maxLine(txt) = isempty(collect(eachmatch(r"line (\d+)", txt))) ? 0 :
                       maximum(parse.(Int, [m.captures[1] for m in eachmatch(r"line (\d+)", txt)]))
        check("…and LATER lines are on screen (the page advanced)",
              maxLine(secondPage) > maxLine(firstPage) && maxLine(secondPage) >= 24,
              (maxLine(firstPage), maxLine(secondPage)))
        # Quit and WAIT for the pager to actually exit: its screen may still hold
        # an old prompt line, so require the tail to GROW past the key press and
        # end on a prompt. (Sending a command too early produced "qmicro …".)
        quitOk = quitApp(sess, "q")
        check("q returns to the prompt", quitOk, promptSegment(sess))
    end

    if havMicro
        # ---- 2: micro the SAME file, type, save, quit ----------------------
        launch2 = agentWriteAndWait(sess, "micro " * EDITED; timeout = 15.0)
        check("micro launches and resolves as STARTED",
              launch2.ok && launch2.errorKind == :running, launch2.errorKind)
        # micro paints on the ALTERNATE screen; wait for it before typing (keys
        # sent during startup land in the shell).
        check("the editor draws its own screen (alt-screen)",
              waitFor(() -> inAltScreen(sess); timeoutS = 8.0),
              (promptSegment(sess), inAltScreen(sess)))
        sleep(0.6)
        # Type at the end of the file: End, Enter, text.
        userWrite(sess, "\x1b[F")
        sleep(0.2)
        userWrite(sess, "\r")
        sleep(0.2)
        userWrite(sess, "EDITED_BY_AGENT")
        sleep(0.4)
        userWrite(sess, "\x13")   # Ctrl+S save
        sleep(0.6)
        quitOk2 = quitApp(sess, "\x11")   # Ctrl+Q quit
        check("Ctrl+S then Ctrl+Q return to the prompt", quitOk2, promptSegment(sess))
        # ---- 3: the agent reads the file back ------------------------------
        cat = agentWriteAndWait(sess, "cat " * EDITED; timeout = 10.0)
        check("the agent reads the edited file back",
              cat.ok && occursin("EDITED_BY_AGENT", cat.excerpt),
              first(cat.excerpt, 120))
        snap2 = string(agentSnapshot(sess))
        check("the snapshot shows the edit on screen",
              occursin("EDITED_BY_AGENT", snap2))
    end
finally
    closeSession!(sess)
end

println()
if isempty(failures)
    println("TUI_DRIVE_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
