"Typst compound session: an editor child and a PDF child bound to one project."

using Base64

import FlootyEditor
import FlootyTypst
import FlootyFileTree

const TYPST_COMPILE_TIMERS = Dict{String,Task}()
const TYPST_COMPILE_LOCK = ReentrantLock()

function editorChildPathFor(project::FlootyTypst.TypstProject)
    editorChild = FlootyEditor.editor_session(project.editor_id)
    editorChild.path
end

function projectRootOf(project::FlootyTypst.TypstProject)
    project.project_root
end

function registerTypstChild!(child; parent::AbstractSession)
    registerSession!(child)
    if !(child.id in parent.children)
        push!(parent.children, child.id)
    end
    child
end

# A child agent turn can ask the compiler to run in a task; keep one pending
# compile per project rather than racing every keystroke.
function scheduleTypstCompile(project::FlootyTypst.TypstProject; delay_s::Real = 0.45)
    task = lock(TYPST_COMPILE_LOCK) do
        existing = get(TYPST_COMPILE_TIMERS, project.id, nothing)
        if existing !== nothing && !istaskdone(existing)
            try; schedule(existing, InterruptException(); error = false); catch; end
        end
        t = @async begin
            try
                sleep(Float64(delay_s))
                FlootyTypst.save_source!(project)
                FlootyTypst.compile_project!(project)
                wv = FlootyPTYLayer.activeTerminalUiWebview()
                if wv !== nothing
                    pdf = FlootyPDF.pdf_session(project.pdf_id)
                    bytes = pdf.bytes
                    if !isempty(bytes)
                        script = "if (window.typstPdfLayer && window.typstPdfLayer.api) { window.typstPdfLayer.api().loadBytes(\"" *
                                 base64encode(bytes) * "\", \"" * escapeJsString(
                                 splitext(basename(project.path))[1] * ".pdf") * "\"); }"
                        FlootyPTYLayer.Webviews.dispatch(wv) do
                            FlootyPTYLayer.Webviews.eval!(wv, script)
                        end
                    end
                    pushAgentEventToWindow(wv,
                        AgentMonitorThinkingEvent(project.id, "typst compile ok"; monitor = :typst))
                end
            catch err
                pushAgentEventToWindow(FlootyPTYLayer.activeTerminalUiWebview(),
                    AgentMonitorThinkingEvent(project.id, "typst compile error: $(err)"; monitor = :typst))
            end
        end
        TYPST_COMPILE_TIMERS[project.id] = t
        t
    end
    return task
end

function launchTypstSession!(parent_id::AbstractString = "";
                             path::AbstractString = "",
                             name::AbstractString = "Typst")
    root = ensureRootChatSession!()
    parent = isempty(parent_id) ? nothing : sessionForId(parent_id)
    rawPath = normpath(expanduser(strip(String(path))))
    isempty(rawPath) && throw(ArgumentError("typst path cannot be empty"))
    isdir(rawPath) || isfile(rawPath) || throw(ArgumentError("typst path not found: $rawPath"))
    project = FlootyTypst.open_typst_project(rawPath; id = "typst-" * string(uuid4()),
                                               parent = parent === nothing ? nothing : parent.id)
    sess = registerSession!(TypstSession(
        id = project.id,
        parent = parent === nothing ? nothing : parent.id,
        path = project.path,
        project_root = project.project_root,
        editor_id = project.editor_id,
        pdf_id = project.pdf_id,
        url = "typst:" * project.id))
    editor = FlootyEditor.editor_session(project.editor_id)
    registerSession!(editor)
    push!(sess.children, editor.id)
    pdf = FlootyPDF.pdf_session(project.pdf_id)
    registerSession!(pdf)
    push!(sess.children, pdf.id)
    if parent isa AbstractSession
        push!(parent.children, sess.id)
    end
    wv = FlootyPTYLayer.activeTerminalUiWebview()
    if wv !== nothing
        linkAndLaunch(wv, sess, editor;
                      root_id = root.id,
                      parent_id = parent === nothing ? "" : parent.id)
    end
    return sess
end

function linkAndLaunch(wv, sess, editor; root_id::AbstractString, parent_id::AbstractString)
    FlootyPTYLayer.addTypstTabUi(wv, sess.id, "Typst", sess.project_root,
                                  sess.editor_id, sess.pdf_id; root_id = root_id, parent_id = parent_id)
    payload = Dict(
        "session" => sess.editor_id,
        "path" => editor.path,
        "projectRoot" => sess.project_root,
        "content" => editor.content
    )
    try
        FlootyPTYLayer.Webviews.dispatch(wv) do
            script = "if (window.editorLayer && typeof window.editorLayer.open === 'function') window.editorLayer.open(\"" * escapeJsString(sess.editor_id) *
                     "\", JSON.parse(\"" * escapeJsString(JSON.json(payload)) * "\"));"
            FlootyPTYLayer.Webviews.eval!(wv, script)
        end
    catch err
        @debug "Typst editor load failed" exception = err
    end
    FlootyTypst.compile_project!(FlootyTypst.typst_project(sess.id))
    return true
end

const WORKSPACE_STATE = Dict{String,Any}()
const WORKSPACE_LOCK = ReentrantLock()

function workspaceJson(payload)
    JSON.json(payload)
end

function _workspaceMetadata(tree, workspace)
    Dict(
        "id" => string(workspace.id),
        "name" => workspace.name,
        "roots" => [Dict(
            "id" => string(folder.id),
            "path" => folder.path,
            "name" => folder.name,
            "permissions" => [String(permission) for permission in folder.permissions],
            "readonly" => folder.readonly) for folder in workspace_folders(workspace)]
    )
end

function _workspaceEntries(tree)
    [Dict(
        "name" => entry.name,
        "path" => entry.path,
        "isDir" => entry.is_directory,
        "depth" => entry.depth,
        "hidden" => entry.hidden,
        "expanded" => entry.is_directory && (entry.path in tree.expanded),
        "modified" => Dates.format(entry.modified, "yyyy-mm-ddTHH:MM:SSZ")
    ) for entry in FlootyFileTree.list_tree(tree; include_root = false, refresh = true)]
end

function workspaceStateJson(session_id::AbstractString, root::AbstractString)
    sess = sessionForId(session_id)
    projectId = sess isa TypstSession ? sess.id : (sess === nothing || !(sess isa FlootyEditor.EditorSession) ? "" : String(sess.parent))
    project = isempty(projectId) ? nothing : try FlootyTypst.typst_project(projectId) catch; nothing end
    base = project === nothing ? String(root) : project.project_root
    isdir(base) || return workspaceJson(Dict("success" => false, "error" => "folder not found: $base", "entries" => Any[]))
    key = "tree-" * String(session_id)
    state = lock(WORKSPACE_LOCK) do
        found = get(WORKSPACE_STATE, key, nothing)
        if found === nothing
            tree = FlootyFileTree.create_tree(base; id = "workspace-tree-" * String(session_id), max_depth = 8)
            workspace = FlootyWorkspace.create_workspace("Example")
            folder = FlootyWorkspace.add_folder!(workspace, base; added_by = "workspace")
            push!(WORKSPACE_STATE, key => (tree = tree, workspace = workspace, root = base))
            return WORKSPACE_STATE[key]
        elseif found.root != base
            try FlootyFileTree.remove_tree!(found.tree) catch; end
            tree = FlootyFileTree.create_tree(base; id = "workspace-tree-" * String(session_id), max_depth = 8)
            workspace = FlootyWorkspace.create_workspace("Example")
            folder = FlootyWorkspace.add_folder!(workspace, base; added_by = "workspace")
            WORKSPACE_STATE[key] = (tree = tree, workspace = workspace, root = base)
            return WORKSPACE_STATE[key]
        end
        found
    end
    Dict(
        "success" => true,
        "name" => state.workspace.name,
        "path" => state.root,
        "entries" => _workspaceEntries(state.tree),
        "permissions" => ["read", "write", "execute"]
    ) |> workspaceJson
end

function workspaceToggleHandler(session_id::AbstractString, target::AbstractString)
    key = "tree-" * String(session_id)
    found = lock(WORKSPACE_LOCK) do
        state = get(WORKSPACE_STATE, key, nothing)
        if state !== nothing
            candidate = String(target)
            if isfile(candidate)

            elseif isdir(candidate)
                path = normpath(expanduser(candidate))
                FlootyFileTree.toggle_directory!(state.tree, path)
            end
        end
        state
    end
    found === nothing && return workspaceStateJson(session_id, "")
    Dict(
        "success" => true,
        "path" => found.root,
        "entries" => _workspaceEntries(found.tree)
    ) |> workspaceJson
end

function workspaceCloseHandler(session_id::AbstractString)
    key = "tree-" * String(session_id)
    found = lock(WORKSPACE_LOCK) do
        get(WORKSPACE_STATE, key, nothing)
    end
    if found !== nothing
        try FlootyFileTree.remove_tree!(found.tree) catch; end
        lock(WORKSPACE_LOCK) do
            delete!(WORKSPACE_STATE, key)
        end
    end
    workspaceJson(Dict("success" => true, "entries" => Any[]))
end

function workspaceActionHandler(kind::AbstractString, session_id::AbstractString, payload::AbstractDict)
    action = lowercase(String(kind))
    root = String(get(payload, :root, get(payload, "root", "")))
    if action == "refresh" || action == "state" || action == "open"
        return workspaceStateJson(String(session_id), root)
    elseif action == "toggle"
        target = String(get(payload, :path, get(payload, "path", "")))
        return workspaceToggleHandler(String(session_id), target)
    elseif action == "close"
        return workspaceCloseHandler(String(session_id))
    end
    workspaceJson(Dict("success" => false, "error" => "unsupported workspace action: $action", "entries" => Any[]))
end

function editorEventHandler(kind::AbstractString, session_id::AbstractString, payload)
    editor = sessionForId(session_id)
    editor isa FlootyEditor.EditorSession || return nothing
    projectId = editor.parent === nothing ? "" : String(editor.parent)
    isempty(projectId) && return nothing
    project = try
        FlootyTypst.typst_project(projectId)
    catch
        return nothing
    end
    k = lowercase(String(kind))
    if k == "change"
        content = String(get(payload, :content, get(payload, "content", "")))
        FlootyEditor.set_content!(editor, content; source = "user")
        scheduleTypstCompile(project)
        return nothing
    elseif k == "save"
        content = String(get(payload, :content, get(payload, "content", editor.content)))
        FlootyEditor.set_content!(editor, content; source = "user")
        FlootyTypst.save_source!(project)
        FlootyTypst.compile_project!(project)
        return nothing
    elseif k == "saveas"
        content = String(get(payload, :content, get(payload, "content", editor.content)))
        root = dirname(project.path)
        proposed = joinpath(root, "main.typ")
        i = 1
        while isfile(proposed)
            proposed = joinpath(root, "main-" * string(i) * ".typ")
            i += 1
        end
        write(proposed, content)
        FlootyEditor.set_file!(editor, proposed; read_content = true)
        FlootyEditor.mark_saved!(editor; path = proposed)
        project.path = proposed
        project.status = "ready"
        FlootyTypst.compile_project!(project)
        return nothing
    elseif k == "open"
        requested = strip(String(get(payload, :path, get(payload, "path", ""))))
        candidate = isabspath(requested) ? requested : joinpath(project.project_root, requested)
        isfile(candidate) || return nothing
        FlootyEditor.set_file!(editor, candidate; read_content = true)
        project.path = editor.path
        scheduleTypstCompile(project)
        return nothing
    elseif k == "selection"
        fromIndex = try Int(get(payload, :from, get(payload, "from", 0))) catch; return nothing; end
        line = try Int(get(payload, :line, get(payload, "line", 1))) catch; 1; end
        FlootyEditor.set_selection!(editor, fromIndex, fromIndex; line = line, column = 1)
        return nothing
    end
    nothing
end

const EDITOR_TREE_MAP = Dict{String,String}()
const EDITOR_TREE_LOCK = ReentrantLock()

function editorTreeFor(session_id, root)
    normalized = normpath(expanduser(String(root)))
    isdir(normalized) || return nothing
    lock(EDITOR_TREE_LOCK) do
        id = get(EDITOR_TREE_MAP, String(session_id), nothing)
        tree = nothing
        if id !== nothing
            try tree = FlootyFileTree.get_tree(id) catch; end
        end
        if tree === nothing
            id = "tree-" * string(session_id)
            tree = FlootyFileTree.create_tree(normalized; id = id, max_depth = 6)
            EDITOR_TREE_MAP[String(session_id)] = tree.id
        elseif tree.path != normalized
            remove_tree!(tree)
            tree = FlootyFileTree.create_tree(normalized; id = id, max_depth = 6)
            EDITOR_TREE_MAP[String(session_id)] = tree.id
        end
        tree
    end
end

function editorTreeEntries(tree)
    [Dict(
        "name" => entry.name,
        "path" => entry.path,
        "isDir" => entry.is_directory,
        "depth" => entry.depth,
        "hidden" => entry.hidden,
        "modified" => Dates.format(entry.modified, "yyyy-mm-ddTHH:MM:SSZ"),
        "expanded" => entry.is_directory && (entry.path in tree.expanded)
    ) for entry in FlootyFileTree.list_tree(tree; include_root = false, refresh = true)]
end

function editorToggleDirectoryHandler(session_id::AbstractString, root::AbstractString, path::AbstractString)
    tree = editorTreeFor(session_id, root)
    tree === nothing && return "[]"
    try
        FlootyFileTree.toggle_directory!(tree, String(path))
    catch err
        @debug "editor expand toggle failed" exception = err
        return "[]"
    end
    JSON.json(editorTreeEntries(tree))
end

function readEditorDocument(session_id::AbstractString, path::AbstractString)
    requested = normpath(expanduser(String(path)))
    isfile(requested) || return workspaceJson(Dict("success" => false, "error" => "file not found: $requested"))
    editor = sessionForId(session_id)
    editor isa FlootyEditor.EditorSession || return workspaceJson(Dict("success" => false, "error" => "editor not found"))
    projectId = editor.parent === nothing ? "" : String(editor.parent)
    project = isempty(projectId) ? nothing : try FlootyTypst.typst_project(projectId) catch; nothing end
    if project !== nothing
        root = normpath(expanduser(project.project_root))
        startswith(requested * Base.Filesystem.path_separator, root * Base.Filesystem.path_separator) || return workspaceJson(Dict("success" => false, "error" => "file is outside the workspace"))
    else
        root = dirname(editor.path)
        startswith(requested * Base.Filesystem.path_separator, root * Base.Filesystem.path_separator) || return workspaceJson(Dict("success" => false, "error" => "file is outside the workspace"))
    end
    try
        content = read(requested, String)
        return workspaceJson(Dict("success" => true, "path" => requested, "content" => content, "name" => basename(requested)))
    catch err
        return workspaceJson(Dict("success" => false, "error" => "could not read file: $err"))
    end
end

function editorFileListHandler(session_id::AbstractString, root::AbstractString)
    editor = sessionForId(session_id)
    editor isa FlootyEditor.EditorSession || return "[]"
    projectId = editor.parent === nothing ? "" : String(editor.parent)
    project = isempty(projectId) ? nothing : try FlootyTypst.typst_project(projectId) catch _; nothing end
    base = if !isempty(root)
        normpath(expanduser(String(root)))
    elseif project !== nothing
        project.project_root
    else
        editor.project_root
    end
    isdir(base) || return "[]"
    tree = editorTreeFor(session_id, base)
    entries = tree === nothing ? Any[] : editorTreeEntries(tree)
    JSON.json(entries)
end

newTypstSessionHandler(parent_id::AbstractString = "", path::AbstractString = "",
                       name::AbstractString = "Typst") =
    launchTypstSession!(parent_id; path = isempty(path) ? "" : path, name = isempty(name) ? "Typst" : name)
