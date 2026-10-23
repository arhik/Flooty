# typeKeysProbe.jl — `type` keys are ESCAPES, and empty `type` cannot spin forever.
#
# Reported live: the model emitted {"action":"type","keys":"\r"} meaning Enter. The
# harness wrote the two characters `\` and `r` into the PTY, so "q" typed at the
# shell prompt never executed, the command never ran, and the run looped for 34
# turns until the no-progress stop. Also: repeated EMPTY type actions were accepted
# forever ("type: empty keystrokes — waiting").
#
# Run: julia --startup-file=no --project=. test/typeKeysProbe.jl
using Flooty
using FlootyPTYLayer: startReplSession, closeSession!, tagIn, tailText

failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = detail === "" || detail === nothing ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end

# ---- decoding ---------------------------------------------------------------
check("\\r decodes to Enter", Flooty.decodeTypeKeys("\\r") == "\r",
      repr(Flooty.decodeTypeKeys("\\r")))
check("\\x03 decodes to Ctrl-C", Flooty.decodeTypeKeys("\\x03") == "\x03",
      repr(Flooty.decodeTypeKeys("\\x03")))
check("\\x11 decodes to Ctrl-Q (micro quit)",
      Flooty.decodeTypeKeys("\\x11") == "\x11", "")
check("plain text is untouched", Flooty.decodeTypeKeys("q") == "q", "")
check("a single space stays a space (pages a pager)",
      Flooty.decodeTypeKeys(" ") == " ", "")
check("unknown escapes stay literal", Flooty.decodeTypeKeys("\\d") == "\\d", "")
check("\\\\ decodes to one backslash",
      Flooty.decodeTypeKeys("a\\\\b") == "a\\b",
      repr(Flooty.decodeTypeKeys("a\\\\b")))

# ---- JSON-level escapes: models write \x11 inside the JSON string -------------
# JSON has no \xNN; JSON threw "invalid escape character" and that exception used
# to escape the parser and kill the run (no feedback).
for (label, reply, want) in (("\\x11 (Ctrl-Q)", "{\"action\":\"type\",\"keys\":\"\\x11\"}", "\x11"),
                             ("\\e (Esc)", "{\"action\":\"type\",\"keys\":\"\\e\"}", "\e"))
    a = Flooty.extractActionJson(reply)
    got = a === nothing ? "nothing" : string(a.keys)
    check("an action using $label parses", got == want, repr(got))
end

sess = startReplSession(`zsh -i`; waitPrompt = false)
try
    sleep(1.2)
    tagIn(sess.control; mode = :agent)

    # A model writes `\r` INSIDE its JSON string: the raw reply carries `\\r`.
    replies = String["{\"action\":\"type\",\"keys\":\"echo TYPED\\\\r\"}",
                     "{\"action\":\"done\",\"summary\":\"typed\"}"]
    i = Ref(0)
    r = runTerminalAgent!(sess, "type a line and press Enter";
                          completeFn = _ -> (i[] += 1; replies[min(i[], length(replies))]),
                          maxTurns = 4)
    tr = join(r.transcript, "\n")
    check("the loop honours the type action", occursin("type: echo TYPED\\r", tr),
          first(tr, 200))
    check("…the decoded Enter actually ran the command",
          occursin("TYPED", tailText(sess.tail)), last(tailText(sess.tail), 120))

    # Empty type: refused every time; no deterministic stop.
    empty = "{\"action\":\"type\",\"keys\":\"\"}"
    k = Ref(0)
    r2 = runTerminalAgent!(sess, "send nothing";
                           completeFn = _ -> (k[] += 1; empty), maxTurns = 4)
    t2 = join(r2.transcript, "\n")
    check("empty type actions are refused", occursin("empty keystrokes refused (1/3)", t2),
          first(t2, 160))
    check("…and the run is not stopped deterministically",
          !occursin("[stop]", t2), r2.summary)
    check("…the model keeps getting the corrective note",
          length(collect(eachmatch(r"empty keystrokes refused", t2))) == 4,
          length(collect(eachmatch(r"empty keystrokes refused", t2))))
finally
    closeSession!(sess)
end

println()
if isempty(failures)
    println("TYPE_KEYS_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
