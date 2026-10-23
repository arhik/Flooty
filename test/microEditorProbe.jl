# microEditorProbe.jl — drive `micro` over the PTY: write a story, SAVE it, QUIT.
#
# Reported: micro opened, text was typed, save appeared to work, but Ctrl+Q did not
# exit — the model then spun on `type` for 34 turns. Root causes were fixed (type
# keys are escapes; a quit app no longer owns the pane). This probe pins the whole
# editor round trip against the REAL binary and the REAL file on disk:
#
#   launch micro → type 3 lines (Enter = \r) → Ctrl-S (save) → Ctrl-Q (quit)
#   → back at the prompt → the file on disk holds the story.
#
# Run: julia --startup-file=no --project=. test/microEditorProbe.jl
using Flooty
using FlootyPTYLayer: startReplSession, closeSession!, agentWriteAndWait, userWrite,
    tailText, tagIn, inAltScreen, _tailAtIdlePrompt

failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = detail === "" || detail === nothing ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end

micro = Sys.which("micro")
if micro === nothing
    println("SKIP: micro not installed")
    println("MICRO_EDITOR_PROBE_SKIPPED")
    exit(0)
end

const FILE = joinpath(mktempdir(), "flooty-story.txt")
const LINES = ["Once upon a time a terminal learned to think.",
               "It watched every keystroke, and never forgot a prompt.",
               "The end — saved by Micro, quit by Ctrl-Q."]

sess = startReplSession(`zsh -i`; waitPrompt = false)
try
    sleep(1.2)
    tagIn(sess.control; mode = :agent)
    check("the story file starts absent", !isfile(FILE), FILE)

    # ---- launch ------------------------------------------------------------
    r = agentWriteAndWait(sess, "micro " * FILE; timeout = 15.0)
    check("micro starts as an interactive program",
          r.ok && r.errorKind === :running, (ok = r.ok, kind = r.errorKind))
    t0 = time()
    while time() - t0 < 10 && agentSnapshot(sess).atPrompt !== false
        sleep(0.1)
    end
    snap = agentSnapshot(sess)
    check("the editor owns the pane (atPrompt=false)", snap.atPrompt === false,
          (atPrompt = snap.atPrompt, fullscreen = snap.fullscreen,
           appRunning = snap.appRunning))

    # ---- type the story (Enter is a real CR, exactly what type "\\r" decodes to)
    typed = join(LINES, "\r")
    userWrite(sess, Flooty.decodeTypeKeys(typed))
    sleep(0.8)
    # The pane is in ALTERNATE-SCREEN mode, so the main-screen tail does not hold
    # the typed text (micro paints with cursor moves); the FILE on disk is the
    # authoritative check for what was typed.

    # ---- save: Ctrl-S ------------------------------------------------------
    userWrite(sess, Flooty.decodeTypeKeys("\\x13"))
    saved = false
    for _ in 1:40
        if isfile(FILE) && occursin("terminal learned", read(FILE, String))
            saved = true
            break
        end
        sleep(0.1)
    end
    check("Ctrl-S writes the story to disk", saved,
          isfile(FILE) ? first(read(FILE, String), 120) : "no file")

    # ---- quit: Ctrl-Q (answer the unsaved-changes prompt if it appears) ----
    userWrite(sess, Flooty.decodeTypeKeys("\\x11"))
    t0 = time()
    while time() - t0 < 10
        _tailAtIdlePrompt(tailText(sess.tail)) && break
        # micro 2.x asks "Save changes before closing? (y/n)" when it thinks it is dirty
        occursin("Save changes", tailText(sess.tail)) &&
            userWrite(sess, Flooty.decodeTypeKeys("y\\r"))
        sleep(0.2)
    end
    check("Ctrl-Q returns to the shell prompt", _tailAtIdlePrompt(tailText(sess.tail)),
          last(tailText(sess.tail), 160))
    check("…and the pane is no longer app-owned",
          !inAltScreen(sess) && agentSnapshot(sess).atPrompt === true,
          (alt = inAltScreen(sess), atPrompt = agentSnapshot(sess).atPrompt))

    # ---- the file, and a working send afterwards --------------------------
    body = isfile(FILE) ? read(FILE, String) : ""
    check("the saved file holds every line",
          all(l -> occursin(l, body), LINES),
          replace(body, "\r\n" => " | ", "\n" => " | "))
    r2 = agentWriteAndWait(sess, "cat " * FILE * " | wc -l"; timeout = 15.0)
    check("send works again after the editor exits", r2.ok === true,
          (ok = r2.ok, kind = r2.errorKind))
finally
    closeSession!(sess)
end

println()
if isempty(failures)
    println("MICRO_EDITOR_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
