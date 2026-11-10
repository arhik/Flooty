const TerminalSessionLike = Union{ReplSession,TerminalSession}
function closeLayerSession!(sess)
    if sess isa ChatSession
        stopChatMonitor!(sess.id)
        detachSession!(sess)
        return true
    elseif sess isa TerminalSession
        try
            FlootyPTYLayer.handleTerminalKill(String(sess.id); force = true)
        catch
        end
        detachSession!(sess)
        return true
    elseif sess isa PanelSession
        stopChatMonitor!(sess.id)
        try
            if sess isa PDFSession
                FlootyPDF.close_pdf!(FlootyPDF.pdf_session(sess.id))
            end
        catch err
            @debug "FlootyPDF close failed" exception = err
        end
        try
            stopTrajectoryMonitor!(sess)
        catch
        end
        detachSession!(sess)
        return true
    elseif sess isa FileTreeSession
        stopChatMonitor!(sess.id)
        try
            stopTrajectoryMonitor!(sess)
        catch
        end
        detachSession!(sess)
        return true
    end
    return false
end

function openLayerTerminal!(; kwargs...)
    throw(ArgumentError("terminal sessions are opened by the PTY layer"))
end

function attachLayerSession!(sess, target)
    return sess isa TerminalSessionLike || sess isa ChatSession || sess isa PanelSession
end

function commandLayerSession!(sess, command::Symbol, payload::Dict{String,Any})
    flag = get(payload, "force", false) == true
    if sess isa TerminalSessionLike
        id = sess isa TerminalSession ? sess.id : FlootyPTYLayer.sessionIdFor(sess)
        if command == :kill
            FlootyPTYLayer.handleTerminalKill(String(id); force = flag)
            return true
        elseif command == :resize
            rows = try Int(payload["rows"]) catch; return false end
            cols = try Int(payload["cols"]) catch; return false end
            return FlootyPTYLayer.handleTerminalResize(String(id), rows, cols)
        end
    elseif sess isa PanelSession
        if command == :navigate
            url = String(get(payload, "url", ""))
            return !isempty(strip(url)) && browserNavigateHandler(sess.id, url)
        end
    elseif sess isa ChatSession
        if command == :open
            return true
        end
    end
    false
end

function registerSessionLayers!()
    chatChat = FlootyAbstract.SessionChatHooks(
        (sess, wv, text, tab, selection) -> chatSessionTurn!(wv, text, tab, sess.id, selection),
        (sess, wv) -> startChatMonitor!(sess.id; note_key = sess, wv = wv),
        sess -> stopChatMonitor!(sess.id),
        nothing)
    FlootyAbstract.register_session_layer!(FlootyAbstract.SessionLayerDescriptor(
        :chat, "Chat", :chat, [:chat, :attach, :command, :close, :monitor, :parent_link, :split],
        sess -> sess isa ChatSession,
        (; parent_id = "", name = "Chat") -> launchChildChat!(String(parent_id); name = String(name)),
        attachLayerSession!, commandLayerSession!, closeLayerSession!,
        "/#chat", nothing,
        chatChat))
    termChat = nothing
    FlootyAbstract.register_session_layer!(FlootyAbstract.SessionLayerDescriptor(
        :terminal, "Terminal", :terminal, [:attach, :resize, :command, :close, :url, :persistence],
        sess -> sess isa TerminalSession || sess isa ReplSession,
        (;) -> openLayerTerminal!(),
        attachLayerSession!, commandLayerSession!, closeLayerSession!,
        "/runtime/terminal/", nothing, termChat))
    browserChat = FlootyAbstract.SessionChatHooks(
        (sess, wv, text, tab, selection) -> browserTurnFor!(sess, wv, text, tab, selection),
        (sess, wv) -> false,
        sess -> false,
        nothing)
    FlootyAbstract.register_session_layer!(FlootyAbstract.SessionLayerDescriptor(
        :browser, "Browser", :browser, [:chat, :attach, :command, :close, :monitor, :url, :parent_link, :split],
        sess -> sess isa BrowserSession && !(sess isa PDFSession),
        (; parent_id = "", url = "about:blank", name = "browser") -> launchBrowserSession!(String(parent_id); url = String(url), name = String(name)),
        attachLayerSession!, commandLayerSession!, closeLayerSession!,
        "/browser/", sess -> String(sess.url),
        browserChat))
    pdfChat = FlootyAbstract.SessionChatHooks(
        (sess, wv, text, tab, selection) -> browserTurnFor!(sess, wv, text, tab, selection),
        (sess, wv) -> startPdfMonitor!(sess, wv),
        sess -> stopTrajectoryMonitor!(sess),
        nothing)
    fileTreeChat = FlootyAbstract.SessionChatHooks(
        (sess, wv, text, tab, selection) -> browserTurnFor!(sess, wv, text, tab, selection),
        (sess, wv) -> startFileTreeMonitor!(sess, wv),
        sess -> stopTrajectoryMonitor!(sess),
        nothing)
    FlootyAbstract.register_session_layer!(FlootyAbstract.SessionLayerDescriptor(
        :filetree, "File tree", :document, [:chat, :attach, :command, :close, :monitor, :url, :parent_link, :split],
        sess -> sess isa FileTreeSession,
        (; parent_id = "", folder_id = "", name = "File tree") -> launchFileTreeSession!(String(parent_id); folder_id = String(folder_id), name = String(name)),
        attachLayerSession!, commandLayerSession!, closeLayerSession!,
        "/filetree/", sess -> "filetree:" * String(sess.id),
        fileTreeChat))

    FlootyAbstract.register_session_layer!(FlootyAbstract.SessionLayerDescriptor(
        :pdf, "PDF", :document, [:chat, :attach, :command, :close, :monitor, :url, :parent_link, :persistence, :split],
        sess -> sess isa PDFSession,
        (; parent_id = "", path = "/viewer/index.html", name = "PDF") -> launchPdfSession!(String(parent_id); path = String(path), name = String(name)),
        attachLayerSession!, commandLayerSession!, closeLayerSession!,
        "/viewer/", sess -> String(sess.url),
        pdfChat))
    return nothing
end

function closeGenericSession!(sess)
    FlootyAbstract.session_close!(sess)
end
