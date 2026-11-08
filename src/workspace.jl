using FlootyWorkspaces: Workspace, WorkspaceFolder, find_folder_for_path, is_path_in_workspace
using FlootyWorkspaces
using FlootyWorkspaces: DEFAULT_FOLDER_PERMISSIONS, LOCKED_PERMISSION
using FlootyLayout
using FlootyFileSystem

const WORKSPACE_STATE_LOCK = ReentrantLock()
const WORKSPACES = Dict{String,Workspace}()
const WORKSPACE_OWNER_ID = Ref{UUID}(uuid4())
const WORKSPACE_REQUESTS = Dict{UUID,NamedTuple}()
const WORKSPACE_REQUESTS_LOCK = ReentrantLock()

function _workspaceKey(x)::String
    x isa AbstractString && return String(x)
    x isa ReplSession && return FlootyPTYLayer.sessionIdFor(x)
    x isa ChatSession && return x.id
    x isa TerminalSession && return x.id
    x isa BrowserSession && return x.id
    return string(x)
end

function ensureWorkspace!(key::AbstractString)::Workspace
    lock(WORKSPACE_STATE_LOCK) do
        k = String(key)
        ws = get(WORKSPACES, k, nothing)
        ws === nothing || return ws
        ws = Workspace(k, WORKSPACE_OWNER_ID[])
        WORKSPACES[k] = ws
        return ws
    end
end

workspaceFor(sess) = ensureWorkspace!(_workspaceKey(sess))
workspaceFor(key::AbstractString) = ensureWorkspace!(key)

function _workspaceTokens(command::AbstractString)
    tokens = String[]
    for m in eachmatch(r"\"([^\"]+)\"|'([^']+)'|[^\s]+", String(command))
        value = m.captures[1] === nothing ? (m.captures[2] === nothing ? m.match : m.captures[2]) : m.captures[1]
        push!(tokens, String(value))
    end
    filters = String[]
    for token in tokens
        if startswith(token, "--") && occursin('=', token)
            push!(filters, split(token, "="; limit = 2)[end])
        else
            push!(filters, token)
        end
    end
    filters
end

function _looksLikePath(token::AbstractString)::Bool
    isempty(token) && return false
    startswith(token, "http://") && return false
    startswith(token, "https://") && return false
    token == "--" && return false
    occursin('/', token) || startswith(token, "~") || startswith(token, ".") || occursin(r"\.[A-Za-z0-9_-]{1,10}$", token)
end

function _writeish(command::AbstractString)::Bool
    occursin(r"(^|[\s;(|&])(rm|mv|cp|ln|touch|mkdir|rmdir|chmod|chown|chgrp|truncate|dd|install|apply_patch|patch|tee|scp|rsync|git\s+apply|sed\s+-i|sort\s+-o|perl\s+-pi|ruby\s+-i|xattr|setfattr)(\s|$)", String(command)) ||
        occursin(r"(>>|(^|\s)>)", String(command))
end

function _copyish(command::AbstractString)::Bool
    occursin(r"(^|[\s;(|&])(cp|rsync|ln|install)(\s|$)", String(command))
end

function workspaceCommandPermitted(command::AbstractString, sess)
    ws = ensureWorkspace!(_workspaceKey(sess))
    tokens = _workspaceTokens(command)
    paths = String[]
    for token in tokens
        _looksLikePath(token) || continue
        expanded = expanduser(token)
        push!(paths, abspath(expanded))
    end
    isempty(paths) && return (true, "")
    writeish = _writeish(command)
    if writeish && _copyish(command) && length(paths) >= 2
        for path in paths[1:end-1]
            if !FlootyWorkspaces.can_read(ws, path)
                _requestWorkspaceAttention!(ws, _workspaceKey(sess), path, "read", "agent needs read access")
                return (false, "read denied at $path; permission requested")
            end
        end
        dst = paths[end]
        if !FlootyWorkspaces.can_write(ws, dst)
            _requestWorkspaceAttention!(ws, _workspaceKey(sess), dst, "write", "agent needs write access")
            return (false, "write denied at $dst; permission requested")
        end
        return (true, "")
    elseif writeish
        for path in paths
            if !FlootyWorkspaces.can_write(ws, path)
                _requestWorkspaceAttention!(ws, _workspaceKey(sess), path, "write", "agent needs write access")
                return (false, "write denied at $path; permission requested")
            end
        end
        return (true, "")
    else
        for path in paths
            if !FlootyWorkspaces.can_read(ws, path)
                _requestWorkspaceAttention!(ws, _workspaceKey(sess), path, "read", "agent needs read access")
                return (false, "read denied at $path; permission requested")
            end
        end
        return (true, "")
    end
end

function _attentionInfo(folderId::UUID)
    lock(WORKSPACE_REQUESTS_LOCK) do
        get(WORKSPACE_REQUESTS, folderId, nothing)
    end
end

function _attentionInfo(folderId::AbstractString)
    fid = tryparse(UUID, String(folderId))
    fid === nothing && return nothing
    _attentionInfo(fid)
end

function folderAttention(folder::WorkspaceFolder)
    _attentionInfo(folder.id)
end

function _setAttention!(folder::WorkspaceFolder, reason::AbstractString, operation::AbstractString)
    path = folder.path
    entry = (path = path,
             reason = String(reason),
             operation = String(operation),
             name = folder.name,
             requested_at = time())
    lock(WORKSPACE_REQUESTS_LOCK) do
        WORKSPACE_REQUESTS[folder.id] = entry
    end
    return entry
end

function _clearAttention!(folderId::UUID)
    lock(WORKSPACE_REQUESTS_LOCK) do
        pop!(WORKSPACE_REQUESTS, folderId, nothing)
    end
end

function _requestFolder!(ws::Workspace, key::AbstractString, path::AbstractString, operation::AbstractString, reason::AbstractString)
    target = try
        normpath(abspath(String(path)))
    catch
        return nothing
    end
    target == "" && return nothing
    existing = nothing
    for folder in values(ws.folders)
        contains_path(folder, target) && (existing = folder; break)
    end
    folder = existing
    was_attention = folder !== nothing && _attentionInfo(folder.id) !== nothing
    if folder === nothing
        if isdir(target)
            folder = FlootyWorkspaces.add_folder_to_workspace!(ws, target;
                name = basename(target),
                added_by = WORKSPACE_OWNER_ID[],
                recursive = true,
                readonly = true,
                permissions = Symbol[])
        else
            folder = FlootyWorkspaces.add_pending_folder_to_workspace!(ws, target;
                name = basename(target),
                added_by = WORKSPACE_OWNER_ID[],
                recursive = true,
                readonly = true,
                permissions = Symbol[])
        end
    end
    if !was_attention
        note = string("workspace permission requested: ", operation, " access to '", folder.name, "' (", folder.path, ") — awaiting user review")
        try
            pushMonitorNote!(String(key), note; source = :workspace)
        catch err
            @debug "workspace permission request note failed" exception = err
        end
        try
            workspace_file_change!(key, string(folder.id), note, "permission_request")
        catch err
            @debug "workspace permission request push failed" exception = err
        end
    end
    _setAttention!(folder, reason, operation)
    return folder
end

function _requestWorkspaceAttention!(ws::Workspace, key::AbstractString, path::AbstractString, operation::AbstractString, reason::AbstractString)
    _requestFolder!(ws, key, path, operation, reason)
end

function _setAttentionAndNotify!(ws::Workspace, key::AbstractString, folder::WorkspaceFolder, operation::AbstractString, reason::AbstractString)
    existing = _attentionInfo(folder.id)
    if existing === nothing
        note = string("workspace permission requested: ", operation, " access to '", folder.name, "' (", folder.path, ") — awaiting user review")
        try
            pushMonitorNote!(String(key), note; source = :workspace)
        catch err
            @debug "workspace permission request note failed" exception = err
        end
        try
            workspace_file_change!(key, string(folder.id), note, "permission_request")
        catch err
            @debug "workspace permission request push failed" exception = err
        end
    end
    _setAttention!(folder, reason, operation)
    return folder
end

function workspaceToolPermissionRequest!(key::AbstractString, folderId::Union{AbstractString,UUID,Nothing}, operation::AbstractString, reason::AbstractString)
    ws = ensureWorkspace!(key)
    targets = WorkspaceFolder[]
    if folderId !== nothing
        fid = folderId isa UUID ? folderId : tryparse(UUID, String(folderId))
        if fid !== nothing
            folder = folderById(ws, fid)
            folder !== nothing && push!(targets, folder)
        end
    else
        for folder in listWorkspaceFolders(key)
            hasFolderPermission(folder, :read) || push!(targets, folder)
        end
    end
    for folder in targets
        _setAttentionAndNotify!(ws, key, folder, operation, reason)
    end
    return !isempty(targets)
end

function _attentionNote(folder::WorkspaceFolder, newPerms::Vector{Symbol})
    path = folder.path
    perms = LOCKED_PERMISSION in newPerms ? "locked" : join(String[String(p) for p in newPerms], ",")
    return string("workspace permission updated for folder '", folder.name, "' (", path, "): ", perms)
end

function _permissionChanged!(key::AbstractString, folder::WorkspaceFolder, note::AbstractString)
    _clearAttention!(folder.id)
    try
        pushMonitorNote!(String(key), note; source = :workspace)
    catch err
        @debug "workspace permission note failed" exception = err
    end
    try
        workspace_file_change!(key, string(folder.id), note, "permission_change")
    catch err
        @debug "workspace permission push failed" exception = err
    end
    if LOCKED_PERMISSION in folder.permissions
        _unwatchFolderTree!(folder)
    else
        _watchFolderTree!(key, folder)
    end
    return nothing
end
function _layoutForSession(sess)
    sess isa ChatSession && return FlootyLayout.CHAT_LAYOUT
    sess isa BrowserSession && return FlootyLayout.BROWSER_LAYOUT
    return FlootyLayout.TERMINAL_LAYOUT
end

function _sessionForWorkspaceKey(key::AbstractString)
    k = isempty(String(key)) ? _workspaceKey(ensureRootChatSession!()) : String(key)
    sess = sessionForId(k)
    return sess, k
end

function ensureDefaultWorkspace!(sess)
    ws = ensureWorkspace!(_workspaceKey(sess))
    if sess isa TerminalSession && isempty(ws.folder_order)
        FlootyWorkspaces.ensure_workspace_folder!(ws, pwd(); name = basename(abspath(pwd())))
    end
    return ws
end

workspaceLayout(sess) = _layoutForSession(sess)

function _watchDirectory(key::AbstractString, folder::WorkspaceFolder, relDir::Union{Nothing,AbstractString})
    target = relDir === nothing ? folder.path : joinpath(folder.path, relDir)
    isdir(target) || return nothing
    folderId = string(folder.id)
    try
        FlootyFileSystem.start_file_watcher(target; callback = (rel, action) -> workspace_file_change!(key, folderId, rel, action), interval = 0.01)
    catch err
        @debug "FlootyFileSystem watcher failed" path = target exception = err
    end
    return nothing
end

function _watchFolderTree!(key::AbstractString, folder::WorkspaceFolder; maxDepth::Int = 1)
    _watchDirectory(key, folder, nothing)
    baseDepth = length(splitpath(folder.path))
    try
        for (root, dirs, files) in walkdir(folder.path)
            depth = length(splitpath(root)) - baseDepth
            depth >= maxDepth && continue
            for dir in dirs
                _watchDirectory(key, folder, relpath(joinpath(root, dir), folder.path))
            end
        end
    catch err
        @debug "FlootyFileSystem tree watch failed" path = folder.path exception = err
    end
    return nothing
end

function _unwatchFolderTree!(folder::WorkspaceFolder; maxDepth::Int = 1)
    targets = Set{String}([folder.path])
    try
        for (root, dirs, files) in walkdir(folder.path)
            if length(splitpath(root)) - length(splitpath(folder.path)) >= maxDepth
                continue
            end
            push!(targets, root)
        end
    catch
    end
    for target in targets
        try
            FlootyFileSystem.stop_file_watcher(target)
        catch
        end
    end
    return nothing
end

function workspace_file_change!(key::AbstractString, folderId::AbstractString, path::AbstractString, action::AbstractString)
    sid = isempty(key) ? "" : String(key)
    try
        wv = FlootyPTYLayer.activeTerminalUiWebview()
        wv === nothing && return nothing
        payload = Dict("session_id" => sid, "folder_id" => String(folderId), "path" => String(path), "action" => String(action))
        script = "window.handleWorkspaceFileChange && window.handleWorkspaceFileChange(" * JSON.json(payload) * ");"
        FlootyPTYLayer.Webviews.dispatch(wv) do
            try
                FlootyPTYLayer.Webviews.eval!(wv, script)
            catch err
                @debug "Flooty workspace file change push failed" exception = err
            end
        end
    catch err
        @debug "Flooty workspace file change failed" exception = err
    end
    return nothing
end

function folderPermissions(folder::WorkspaceFolder)::Vector{Symbol}
    copy(folder.permissions)
end

function setFolderPermissions!(folder::WorkspaceFolder, perms::Vector{Symbol})
    empty!(folder.permissions)
    append!(folder.permissions, perms)
    return folder
end

function hasFolderPermission(folder::WorkspaceFolder, permission::Symbol)::Bool
    FlootyWorkspaces.has_permission(folder, permission)
end

function isFolderLocked(folder::WorkspaceFolder)::Bool
    LOCKED_PERMISSION in folder.permissions
end

function folderInfo(folder::WorkspaceFolder)
    perms = folderPermissions(folder)
    locked = LOCKED_PERMISSION in perms
    (id = string(folder.id),
     name = folder.name,
     path = folder.path,
     readonly = folder.readonly,
     permissions = locked ? String["locked"] : String[String(p) for p in perms],
     locked = locked,
     can_read = !locked && :read in perms,
     can_write = !locked && :write in perms && !folder.readonly,
     can_execute = !locked && :execute in perms)
end

function folderInfoPublic(folder::WorkspaceFolder)
    info = folderInfo(folder)
    return (id = info.id,
            name = info.name,
            permissions = info.permissions,
            locked = info.locked,
            can_read = info.can_read,
            can_write = info.can_write,
            can_execute = info.can_execute)
end

function _folderStats(folder::WorkspaceFolder; maxEntries::Int = 1000, maxDepth::Int = 4)
    files = 0
    dirs = 0
    truncated = false
    try
        for (root, dirnames, filenames) in walkdir(folder.path)
            rel = relpath(root, folder.path)
            depth = rel == "." ? 0 : length(splitpath(rel)) - 1
            depth > maxDepth && continue
            dirs += length(dirnames)
            files += length(filenames)
            if files + dirs >= maxEntries
                truncated = true
                break
            end
        end
    catch
    end
    return (file_count = files, dir_count = dirs, count_truncated = truncated)
end

function folderInfoForUI(folder::WorkspaceFolder)
    info = folderInfo(folder)
    stats = _folderStats(folder)
    attention = folderAttention(folder)
    attention_reason = attention === nothing ? "" : string(get(attention, :operation, "access"), ": ", get(attention, :reason, ""))
    return (id = info.id,
            name = info.name,
            path = info.path,
            readonly = info.readonly,
            permissions = info.permissions,
            locked = info.locked,
            can_read = info.can_read,
            can_write = info.can_write,
            can_execute = info.can_execute,
            file_count = stats.file_count,
            dir_count = stats.dir_count,
            count_truncated = stats.count_truncated,
            attention = attention !== nothing,
            attention_reason = attention_reason,
            attention_operation = attention === nothing ? "" : string(get(attention, :operation, "")))
end

function listWorkspaceFolderInfosForUI(key::AbstractString)
    out = NamedTuple[]
    ws = ensureWorkspace!(key)
    for id in ws.folder_order
        folder = get(ws.folders, id, nothing)
        folder === nothing && continue
        push!(out, folderInfoForUI(folder))
    end
    return out
end

function listWorkspaceFolders(key::AbstractString)
    ws = ensureWorkspace!(key)
    out = WorkspaceFolder[]
    for id in ws.folder_order
        folder = get(ws.folders, id, nothing)
        folder === nothing && continue
        push!(out, folder)
    end
    return out
end

function listWorkspaceFolderInfos(key::AbstractString)
    ws = ensureWorkspace!(key)
    out = NamedTuple[]
    for id in ws.folder_order
        folder = get(ws.folders, id, nothing)
        folder === nothing && continue
        push!(out, folderInfo(folder))
    end
    return out
end

function listWorkspaceFolderInfosPublic(key::AbstractString)
    out = NamedTuple[]
    for info in listWorkspaceFolderInfos(key)
        push!(out, (id = info.id, name = info.name, permissions = info.permissions,
                    locked = info.locked, can_read = info.can_read,
                    can_write = info.can_write, can_execute = info.can_execute))
    end
    return out
end

function addWorkspaceFolder!(key::AbstractString, path::AbstractString; name = "", readonly::Bool = false, recursive::Bool = true)
    expanded = expanduser(String(path))
    isdir(abspath(expanded)) || throw(ArgumentError("Workspace folder does not exist: $expanded"))
    ws = ensureWorkspace!(key)
    folder = FlootyWorkspaces.add_folder_to_workspace!(ws, expanded;
        name = isempty(String(name)) ? basename(abspath(expanded)) : String(name),
        added_by = WORKSPACE_OWNER_ID[],
        recursive = Bool(recursive),
        readonly = Bool(readonly),
        permissions = copy(DEFAULT_FOLDER_PERMISSIONS))
    _watchFolderTree!(key, folder)
    return folder
end

function addWorkspaceFolder!(sess, path::AbstractString; kwargs...)
    addWorkspaceFolder!(_workspaceKey(sess), path; kwargs...)
end

function removeWorkspaceFolder!(key::AbstractString, folderId::Union{AbstractString,UUID})
    ws = ensureWorkspace!(key)
    fid = folderId isa UUID ? folderId : tryparse(UUID, String(folderId))
    fid === nothing && return false
    folder = folderById(ws, fid)
    folder === nothing && return false
    _unwatchFolderTree!(folder)
    _clearAttention!(folder.id)
    removed = FlootyWorkspaces.remove_folder_from_workspace!(ws, fid)
    return removed
end

removeWorkspaceFolder!(sess, folderId) = removeWorkspaceFolder!(_workspaceKey(sess), folderId)

function folderById(ws::Workspace, folderId::Union{AbstractString,UUID})
    fid = folderId isa UUID ? folderId : tryparse(UUID, String(folderId))
    fid === nothing && return nothing
    return FlootyWorkspaces.get_folder_from_workspace(ws, fid)
end

function toggleWorkspacePermission!(key::AbstractString, folderId::Union{AbstractString,UUID}, permission::AbstractString)
    permission = lowercase(String(permission))
    perm = Symbol(permission)
    fid = folderId isa UUID ? folderId : tryparse(UUID, String(folderId))
    fid === nothing && return nothing
    ws = ensureWorkspace!(key)
    folder = folderById(ws, fid)
    folder === nothing && return nothing
    lock(WORKSPACE_STATE_LOCK) do
        if perm === :read || perm === :write || perm === :execute
            FlootyWorkspaces.toggle_permission!(folder, perm)
        elseif perm === LOCKED_PERMISSION
            FlootyWorkspaces.toggle_permission!(folder, perm)
        else
            throw(ArgumentError("Unknown permission: $permission"))
        end
    end
    note = _attentionNote(folder, copy(folder.permissions))
    _permissionChanged!(key, folder, note)
    return folderInfoForUI(folder)
end

toggleWorkspacePermission!(sess, folderId, permission::AbstractString) =
    toggleWorkspacePermission!(_workspaceKey(sess), folderId, permission)

function workspaceSummary(key::AbstractString)
    ws = ensureWorkspace!(key)
    infos = listWorkspaceFolderInfosForUI(key)
    (workspace_id = string(ws.id),
     name = ws.name,
     folder_count = length(infos),
     readable = count(i -> i.can_read, infos),
     writable = count(i -> i.can_write, infos),
     executable = count(i -> i.can_execute, infos),
     locked = count(i -> i.locked, infos),
     attention_count = count(i -> i.attention, infos))
end

function _safeJoin(root::AbstractString, rel::AbstractString)
    rel = replace(String(rel), "\\" => "/")
    rel = strip(rel)
    occursin("\0", rel) && return nothing
    parts = split(rel, "/")
    parts = [p for p in parts if p != "" && p != "."]
    any(p -> p == "..", parts) && return nothing
    candidate = abspath(joinpath(root, parts...))
    rootNorm = replace(abspath(root), "\\" => "/")
    candNorm = replace(candidate, "\\" => "/")
    (candNorm == rootNorm || startswith(candNorm, rootNorm * "/")) && return candidate
    return nothing
end

function readWorkspaceFile(key::AbstractString, folderId::Union{AbstractString,UUID}, filePath::AbstractString; maxBytes::Integer = 65536)
    ws = ensureWorkspace!(key)
    folder = folderById(ws, folderId)
    folder === nothing && return (false, "")
    hasFolderPermission(folder, :read) || return (false, "Folder is locked or read permission is disabled")
    target = isabspath(filePath) ? abspath(String(filePath)) : _safeJoin(folder.path, String(filePath))
    target === nothing && return (false, "Path is outside the folder")
    replace(abspath(target), "\\" => "/") == replace(folder.path, "\\" => "/") ||
        startswith(replace(abspath(target), "\\" => "/"), replace(folder.path, "\\" => "/") * "/") ||
        return (false, "Path is outside the folder")
    isfile(target) || return (false, "Not a file: $filePath")
    try
        data = read(target)
        length(data) <= maxBytes || return (false, "File too large: $(length(data)) bytes")
        return (true, String(data))
    catch err
        return (false, sprint(showerror, err))
    end
end

function writeWorkspaceFile(key::AbstractString, folderId::Union{AbstractString,UUID}, filePath::AbstractString, content::AbstractString)
    ws = ensureWorkspace!(key)
    folder = folderById(ws, folderId)
    folder === nothing && return (false, "Folder not found")
    hasFolderPermission(folder, :write) || return (false, "Folder is locked or write permission is disabled")
    folder.readonly && return (false, "Folder is readonly")
    target = isabspath(filePath) ? abspath(String(filePath)) : _safeJoin(folder.path, String(filePath))
    target === nothing && return (false, "Path is outside the folder")
    replace(abspath(target), "\\" => "/") == replace(folder.path, "\\" => "/") ||
        startswith(replace(abspath(target), "\\" => "/"), replace(folder.path, "\\" => "/") * "/") ||
        return (false, "Path is outside the folder")
    try
        mkpath(dirname(target))
        write(target, String(content))
        return (true, relpath(target, folder.path))
    catch err
        return (false, sprint(showerror, err))
    end
end

function listWorkspaceFiles(key::AbstractString, folderId::Union{AbstractString,UUID}; recursive::Bool = true, limit::Integer = 200, maxDepth::Int = 4)
    ws = ensureWorkspace!(key)
    folder = folderById(ws, folderId)
    folder === nothing && return (false, String[])
    hasFolderPermission(folder, :read) || return (false, String[])
    out = String[]
    try
        for (root, dirs, files) in walkdir(folder.path)
            depth = count(==(Base.Filesystem.path_separator), relpath(root, folder.path)) + (relpath(root, folder.path) == "." ? 0 : 1)
            depth > maxDepth && continue
            for file in files
                push!(out, relpath(joinpath(root, file), folder.path))
                length(out) >= limit && return (true, out)
            end
            recursive || empty!(dirs)
        end
        return (true, out)
    catch err
        return (false, String[])
    end
end

function searchWorkspaceFiles(key::AbstractString, query::AbstractString, folderId::Union{AbstractString,UUID,Nothing} = nothing; maxResults::Int = 50, maxBytes::Integer = 262144)
    needle = lowercase(String(query))
    isempty(needle) && return (false, [])
    ws = ensureWorkspace!(key)
    folders = folderId === nothing ?
        [get(ws.folders, id, nothing) for id in ws.folder_order] :
        [folderById(ws, folderId)]
    out = Dict{String,String}[]
    for folder in folders
        folder === nothing && continue
        hasFolderPermission(folder, :read) || continue
        try
            for (root, dirs, files) in walkdir(folder.path)
                for file in files
                    target = joinpath(root, file)
                    try
                        size = filesize(target)
                        size > maxBytes && continue
                        content = read(target)
                        occursin(needle, lowercase(String(content))) || continue
                        push!(out, Dict("folder_id" => string(folder.id),
                                        "file" => relpath(target, folder.path)))
                        length(out) >= maxResults && return (true, out)
                    catch
                        continue
                    end
                end
            end
        catch err
            return (false, out)
        end
    end
    return (true, out)
end

function workspaceUIState(session_id::AbstractString = "")
    sess, key = _sessionForWorkspaceKey(session_id)
    ws = ensureWorkspace!(key)
    layout = workspaceLayout(sess)
    folders = listWorkspaceFolderInfosForUI(key)
    summary = workspaceSummary(key)
    return (success = true,
            workspace_id = string(ws.id),
            name = ws.name,
            kind = string(layout.kind),
            layout = string(layout.kind),
            workspace_visible = FlootyLayout.workspaceVisible(layout),
            terminal = FlootyLayout.terminalVisible(layout),
            folders = folders,
            summary = summary)
end

function workspaceUIAdd(session_id::AbstractString, path::AbstractString, name::AbstractString = "")
    key = isempty(String(session_id)) ? _workspaceKey(ensureRootChatSession!()) : String(session_id)
    folder = addWorkspaceFolder!(key, String(path); name = String(name))
    return (success = true, folder = folderInfoForUI(folder))
end

function workspaceUIRemove(session_id::AbstractString, folder_id::AbstractString)
    key = isempty(String(session_id)) ? _workspaceKey(ensureRootChatSession!()) : String(session_id)
    removed = removeWorkspaceFolder!(key, String(folder_id))
    return (success = Bool(removed))
end

function workspaceUIToggle(session_id::AbstractString, folder_id::AbstractString, permission::AbstractString)
    key = isempty(String(session_id)) ? _workspaceKey(ensureRootChatSession!()) : String(session_id)
    info = toggleWorkspacePermission!(key, String(folder_id), String(permission))
    info === nothing && return (success = false, error = "Folder not found")
    ws = ensureWorkspace!(key)
    folder = folderById(ws, String(folder_id))
    folder === nothing && return (success = true, folder = info)
    return (success = true, folder = folderInfoForUI(folder))
end

function workspaceUISummary(session_id::AbstractString = "")
    key = isempty(String(session_id)) ? _workspaceKey(ensureRootChatSession!()) : String(session_id)
    return (success = true, summary = workspaceSummary(key))
end

folderPublic(folder::WorkspaceFolder) = folderInfoPublic(folder)
folderPublic(info::NamedTuple) = info


