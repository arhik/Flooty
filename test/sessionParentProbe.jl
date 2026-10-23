# sessionParentProbe.jl — the session tree's re-parenting.
#
# The tree navigation's "make this the parent" moves a session under a new
# parent. The move has to keep the tree a TREE: the old parent's child list
# loses the session, the new one gains it, and a move that would make a
# session its own ancestor is refused.
#
#   julia --startup-file=no --project=. test/sessionParentProbe.jl
using Flooty

const SESSIONS = Flooty.SESSIONS

failures = String[]
check(ok, what) = ok ? nothing : push!(failures, what)

# A small tree: a -> b -> c, and a second root d.
SESSIONS["a"] = Flooty.ChatSession(id = "a")
SESSIONS["b"] = Flooty.ChatSession(id = "b", parent = "a")
SESSIONS["c"] = Flooty.ChatSession(id = "c", parent = "b")
SESSIONS["d"] = Flooty.ChatSession(id = "d")
SESSIONS["a"].children = ["b"]
SESSIONS["b"].children = ["c"]

# Move c under a: it leaves b, it joins a.
check(Flooty.setParent!("c", "a"), "the move was refused")
check("c" in SESSIONS["a"].children, "the new parent did not gain the child")
check(!("c" in SESSIONS["b"].children), "the old parent kept the child")
check(SESSIONS["c"].parent == "a", "the session's parent field did not follow")

# A cycle is refused: a under c would put a under its own descendant.
check(!Flooty.setParent!("a", "c"), "a cycle was allowed")
check(SESSIONS["a"].parent === nothing, "the refused move changed the tree")

# A move onto itself is refused.
check(!Flooty.setParent!("d", "d"), "a move onto itself was allowed")

# An unknown parent is refused.
check(!Flooty.setParent!("d", "nope"), "an unknown parent was allowed")

# An empty parent makes a root.
check(Flooty.setParent!("c", ""), "un-parenting was refused")
check(SESSIONS["c"].parent === nothing, "the session is still parented")
check(!("c" in SESSIONS["a"].children), "the old parent kept the child")

if isempty(failures)
    println("SESSION_PARENT_PROBE_OK")
    exit(0)
end
for f in failures
    println("FAILED: ", f)
end
println("SESSION_PARENT_PROBE_FAILED")
exit(1)
