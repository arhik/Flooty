# sessionReattach.jl - reattach every per-session agent after a terminal revive.
#
# A revive creates a NEW ReplSession object behind the SAME terminal id. Every
# per-session registry here is keyed by the session OBJECT, so the revived
# session would otherwise start with no monitor, no driver, no trajectory
# monitor and an EMPTY agent brief. This is the single place that migrates
# them, so "terminal exited and was revived" reaches every agent.

"""
    migrateMonitorState!(oldSess, newSess) :: Bool

Move the per-session monitor state from a dead session object to its revived
replacement: the commissioned agent brief, the queued monitor notes and any
pending interrupt. These live in IdDicts keyed by the session OBJECT, so a
revived session would otherwise start with an EMPTY brief and lose notes the
agent had not read yet.
"""
function migrateMonitorState!(oldSess, newSess)::Bool
    oldSess === nothing && return false
    oldSess === newSess && return false
    moved = false
    lock(AGENT_BRIEF_LOCK) do
        v = get(AGENT_BRIEF, oldSess, nothing)
        if v !== nothing
            AGENT_BRIEF[newSess] = v
            delete!(AGENT_BRIEF, oldSess)
            moved = true
        end
    end
    lock(MONITOR_NOTES_LOCK) do
        v = get(MONITOR_NOTES, oldSess, nothing)
        if v !== nothing
            MONITOR_NOTES[newSess] = v
            delete!(MONITOR_NOTES, oldSess)
            moved = true
        end
    end
    lock(MONITOR_INTERRUPTS_LOCK) do
        v = get(MONITOR_INTERRUPTS, oldSess, nothing)
        if v !== nothing
            MONITOR_INTERRUPTS[newSess] = v
            delete!(MONITOR_INTERRUPTS, oldSess)
            moved = true
        end
    end
    return moved
end

"""
    reattachSession!(oldSess, newSess) :: Bool

The ONE place a revived terminal is reattached to every per-session agent.
Called from the reconnect hook after FlootyPTYLayer swapped the PTY behind an
existing tab. Order matters:

  1. stop the OLD loops (monitor, trajectory, driver) so nothing keeps
     sampling the dead session;
  2. migrate the per-session state (brief, notes, interrupts);
  3. re-register the session TREE entry so it points at the new repl;
  4. start the loops on the NEW session.
"""
function reattachSession!(oldSess, newSess)::Bool
    newSess === nothing && return false
    if oldSess !== nothing && oldSess !== newSess
        try; stopMonitor!(oldSess); catch; end
        try; stopTrajectoryMonitor!(oldSess); catch; end
        try; stopAgentRunner!(oldSess); catch; end
    end
    try; migrateMonitorState!(oldSess, newSess); catch; end
    # The session TREE holds the repl object: point it at the new session or
    # every tree walk (traces, steering, parent lookups) sees a corpse.
    tid = try
        FlootyPTYLayer.sessionIdFor(newSess)
    catch
        ""
    end
    if !isempty(tid)
        lock(SESSIONS_LOCK) do
            ts = get(SESSIONS, tid, nothing)
            ts === nothing || (ts.repl = newSess)
        end
    end
    try; startMonitor!(newSess); catch; end
    try; startTrajectoryMonitor!(newSess); catch; end
    try; startAgentRunner!(newSess); catch; end
    try
        pushMonitorNote!(newSess,
            "terminal exited and was revived; context kept";
            source = :system)
    catch
    end
    return true
end
