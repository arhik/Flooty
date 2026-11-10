"File tree compound session: an addressable, standalone workspace navigator panel."

function launchFileTreeSession!(parent_id::AbstractString = "";
                                folder_id::AbstractString = "",
                                name::AbstractString = "File tree")
    root = ensureRootChatSession!()
    parent = isempty(parent_id) ? nothing : sessionForId(parent_id)
    sess = registerSession!(FileTreeSession(
        id = "filetree-" * string(uuid4()),
        parent = parent === nothing ? nothing : parent.id,
        folder_id = String(folder_id)))
    if parent isa AbstractSession
        push!(parent.children, sess.id)
    end
    wv = FlootyPTYLayer.activeTerminalUiWebview()
    if wv !== nothing
        FlootyPTYLayer.addFileTreeTabUi(wv, sess.id, String(name);
                                        root_id = root.id,
                                        parent_id = parent === nothing ? "" : parent.id)
        startFileTreeMonitor!(sess, wv)
    end
    return sess
end

newFileTreeSessionHandler(parent_id::AbstractString = "", folder_id::AbstractString = "",
                          name::AbstractString = "File tree") =
    launchFileTreeSession!(parent_id; folder_id = folder_id, name = isempty(name) ? "File tree" : name)

function startFileTreeMonitor!(sess::FileTreeSession, wv = nothing)
    startChatMonitor!(sess.id; note_key = sess, wv = wv)
    startTrajectoryMonitor!(sess)
    return true
end
