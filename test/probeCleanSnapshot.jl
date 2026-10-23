using Flooty

# cleanSnapshotText must remove every trace of eval bookkeeping from raw
# PTY text — including orphans produced by chunk splits and hard cuts that
# the line-based scrubber cannot see (the `L_BEGIN:", "eval000001")` leak).

pua = string(Char(0xf0a7))

function assertCond(cond::Bool, label::AbstractString)
    cond || (println("FAIL[$label]"); exit(1))
end

# 1. Head-orphan: tag half cut away, only `L_BEGIN:", "eval000001")` remains.
out = Flooty.cleanSnapshotText(
    "L_BEGIN:\", \"eval000001\")julia> x = 21\n21\n")
assertCond(!occursin("eval000001", out), "head-orphan-line-blanked")
assertCond(occursin("x = 21", out) && occursin("21", out), "real-output-kept")

# 2. Full sentinel line inside otherwise-clean text.
out = Flooty.cleanSnapshotText(
    "julia> $(pua)println(\"FLOOTY_EVAL_END:\", \"eval000002\", \":ok\")\r\nINTENT_42\r\n")
assertCond(!occursin("FLOOTY", out) && !occursin(pua, out) &&
           !occursin("eval000002", out), "full-sentinel-scrubbed")
assertCond(occursin("INTENT_42", out), "result-kept")

# 3. Trailing partial tag (excerpt cut mid-word).
out = Flooty.cleanSnapshotText("result ok\njulia> FLOOTY_EVAL_BEG")
assertCond(!occursin("FLOOTY", out), "trailing-partial-tag-trimmed")

# 4. Ordinary trailing content is NEVER trimmed.
keep = "done\njulia> println(\"hi\")"
out = Flooty.cleanSnapshotText(keep)
assertCond(out == keep, "normal-tail-untouched")

# 5. _lineAlignedTail: cut lands on a line boundary, length bounded.
longText = reduce(*, ["line$(i) padding padding padding\n" for i in 1:100])
tail = Flooty._lineAlignedTail(longText, 200)
assertCond(length(tail) <= 260, "aligned-tail-bounded")   # one line slack
assertCond(startswith(longText, String(first(tail, 4))), "aligned-prefix-match")

println("CLEAN_SNAPSHOT_PROBE_OK")
