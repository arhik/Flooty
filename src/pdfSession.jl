function launchPdfSession!(parent_id::AbstractString = "";
                           path::AbstractString = "", name::AbstractString = "PDF")
    root = ensureRootChatSession!()
    parent = isempty(parent_id) ? nothing : sessionForId(parent_id)
    sess = FlootyPDF.open_pdf(""; id = "pdf-" * string(uuid4()),
                              parent = parent === nothing ? nothing : parent.id)
    if !isempty(path) && isfile(path)
        FlootyPDF.set_file!(sess, path)
    end
    registerSession!(sess)
    if parent isa AbstractSession
        push!(parent.children, sess.id)
    end
    wv = FlootyPTYLayer.activeTerminalUiWebview()
    if wv !== nothing
        FlootyPTYLayer.addBrowserTabUi(wv, sess.id, String(name), sess.url;
                                       root_id = root.id,
                                       parent_id = parent === nothing ? "" : parent.id,
                                       open_native = false)
        try
            startPdfMonitor!(sess, wv)
        catch err
            @debug "PDF monitor attach failed" exception = err
        end
    end
    return sess
end

newPdfSessionHandler(parent_id::AbstractString = "", url::AbstractString = "/viewer/index.html",
                     name::AbstractString = "PDF") =
    launchPdfSession!(parent_id; path = url, name = isempty(name) ? "PDF" : name)

function startPdfMonitor!(sess::PDFSession, wv = nothing)
    startChatMonitor!(sess.id; note_key = sess, wv = wv)
    startTrajectoryMonitor!(sess)
    return true
end

const PDF_TOOL_WAITERS = Dict{String,Channel{Tuple{String,String,String,Bool}}}()
const PDF_TOOL_WAITERS_LOCK = ReentrantLock()

pdfToolWaiter!(id::AbstractString) =
    lock(PDF_TOOL_WAITERS_LOCK) do
        ch = Channel{Tuple{String,String,String,Bool}}(1)
        PDF_TOOL_WAITERS[String(id)] = ch
        ch
    end

function pdfToolResultHandler(session_id::AbstractString, request::AbstractString,
                              tool::AbstractString, result::AbstractString, ok::Bool)
    request = String(request)
    ch = lock(PDF_TOOL_WAITERS_LOCK) do
        pop!(PDF_TOOL_WAITERS, request, nothing)
    end
    ch === nothing && return false
    try
        put!(ch, (String(session_id), String(tool), String(result), ok))
        return true
    catch
        return false
    end
end

function pdfToolWait(request::AbstractString; timeout_s::Real = 5.0)
    ch = lock(PDF_TOOL_WAITERS_LOCK) do
        get(PDF_TOOL_WAITERS, String(request), nothing)
    end
    ch === nothing && return ("", "", "timeout", false)
    try
        return timedwait(() -> isready(ch), Float64(timeout_s)) == :timed_out ?
            ("", "", "timeout", false) : take!(ch)
    finally
        lock(PDF_TOOL_WAITERS_LOCK) do
            delete!(PDF_TOOL_WAITERS, String(request))
        end
    end
end

pdfNavigateHandler(session_id::AbstractString, url::AbstractString) =
    browserNavigateHandler(session_id, url)

