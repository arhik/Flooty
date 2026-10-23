# journalProbe.jl — the event journal + loading a session back from it.
#
# Phase 1 of FlootyArchitecture/JOURNAL_AND_INDEX_STORE.md: every recorded turn
# also lands as a row in the journal, a session is a PROJECTION of those rows, and
# a transcript can be rebuilt after a restart. No Arrow, no embeddings.
#
# Run: julia --startup-file=no --project=. test/journalProbe.jl
using Flooty
using Flooty: journalStore, journalSessionUid, journalBindSession!,
    journalConversation, journalSessionList, journalDoctor, enableJournalPersistence!,
    disableJournalPersistence!, recordTask!, recordAgentEvent!,
    conversationTranscript
using FlootyPTYLayer: startReplSession, closeSession!, adoptSessionTerminal!,
    AgentTextEvent, AgentThinkingEvent, AgentToolCallEvent, AgentToolResultEvent
import FlootyPersistence

failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = isempty(detail) ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end

const DIR = mktempdir()
const JPATH = joinpath(DIR, "journal.sqlite")

# ---- journaling is OFF by default (headless probes stay hermetic) -------------
check("journaling is off until enabled", journalStore() === nothing)
offConv = Flooty.conversationFor("off-by-default")
recordTask!(offConv, "nothing should be written")
check("a record while OFF writes no journal file", !isfile(JPATH), JPATH)

# ---- open + schema -----------------------------------------------------------
j = enableJournalPersistence!(JPATH)
check("open_journal creates the file", isfile(JPATH), JPATH)
check("schema version is v1",
      FlootyPersistence.schema_version(j) == FlootyPersistence.JOURNAL_SCHEMA_VERSION,
      FlootyPersistence.schema_version(j))
check("doctor reports an empty journal", journalDoctor().rows == 0, journalDoctor())

# ---- a session, bound, then recorded ----------------------------------------
sess = startReplSession(`julia --startup-file=no -q`)
uid1 = Ref("")   # assigned inside the try; used by the versioning section below
try
    sleep(0.4)
    conv = Flooty.conversationFor(sess)
    uid1[] = journalBindSession!(sess, conv)
    check("binding mints a session uid", !isempty(uid1[]), uid1[])

    # Before adoption the events carry no terminal id; after it they do — and the
    # uid must NOT change (that is the re-key defect the journal removes).
    recordTask!(conv, "print 1 and stop")
    recordAgentEvent!(conv, AgentThinkingEvent("", "MONOLOGUE"))
    recordAgentEvent!(conv, AgentToolCallEvent("", "call-1", "repl", "echo 1"))
    recordAgentEvent!(conv, AgentToolResultEvent("", "call-1", true, "1"))
    recordAgentEvent!(conv, AgentTextEvent("", "Printed 1."))

    adopted = adoptSessionTerminal!(sess; name = "journal probe")
    uid2 = journalBindSession!(sess, conv)
    check("adoption does not re-key the session", uid1[] == uid2,
          string(uid1[], " / ", uid2))

    recordTask!(conv, "and now print 2")

    events = FlootyPersistence.journal_events(j; session_uid = uid1[])
    kinds = [e.kind for e in events]
    check("every recorded turn is a journal row", length(events) == 8, kinds)
    check("kinds are the message vocabulary",
          sort(kinds) == sort(["session_started", "session_adopted", "user_instruction",
                               "user_instruction", "assistant_thinking", "tool_call",
                               "tool_result", "assistant_text"]), kinds)
    check("lifecycle rows are recorded exactly once each",
          count(==("session_started"), kinds) == 1 &&
          count(==("session_adopted"), kinds) == 1)
    # Pre-adoption events honestly say "unattached"; later ones carry the tab id.
    firstTask = findfirst(e -> e.kind == "user_instruction", events)
    check("events before adoption carry no terminal id",
          events[firstTask].terminal_id == "")
    check("events after adoption carry the terminal id",
          events[end].terminal_id == adopted, (events[end].terminal_id, adopted))
    check("rows are stamped with the schema version",
          all(e -> Int(e.schema_version) == FlootyPersistence.JOURNAL_SCHEMA_VERSION, events))
    check("reasoning travels in `thinking`, never in `content`",
          any(e -> e.kind == "assistant_thinking" && e.thinking == "MONOLOGUE" &&
                   e.content === nothing, events))
    check("tool results carry their outcome",
          any(e -> e.kind == "tool_result" && e.ok === true && e.tool_call_id == "call-1",
              events))

    # ---- the projection: a session is filter(session_uid) -------------------
    rebuilt = journalConversation(uid1[])
    live = conversationTranscript(conv)
    journaled = conversationTranscript(rebuilt)
    check("journalConversation rebuilds the same transcript", journaled == live,
          string(length(journaled), " vs ", length(live), " messages"))
    check("the rebuilt transcript keeps reasoning and tool pairing",
          any(l -> occursin("(reasoning) MONOLOGUE", l), journaled) &&
          any(l -> startswith(l, "tool: 1"), journaled), journaled)
    check("an unknown session loads as an empty transcript",
          isempty(conversationTranscript(journalConversation("no-such-session"))))

    sessions = journalSessionList()
    mine = findfirst(s -> s.session_uid == uid1[], sessions)
    check("journalSessionList finds the session", mine !== nothing, length(sessions))
    if mine !== nothing
        check("…with its event count and terminal ids",
              sessions[mine].events == 8 && adopted in sessions[mine].terminal_ids,
              (sessions[mine].events, sessions[mine].terminal_ids))
    end
finally
    closeSession!(sess)
end

# ---- schema versioning ------------------------------------------------------
newer = FlootyPersistence.append_event!(j; kind = "assistant_text",
    session_uid = "future-session", role = "assistant", content = "from the future",
    schema_version = FlootyPersistence.JOURNAL_SCHEMA_VERSION + 1)
raised = try
    FlootyPersistence.journal_events(j; session_uid = "future-session")
    false
catch err
    occursin("newer than this reader", sprint(showerror, err))
end
check("a row from a NEWER schema refuses to be read (never misread)", raised, newer)

# ---- reopen: idempotent schema, data intact --------------------------------
disableJournalPersistence!()
j2 = enableJournalPersistence!(JPATH)
check("reopen keeps the schema version",
      FlootyPersistence.schema_version(j2) == FlootyPersistence.JOURNAL_SCHEMA_VERSION)
check("reopen keeps the rows", journalDoctor().rows == 9, journalDoctor().rows)
check("reopen does not replay migrations",
      length(FlootyPersistence.journal_events(j2; kind = "session_started")) == 1)

# ---- an append may never be unattributed -----------------------------------
raised = try
    FlootyPersistence.append_event!(j2; kind = "assistant_text", session_uid = "",
                                    content = "orphan")
    false
catch err
    occursin("session_uid", sprint(showerror, err))
end
check("an empty session_uid is rejected at the write path", raised)

# ---- batched append (importers) --------------------------------------------
n = FlootyPersistence.append_events!(j2, [
    (kind = "assistant_text", session_uid = uid1[], role = "assistant",
     content = "imported " * string(i)) for i in 1:5])
check("append_events! inserts in one transaction", n == 5 &&
      length(FlootyPersistence.journal_events(j2; session_uid = uid1[])) == 13,
      (n, length(FlootyPersistence.journal_events(j2; session_uid = uid1[]))))

disableJournalPersistence!()

println()
if isempty(failures)
    println("JOURNAL_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", "))
    exit(1)
end
