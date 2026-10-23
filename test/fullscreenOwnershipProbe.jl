# fullscreenOwnershipProbe.jl — QUITTING a full-screen program must hand the pane back.
#
# Reported live: after `micro` exited, the model still saw
# `screen=app-running (no prompt)`, `send` was refused, and the agent spun on
# `type` for 34 turns until the no-progress stop. Cause: the app-footprint test
# matched `\e[?1049h` ANYWHERE in the raw tail, so the editor that had already
# exited still "owned" the pane forever.
#
# Pinned here:
#   * _tailLooksLikeApp is LAST-TRANSITION-WINS (unit cases);
#   * a real pager owns the pane while running and gives it back after `q`;
#   * `send` works again immediately after the pager exits.
#
# Run: julia --startup-file=no --project=. test/fullscreenOwnershipProbe.jl
using Flooty
using FlootyPTYLayer: startReplSession, closeSession!, agentWriteAndWait, userWrite,
    tailText, _tailLooksLikeApp, _tailAtIdlePrompt
using FlootyPTYLayer

failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = detail === "" || detail === nothing ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end

# ---- unit: last transition decides -----------------------------------------
check("editor opened then closed is NOT app-running",
      !_tailLooksLikeApp("\e[?1049h micro UI\e[?1049l prompt % "))
check("editor still open IS app-running",
      _tailLooksLikeApp("prompt % \e[?1049h micro UI"))
check("cursor hidden then shown is NOT app-running",
      !_tailLooksLikeApp("\e[?25l render \e[?25h prompt % "))
check("cursor hide as the last transition IS app-running",
      _tailLooksLikeApp("prompt % \e[?25l render"))
check("a pager marker in HISTORY is not app-running",
      !_tailLooksLikeApp("(END)" * repeat("x", 2000) * "\nprompt % "))
check("a pager marker at the END is app-running",
      _tailLooksLikeApp("prompt %\n" * repeat("x", 200) * "(END)"))

# ---- integration: less owns the pane, q gives it back -----------------------
const FILE = joinpath(mktempdir(), "pager.txt")
write(FILE, join(["line " * string(i) for i in 1:200], "\n") * "\n")
pager = Sys.which("bat") === nothing && Sys.which("batcat") !== nothing ? "batcat" :
        Sys.which("bat") !== nothing ? "bat" : Sys.which("less") !== nothing ? "less" : ""
if isempty(pager)
    println("SKIP: no pager available")
    println("FULLSCREEN_OWNERSHIP_PROBE_SKIPPED")
    exit(0)
end
println("pager=", pager)

sess = startReplSession(`zsh -i`; waitPrompt = false)
try
    sleep(1.2)
    FlootyPTYLayer.tagIn(sess.control; mode = :agent)
    r1 = agentWriteAndWait(sess, pager * " " * FILE; timeout = 10.0)
    check("the pager starts (interactive)", r1.ok && r1.errorKind === :running,
          (ok = r1.ok, kind = r1.errorKind))
    # Keys typed before the pager reads input land in the SHELL — wait until the
    # pane is actually owned before pressing q.
    for _ in 1:80
        agentSnapshot(sess).atPrompt === false && break
        sleep(0.1)
    end
    snap1 = agentSnapshot(sess)
    check("while the pager runs, atPrompt is false", snap1.atPrompt === false,
          (atPrompt = snap1.atPrompt, appRunning = snap1.appRunning,
           fullscreen = snap1.fullscreen))
    # Ownership has THREE sources and they are not interchangeable: the live
    # alt-screen flag (`vim`/`micro`), the tail footprint, and the recent eval's
    # `:running` kind (`bat` paints inline). What the model must see is `screen=`.
    check("…and the snapshot announces the running app",
          occursin(r"screen=(fullscreen|app-running)", string(snap1)) &&
          occursin("atPrompt=false", string(snap1)),
          first(string(snap1), 160))

    userWrite(sess, "q")
    t0 = time()
    while time() - t0 < 8 && !_tailAtIdlePrompt(tailText(sess.tail))
        sleep(0.2)
    end
    snap2 = agentSnapshot(sess)
    check("after q, atPrompt is true again", snap2.atPrompt === true,
          (atPrompt = snap2.atPrompt, appRunning = snap2.appRunning,
           fullscreen = snap2.fullscreen))
    check("…and the tail no longer looks like an app",
          !_tailLooksLikeApp(tailText(sess.tail)), "")

    r2 = agentWriteAndWait(sess, "echo BACK_OK"; timeout = 15.0)
    check("send works again after the pager exits", r2.ok === true,
          (ok = r2.ok, kind = r2.errorKind, excerpt = first(string(r2.excerpt), 120)))
    check("…and its output is visible", occursin("BACK_OK", string(r2.excerpt)),
          first(string(r2.excerpt), 120))
finally
    closeSession!(sess)
end

println()
if isempty(failures)
    println("FULLSCREEN_OWNERSHIP_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
