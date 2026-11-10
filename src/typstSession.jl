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

function editorFileListHandler(session_id::AbstractString, root::AbstractString)
    editor = sessionForId(session_id)
    editor isa FlootyEditor.EditorSession || return "[]"
    projectId = editor.parent === nothing ? "" : String(editor.parent)
    project = isempty(projectId) ? nothing : try FlootyTypst.typst_project(projectId) catch _; nothing end
    base = isempty(root) && project !== nothing ? project.project_root : normpath(expanduser(String(root)))
    isdir(base) || return "[]"
    tree = editorTreeFor(session_id, base)
    entries = tree === nothing ? Any[] : editorTreeEntries(tree)
    JSON.json(entries)
end

newTypstSessionHandler(parent_id::AbstractString = "", path::AbstractString = "",
                       name::AbstractString = "Typst") =
    launchTypstSession!(parent_id; path = isempty(path) ? "" : path, name = isempty(name) ? "Typst" : name)
