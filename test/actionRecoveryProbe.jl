# actionRecoveryProbe.jl — MALFORMED MODEL REPLIES must be recoverable.
#
# Reported live: the model emitted
#   {"action":"send","code":"cd ~/.julia/dev/ArboryCA && find . ... head -300
# — an UNTERMINATED JSON string (output cut mid-command). Three of those in a row
# stopped the run ("stopped: unparseable replies") with nothing executed.
#
# Pinned here:
#   * jsonFailureKind names the failure (prose / truncated / malformed);
#   * a truncated reply is reported as such and the corrective note says the reply
#     was CUT OFF (so the model shortens/chunks instead of repeating);
#   * an oversized `code` is REFUSED before execution (it is what gets truncated);
#   * literal newlines inside a string are repaired and DO parse (regression for
#     the existing repair tier).
#
# Run: julia --startup-file=no --project=. test/actionRecoveryProbe.jl
using Flooty
using FlootyPTYLayer: startReplSession, closeSession!, tagIn, tailText

failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = detail === "" || detail === nothing ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end

# ---- pure parser classification ---------------------------------------------
truncated = "{\"action\":\"send\",\"code\":\"cd ~/.julia/dev/ArboryCA && find . -maxdepth 4 -type f | sort && grep -RInE 'include|using' src | head -300"
check("an unterminated reply is classified :truncated",
      Flooty.jsonFailureKind(truncated) === :truncated,
      Flooty.jsonFailureKind(truncated))
check("…and yields no action", Flooty.extractActionJson(truncated) === nothing)
check("prose is classified :prose",
      Flooty.jsonFailureKind("I will look at the files.") === :prose)
check("a closed-but-broken object is :malformed",
      Flooty.jsonFailureKind("{\"action\":\"send\",\"code\":\"x\\q\"}") === :malformed)
pretty = "{\"action\":\"send\",\n \"code\":\"echo one\necho two\"}"   # literal newline
parsed = Flooty.extractActionJson(pretty)
check("literal newlines inside a string are repaired and parse",
      parsed !== nothing && occursin("echo one", string(get(parsed, "code", ""))),
      parsed === nothing ? "nothing" : string(get(parsed, "code", "")))

sess = startReplSession(`zsh -i`; waitPrompt = false)
try
    sleep(1.2)
    tagIn(sess.control; mode = :agent)

    # ---- 1) truncated reply → warn + a note that names TRUNCATION ----------
    replies = String[
        truncated,
        "{\"action\":\"done\",\"summary\":\"recovered\"}",
    ]
    i = Ref(0)
    seenNote = Ref("")
    completeFn = msgs -> begin
        i[] += 1
        # The corrective SYSTEM NOTE is model-facing (not a transcript line): read
        # it from what the NEXT call was actually given.
        i[] == 2 && (seenNote[] = join([string(m.content) for m in msgs
                                        if m.role == "user"], "\n"))
        replies[min(i[], length(replies))]
    end
    r1 = runTerminalAgent!(sess, "do the thing"; completeFn = completeFn, maxTurns = 4)
    t1 = join(r1.transcript, "\n")
    check("a truncated reply does not stop the run (next reply recovers)", r1.ok, r1.summary)
    check("…it is reported as a warning", occursin("[warn] unparseable model output", t1), "")
    check("…and the run never stopped for it", !occursin("stopped: unparseable", t1), "")
    check("…the corrective note names the CUT OFF reply",
          occursin("CUT OFF", seenNote[]), first(seenNote[], 160))

    # ---- 2) oversized code is refused before it can be truncated ------------
    huge = "echo " * repeat("x", Flooty.SEND_MAX_CODE_CHARS + 200)
    replies2 = String["{\"action\":\"send\",\"code\":\"$(huge)\"}",
                      "{\"action\":\"done\",\"summary\":\"chunked\"}"]
    j = Ref(0)
    completeFn2 = _ -> (j[] += 1; replies2[min(j[], length(replies2))])
    r2 = runTerminalAgent!(sess, "send a huge command"; completeFn = completeFn2,
                           maxTurns = 4)
    t2 = join(r2.transcript, "\n")
    check("an oversized send is refused", occursin("send refused: code is", t2),
          first(t2, 160))
    check("…and nothing was executed for it", !occursin("send: echo x", t2), "")
    check("…the run still finishes", r2.ok, r2.summary)

    # ---- 2b) repeated successful commands EXECUTE; no pre-execution refusal --
    # A text comparison must not decide the command was useless: the model
    # could be rerunning an idempotent inspection, and refusing it hides the
    # terminal state from the next turn (the livelock the user reported).
    okreply = "{\"action\":\"send\",\"code\":\"echo REPEAT_PROBE\"}"
    repliesDup = fill(okreply, 7)
    push!(repliesDup, "{\"action\":\"done\",\"summary\":\"repeated\"}")
    d = Ref(0)
    completeFnDup = _ -> (d[] += 1; repliesDup[min(d[], length(repliesDup))])
    rDup = runTerminalAgent!(sess, "repeat the same command"; completeFn = completeFnDup,
                             maxTurns = 9)
    tDup = join(rDup.transcript, "\n")
    check("repeated commands execute instead of being refused",
          !occursin("duplicate of just-succeeded", tDup) &&
          !occursin("[loop-guard] duplicate", tDup), first(tDup, 200))
    check("…all seven executions ran",
          length(collect(eachmatch(r"send: echo REPEAT_PROBE", tDup))) == 7,
          length(collect(eachmatch(r"send: echo REPEAT_PROBE", tDup))))
    check("…and the run finishes", rDup.ok, rDup.summary)

    # ---- 2c) a BARE COMMAND reply is recovered as a send ------------------
    # Live: after one truncated reply the model answered with the command itself
    # ("cd ~/.julia/dev/Arborythmic && find …"), three times, then stopped.
    bare = "echo RECOVERED_BARE"
    repliesBare = String[bare, bare, "{\"action\":\"done\",\"summary\":\"bare ok\"}"]
    b = Ref(0)
    completeFnBare = _ -> (b[] += 1; repliesBare[min(b[], length(repliesBare))])
    rBare = runTerminalAgent!(sess, "use a bare command"; completeFn = completeFnBare,
                              maxTurns = 5)
    tBare = join(rBare.transcript, "\n")
    check("a bare command reply is recovered as send",
          occursin("recovered a bare command as send", tBare), first(tBare, 160))
    tail = tailText(sess.tail)
    check("…the command actually ran", occursin("RECOVERED_BARE", tail), last(tail, 120))
    check("…and the run did not count it as unparseable",
          !occursin("stopped: unparseable", tBare) && rBare.ok, rBare.summary)
    check("prose is NOT mistaken for a command",
          Flooty.recoverBareCommand("Let me inspect the files.") === nothing, "")
    check("multi-line text is not a bare command",
          Flooty.recoverBareCommand("cd /tmp\nls") === nothing, "")
    check("a bare Julia/Pkg statement is recovered",
          Flooty.recoverBareCommand("using Pkg; Pkg.status(\"WGPUCompute\")") ==
          "using Pkg; Pkg.status(\"WGPUCompute\")", "")
    check("a bare Pkg call is recovered",
          Flooty.recoverBareCommand("Pkg.test(\"WGPUCompute\")") ==
          "Pkg.test(\"WGPUCompute\")", "")

    # ---- 2d) provider markup: ZWSP-corrupted and TRUNCATED tags -------------
    # Live: replies arrived as `sed -n '1,120p' file\n<\u200b/rfl:parameter>` and
    # `<rfl:parameter name="code">…` with no close. Both were "unparseable".
    zw = "sed -n \"1,120p\" src/bitPermute.jl\n<\u200b/rfl:parameter>"
    check("a bare command followed by a ZWSP close tag is recovered",
          Flooty.recoverBareCommand(zw) == "sed -n \"1,120p\" src/bitPermute.jl",
          repr(Flooty.recoverBareCommand(zw)))
    a_trunc = Flooty.extractProviderAction("<rfl:parameter name=\"code\">ls -la")
    check("truncated provider markup still yields its action",
          a_trunc !== nothing && string(a_trunc.action) == "send" &&
          string(a_trunc.code) == "ls -la",
          a_trunc === nothing ? "nothing" : string(a_trunc.action, " ", a_trunc.code))
    a_zw = Flooty.extractProviderAction("<rfl:\u200bparameter name=\"keys\">q")
    check("invisible characters inside a tag do not defeat it",
          a_zw !== nothing && string(a_zw.action) == "type" && string(a_zw.keys) == "q",
          a_zw === nothing ? "nothing" : string(a_zw.action, " ", a_zw.keys))
    repliesZw = String[zw, "{\"action\":\"done\",\"summary\":\"read\"}"]
    z = Ref(0)
    rZw = runTerminalAgent!(sess, "read a chunk";
                            completeFn = _ -> (z[] += 1; repliesZw[min(z[], 2)]),
                            maxTurns = 4)
    tZw = join(rZw.transcript, "\n")
    check("…and such a reply does not burn a strike", rZw.ok &&
          !occursin("unparseable", tZw), rZw.summary)
    check("…the command ran", occursin("bitPermute", tailText(sess.tail)), "")

    # ---- 3) invalid replies are corrected, not deterministically stopped ----
    k = Ref(0)
    completeFn3 = _ -> (k[] += 1; truncated)
    r3 = runTerminalAgent!(sess, "keep failing"; completeFn = completeFn3, maxTurns = 6)
    t3 = join(r3.transcript, "\n")
    check("invalid replies do not trigger a deterministic stop",
          !occursin("[stop]", t3) && !r3.ok, r3.summary)
    check("…each call gets the corrective warning",
          length(collect(eachmatch(r"\[warn\] unparseable", t3))) == 6,
          length(collect(eachmatch(r"\[warn\] unparseable", t3))))
finally
    closeSession!(sess)
end

println()
if isempty(failures)
    println("ACTION_RECOVERY_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
