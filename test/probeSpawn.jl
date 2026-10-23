import FlootyPTYLayer
using FlootyPTYLayer

nullTerm(bytes) = begin
    i = findfirst(==(0x00), bytes)
    String(i === nothing ? bytes : bytes[1:i-1])
end

"""Poll-read a nonblocking master fd until deadline; tags raw errno failures."""
function readAll(master::Cint; seconds::Float64 = 4.0)
    deadline = time() + seconds
    buf = Vector{UInt8}(undef, 4096)
    parts = String[]
    while time() < deadline
        n = ccall(:read, Cssize_t, (Cint, Ptr{UInt8}, Csize_t),
                  master, buf, length(buf))
        if n > 0
            push!(parts, String(buf[1:n]))
        elseif n == 0
            push!(parts, "<<EOF>>")
            break
        else
            e = Libc.errno()
            if e == 4
                continue
            elseif e == 35
                sleep(0.02)
            else
                push!(parts, "<<errno $e>>")
                break
            end
        end
    end
    return join(parts)
end

"""Create a fresh pty pair and run the helper DIRECTLY (Julia run(), no posix_spawnp path)."""
function manualHelperTrial(label::String)
    masterFd, slaveFd = FlootyPTYLayer.createPtyPair()
    FlootyPTYLayer.setWindowSizeOn(slaveFd, FlootyPTYLayer.Winsize(24, 80))
    slavePath = nullTerm(FlootyPTYLayer.slaveDevicePath(masterFd))
    FlootyPTYLayer.makeNonBlocking!(masterFd)
    local out::String
    try
        run(`$(FlootyPTYLayer.HELPER_EXE) $slavePath - sh -c 'tty >/dev/null; echo MANUAL_MARKER'`)
        out = readAll(masterFd)
    catch e
        out = "<<threw: " * sprint(showerror, e) * ">>"
    end
    println("   [$label] master=$masterFd slave=$slavePath out=", repr(out))
    FlootyPTYLayer.closeQuietly(masterFd)
    FlootyPTYLayer.closeQuietly(slaveFd)
    return out
end

nullTerm(bytes) = begin
    i = findfirst(==(0x00), bytes)
    String(i === nothing ? bytes : bytes[1:i-1])
end

"""Replica of FlootyPTYLayer.masterReadLoop with per-syscall logging."""
function forensicLoop(h::FlootyPTYLayer.PtyHandle; seconds::Float64 = 8.0,
                      eofGraceS::Float64 = 0.0)
    buffer = Vector{UInt8}(undef, 8192)
    t0 = time()
    events = String[]
    got = String[]
    while time() - t0 < seconds
        h.open || (push!(events, "t=$(round(time()-t0;digits=3)) h.open false -> break"); break)
        n = ccall(:read, Cssize_t, (Cint, Ptr{UInt8}, Csize_t),
                  h.masterFd, buffer, length(buffer))
        if n > 0
            push!(got, String(buffer[1:n]))
            push!(events, "t=$(round(time()-t0;digits=3)) n=$n data=" *
                          repr(String(buffer[1:n])))
        elseif n == 0
            if time() - t0 < eofGraceS
                sleep(0.01)
            else
                push!(events, "t=$(round(time()-t0;digits=3)) n=0 EOF -> break")
                break
            end
        else
            e = Libc.errno()
            if e == 4
                continue
            elseif e == 35
                sleep(FlootyPTYLayer.READ_POLL_SECONDS)
            else
                push!(events, "t=$(round(time()-t0;digits=3)) n=$n errno=$e -> break")
                break
            end
        end
    end
    foreach(ev -> println("      [forensic] ", ev), events)
    println("      [forensic] collected=", repr(join(got)))
end

"""Manual spawn using the layer's own internals; caller runs its own reader."""
function manualSpawn(cmd::Cmd)
    masterFd, slaveFd = FlootyPTYLayer.createPtyPair()
    FlootyPTYLayer.setWindowSizeOn(slaveFd, FlootyPTYLayer.Winsize(24, 80))
    pid = FlootyPTYLayer.spawnChildAttached(masterFd, slaveFd, cmd)
    FlootyPTYLayer.makeNonBlocking!(masterFd)
    return FlootyPTYLayer.PtyHandle(Base.UUID(0), masterFd, pid,
                                    Channel{Vector{UInt8}}(Inf), ReentrantLock(),
                                    nothing, true)
end

function fdValid(fd::Cint)
    flags = ccall(:fcntl, Cint, (Cint, Cint), fd, FlootyPTYLayer.F_GETFL_FLAG)
    return flags >= 0 ? "valid(flags=$(flags))" : "BADFD(errno=$(Libc.errno()))"
end

"""Manual nonblocking read burst on an fd, bypassing any layer task."""
function manualRead(fd::Cint; seconds::Float64 = 1.0)
    buf = Vector{UInt8}(undef, 4096)
    parts = String[]
    deadline = time() + seconds
    while time() < deadline
        n = ccall(:read, Cssize_t, (Cint, Ptr{UInt8}, Csize_t), fd, buf, length(buf))
        if n > 0
            push!(parts, String(buf[1:n]))
        elseif n == 0
            push!(parts, "<<EOF>>")
            break
        else
            e = Libc.errno()
            e == 4 && continue
            e == 35 && (sleep(0.05); continue)
            push!(parts, "<<errno $e>>")
            break
        end
    end
    return join(parts)
end

function taskState(t::Union{Task,Nothing})
    t === nothing && return "(no task)"
    if !istaskdone(t)
        return "running"
    end
    if istaskfailed(t)
        buf = IOBuffer()
        try
            wait(t)
        catch e
            showerror(buf, e)
            bt = catch_backtrace()
            Base.show_backtrace(buf, bt)
        end
        return "FAILED: " * String(take!(buf))
    end
    return "done-ok"
end

psLine(pid) = try
    strip(read(`/bin/ps -o pid,ppid,pgid,sess,stat,tty,command -p $pid`, String))
catch e
    "ps-failed"
end

"""Run one manual spawn + forensic reader; returns collected events via print."""
function runForensicTrial(label::String, cmd::Cmd; seconds::Float64 = 8.0,
                          eofGraceS::Float64 = 0.0)
    h = manualSpawn(cmd)
    println("   [$label] pid=$(h.pid) masterFd=$(h.masterFd) grace=$(eofGraceS)s")
    forensicLoop(h; seconds, eofGraceS)
    st = Ref{Cint}(0)
    r = ccall(:waitpid, Cint, (Cint, Ptr{Cint}, Cint), h.pid, st, Cint(1))
    println("   [$label] waitpid r=$r status=$(r == h.pid ? "exit=$((st[]>>8)&0xFF) sig=$(st[]&0x7F)" : string(st[]))")
    FlootyPTYLayer.closeQuietly(h.masterFd)
end

const TRIAL_CMD = `sh -c 'sleep 1; tty >/dev/null; echo MARKER'`

println("== R1: manual spawn on CLEAN process (control, no grace) ==")
runForensicTrial("R1", TRIAL_CMD; seconds = 4.0)

println("== R2: establish poison: self-exited child, master fd LEFT OPEN ==")
g1 = spawnPty(`sh -c 'exit 0'`)
sleep(0.5)
println("   g1.pid=$(g1.pid) masterFd=$(g1.masterFd) left open, unreaped")

println("== R3: manual spawn UNDER POISON, no grace ==")
runForensicTrial("R3", TRIAL_CMD; seconds = 4.0)

println("== R4: manual spawn UNDER POISON, 1s EOF grace ==")
runForensicTrial("R4", TRIAL_CMD; seconds = 4.0, eofGraceS = 1.0)

# cleanup best effort
closePty!(g1)

println("PROBE_DONE")
