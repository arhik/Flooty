# checkPopupTagging.jl — load both packages after the per-session popup
# tagging changes; every include must parse and precompile without error.
using FlootyPTYLayer
using Flooty

# The new field exists and defaults keep legacy broadcast behavior.
fb = Flooty.AgentFeedback(title = "t", body = "b")
@assert fb.sessionId == ""
fb2 = Flooty.AgentFeedback(title = "t", body = "b", sessionId = "sid-1")
@assert fb2.sessionId == "sid-1"

println("CHECK_POPUP_TAGGING_OK")
