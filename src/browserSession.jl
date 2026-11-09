# browserSession.jl — a first-class BROWSER session.
#
# The page owns the panel (URL bar + iframe). The driver is a chat-like loop that
# can NAVIGATE the panel or answer; cross-origin pages are not readable, so
# navigation is the action surface (a CDP-backed reader can be layered later).

const PDFSession = FlootyPDF.PDFSession
const PanelSession = Union{AbstractPanelSession, PDFSession}

const BROWSER_COMPLETE = Ref{Union{Nothing,Function}}(nothing)

const PDF_SYSTEM_PROMPT = """
You drive a PDF SESSION: a live PDF viewer the user can see.
The runtime executes one action per assistant turn and sends the result back to you.
Continue with more actions until the task is complete, then use "done".
Reply with EXACTLY ONE JSON object and nothing else:
{"action":"goto","page":<1-based page number>}  jump to a page
{"action":"search","query":"<term>"}                 search the PDF and jump to first match
{"action":"nextMatch"}                              search for the next match
{"action":"copySelection"}                           copy the current selection
{"action":"previousMatch"}                         search for the previous match
{"action":"nextPage"}                                go to the next page
{"action":"previousPage"}                            go to the previous page
{"action":"zoomIn"}                                 zoom in
{"action":"zoomOut"}                                zoom out
{"action":"rotate"}                                 rotate the page
{"action":"note","text":"<note>"}                    add a note to the highlighted text
{"action":"copyPage"}                                copy all text on the current page
{"action":"toggleSidebar"}                             toggle the outline/pages sidebar
{"action":"showPages"}                                show the Pages sidebar tab
{"action":"showOutline"}                               show the Outline sidebar tab
{"action":"clearMarks"}                                remove all annotations
{"action":"bookmark"}                                  toggle bookmark on the current page
{"action":"saveCopy"}                                  save the annotated PDF as a copy
{"action":"removeHighlight"}                             remove the currently-selected existing highlight
{"action":"reorder","page":<n>,"position":<n>}         reorder a page to a new position
{"action":"highlight","color":"yellow|green|blue|pink|red"}  highlight the selected text
{"action":"send","code":"<pdf command>"}        run a PDF command such as "goto 8", "next page", or "find term"
{"action":"type","keys":"<keys>"}                send keys such as PgDn, PgUp, Home, End, +, or -
{"action":"reply","text":"<answer>"}             answer the user
{"action":"done","summary":"<what happened>"}    finish the task

Available highlight colors: yellow, green, blue, pink, red.
When asked to circle/emphasize/show authors or a passage, use highlight with the requested color.
When asked to remove all annotations or clear highlights, use clearMarks.
Unsupported actions have no effect; do not invent commands or describe an action as done unless one of the listed actions was executed.
When the user asks about selected text, use the selected text as context. When
Do not return the action as the visible reply; use reply or done for the final answer.
"""

function _uriEncode(s::AbstractString)
    out = IOBuffer()
    for byte in codeunits(String(s))
        isUnicode = byte <= 0x7f && (isuppercase(Char(byte)) || islowercase(Char(byte)) || isdigit(Char(byte)) || Char(byte) in ('-', '_', '.', '~'))
        if isUnicode
            print(out, Char(byte))
        else
            print(out, '%', uppercase(string(byte, base = 16, pad = 2)))
        end
    end
    return String(take!(out))
end

function parsePdfSend(code::AbstractString)
    raw = strip(String(code))
    isempty(raw) && return Nothing
    normalized = lowercase(join(split(raw, r"\s+"), " "))
    if (m = match(r"^(?:go to page|goto page|go to|page|goto|open page)\s+([0-9]+)$", normalized)) !== nothing
        page = tryparse(Int, m.captures[1])
        page !== nothing && return (kind = :goto, page = clamp(page, 1, 1_000_000), text = "")
    elseif normalized in ["next page", "go next page", "next", "pagenext"] || normalized == "pagedown" || normalized == "page down"
        return (kind = :pdfcontrol, page = 0, text = "nextPage")
    elseif normalized in ["previous page", "previous", "prev", "previous page go", "go previous page", "pageup", "page up"]
        return (kind = :pdfcontrol, page = 0, text = "previousPage")
    elseif normalized in ["zoom in", "zoom-in", "zoomin", "in", "plus"]
        return (kind = :pdfcontrol, page = 0, text = "zoomIn")
    elseif normalized in ["zoom out", "zoom-out", "zoomout", "out", "minus"]
        return (kind = :pdfcontrol, page = 0, text = "zoomOut")
    elseif normalized in ["rotate", "rotate page", "turn"]
        return (kind = :pdfcontrol, page = 0, text = "rotate")
    elseif normalized in ["bookmark", "bookmark page", "toggle bookmark"]
        return (kind = :pdfcontrol, page = 0, text = "bookmark")
    elseif normalized in ["sidebar", "toggle sidebar"]
        return (kind = :pdfcontrol, page = 0, text = "toggleSidebar")
    elseif normalized in ["save copy", "savecopy", "copy save"]
        return (kind = :pdfcontrol, page = 0, text = "saveCopy")
    elseif normalized == "next match" || normalized == "nextmatch"
        return (kind = :matches, page = 0, text = "next")
    elseif normalized == "previous match" || normalized == "previousmatch" || normalized == "prevmatch"
        return (kind = :matches, page = 0, text = "previous")
    elseif normalized == "copy selection" || normalized == "copyselection"
        return (kind = :copy, page = 0, text = "")
    elseif normalized == "copy page" || normalized == "copypage"
        return (kind = :pdfcontrol, page = 0, text = "copyPage")
    elseif normalized == "remove highlight" || normalized == "removehighlight"
        return (kind = :pdfcontrol, page = 0, text = "removeHighlight")
    elseif (m = match(r"^find\s+(.+)$", raw)) !== nothing
        return (kind = :search, page = 0, text = strip(m.captures[1]))
    elseif (m = match(r"^search\s+(.+)$", raw)) !== nothing
        return (kind = :search, page = 0, text = strip(m.captures[1]))
    elseif (m = match(r"^showpages?$", normalized)) !== nothing
        return (kind = :pdfcontrol, page = 0, text = "showPages")
    elseif (m = match(r"^showoutline$", normalized)) !== nothing
        return (kind = :pdfcontrol, page = 0, text = "showOutline")
    elseif normalized in ["clear annotations", "clear marks", "remove annotations", "remove all annotations", "remove highlights", "remove notes"]
        return (kind = :pdfcontrol, page = 0, text = "clearMarks")
    elseif (m = match(r"^(?:note)\s+(.+)$", normalized)) !== nothing
        return (kind = :note, page = 0, text = strip(m.captures[1]))
    elseif (m = match(r"^reorder\s+([0-9]+)\s+([0-9]+)$", normalized)) !== nothing
        src = parse(Int, m.captures[1]); dst = parse(Int, m.captures[2])
        return (kind = :reorder, page = src, position = dst, text = "")
    elseif (m = match(r"^highlight(?:\s+with\s+color\s+|\s+)(yellow|green|blue|pink|red)$", normalized)) !== nothing
        colors = Dict("yellow" => "#FFD84D", "green" => "#5EDC9A", "blue" => "#6CB8FF", "pink" => "#FF8FC7", "red" => "#FF5A4E")
        return (kind = :highlight, page = 0, text = get(colors, m.captures[1], "#FFD84D"))
    end
    nothing
end

function mapPdfKey(keys::AbstractString)
    normalized = lowercase(strip(String(keys)))
    normalized = replace(normalized, r"[\s_]+" => "")
    normalized in ["priorpage", "previous", "prev", "pageup", "pgup", "arrowup"] && return (kind = :pdfcontrol, page = 0, text = "previousPage")
    normalized in ["nextpage", "pagedown", "pgdn", "arrowdown", "space"] && return (kind = :pdfcontrol, page = 0, text = "nextPage")
    normalized in ["home"] && return (kind = :goto, page = 1, text = "")
    normalized in ["end"] && return (kind = :goto, page = 1_000_000, text = "")
    normalized in ["+", "=", "zoomin"] && return (kind = :pdfcontrol, page = 0, text = "zoomIn")
    normalized in ["-", "_", "zoomout"] && return (kind = :pdfcontrol, page = 0, text = "zoomOut")
    normalized in ["r", "rotate"] && return (kind = :pdfcontrol, page = 0, text = "rotate")
    normalized in ["b", "bookmark"] && return (kind = :pdfcontrol, page = 0, text = "bookmark")
    normalized in ["n", "nextmatch"] && return (kind = :matches, page = 0, text = "next")
    normalized in ["p", "previousmatch", "prevmatch"] && return (kind = :matches, page = 0, text = "previous")
    normalized in ["h", "highlight"] && return (kind = :highlight, page = 0, text = "#FFD84D")
    nothing
end

"Parse a PDFSession turn: goto page, or reply."
function parsePdfReply(
reply::AbstractString)
    raw = stripThinking(String(reply))
    act = extractActionJson(raw)
    if act === nothing
        try
            jsonObj = JSON.parse(strip(raw))
            jsonObj isa JSON.Object && (act = jsonObj)
        catch
        end
    end
    if act !== nothing
        kind = lowercase(getstr(act, "action", ""))
        if kind == "goto" || kind == "page"
            p = get(act, :page, get(act, "page", 1))
            try
                p = Int(p)
                p = clamp(p, 1, typemax(Int))
            catch
                p = 1
            end
            return (kind = :goto, page = p, text = String(getstr(act, "text", "")))
        elseif kind == "search"
            return (kind = :search, page = 0,
                    text = String(getstr(act, "query", getstr(act, "text", ""))))
        elseif kind == "note"
            note = String(getstr(act, "text", getstr(act, "note", "")))
            return (kind = :note, page = 0, text = note)
        elseif kind in ("nextpage", "previouspage", "zoomin", "zoomout", "rotate", "copypage", "togglesidebar", "showpages", "showoutline", "clearmarks", "bookmark", "savecopy", "removehighlight")
            controlNames = Dict("nextpage" => "nextPage", "previouspage" => "previousPage", "zoomin" => "zoomIn", "zoomout" => "zoomOut", "rotate" => "rotate", "copypage" => "copyPage", "togglesidebar" => "toggleSidebar", "showpages" => "showPages", "showoutline" => "showOutline", "bookmark" => "bookmark", "savecopy" => "saveCopy", "removehighlight" => "removeHighlight", "clearmarks" => "clearMarks")
            return (kind = :pdfcontrol, page = 0, text = controlNames[kind])
        elseif kind == "reorder"
            src = try Int(get(act, :page, get(act, "page", 1))) catch; 1; end
            dst = try Int(get(act, :position, get(act, "position", 1))) catch; 1; end
            return (kind = :reorder, page = src, position = dst, text = "")
        elseif kind == "copyselection"
            return (kind = :copy, page = 0, text = "")
        elseif kind == "nextmatch"
            return (kind = :matches, page = 0, text = "next")
        elseif kind == "previousmatch"
            return (kind = :matches, page = 0, text = "previous")
        elseif kind == "highlight"
            colors = Dict("yellow" => "#FFD84D", "green" => "#5EDC9A",
                          "blue" => "#6CB8FF", "pink" => "#FF8FC7",
                          "red" => "#FF5A4E")
            color = lowercase(strip(String(getstr(act, "color", "yellow"))))
            hex = get(colors, color, "#FFD84D")
            return (kind = :highlight, page = 0, text = hex)
        elseif kind == "send"
            parsed = parsePdfSend(String(get(act, :code, get(act, "code", ""))))
            parsed === nothing && return (kind = :unsupported, page = 0, text = String(get(act, :code, get(act, "code", ""))))
            return parsed
        elseif kind == "type"
            parsed = mapPdfKey(String(get(act, :keys, get(act, "keys", ""))))
            parsed === nothing && return (kind = :unsupported, page = 0, text = String(get(act, :keys, get(act, "keys", ""))))
            return parsed
        elseif kind == "reply"
            return (kind = :chat, page = 0, text = String(getstr(act, "text", getstr(act, "reply", ""))))
        elseif kind == "done"
            return (kind = :done, page = 0, text = String(getstr(act, "summary", "")))
        end
    end
    return (kind = :chat, page = 0, text = String(strip(stripProviderMarkup(raw))))
end

const BROWSER_SYSTEM_PROMPT = """
You drive a BROWSER SESSION: a live web panel the user can see. You know the
current URL and the conversation, but NOT the cross-origin page DOM.
Reply with EXACTLY ONE JSON object and nothing else:
{"action":"navigate","url":"https://..."}   open a URL in the panel
{"action":"reply","text":"<answer>"}        answer the user
{"action":"done","summary":"<what happened>"}
Prefer search/result URLs the user can read; be concise. Never claim to have
read content the panel cannot expose.
"""

function parseBrowserReply(reply::AbstractString)
    raw = stripThinking(String(reply))
    act = extractActionJson(raw)
    if act === nothing
        try
            obj = JSON.parse(strip(raw))
            obj isa JSON.Object && (act = obj)
        catch
        end
    end
    if act !== nothing
        kind = lowercase(getstr(act, "action", ""))
        if kind == "navigate"
            return (kind = :navigate, url = String(getstr(act, "url", "")),
                    text = String(getstr(act, "reply", "")))
        end
        body = String(getstr(act, "reply", getstr(act, "text", getstr(act, "summary", ""))))
        return (kind = :chat, url = "", text = body)
    end
    return (kind = :chat, url = "", text = String(strip(stripProviderMarkup(raw))))
end

"Create a BrowserSession (child of `parent_id`, or the root chat when empty)."
function launchBrowserSession!(parent_id::AbstractString = "";
                               url::AbstractString = "about:blank",
                               name::AbstractString = "browser")
    root = ensureRootChatSession!()
    parent = isempty(parent_id) ? nothing : sessionForId(parent_id)
    sess = registerSession!(BrowserSession(
        parent = parent === nothing ? nothing : parent.id,
        url = String(url)))
    if parent isa AbstractSession
        push!(parent.children, sess.id)
    end
    wv = FlootyPTYLayer.activeTerminalUiWebview()
    if wv !== nothing
        FlootyPTYLayer.addBrowserTabUi(
            wv, sess.id, String(name), String(url);
            root_id = root.id, parent_id = parent === nothing ? "" : parent.id)
        @async begin
            sleep(0.4)
            try
                FlootyPTYLayer.pushAgentEventToWindow(wv,
                    AgentMonitorThinkingEvent(sess.id,
                        "browser monitor attached — watching navigation"))
            catch
            end
        end
    end
    return sess
end

"The UI chooser's browser spawner."
newBrowserSessionHandler(parent_id::AbstractString, url::AbstractString,
                         name::AbstractString) =
    launchBrowserSession!(parent_id; url = isempty(url) ? "about:blank" : url,
                          name = isempty(name) ? "browser" : name)

"The page's URL bar: keep the session's current URL in sync."
function browserNavigateHandler(session_id::AbstractString, url::AbstractString)
    s = sessionForId(session_id)
    s isa PanelSession || return false
    s.url = String(url)
    return true
end

function pushPdfToolEvent(wv, sess, tool::AbstractString, detail::AbstractString; ok::Bool = true)
    try
        trajectoryToolCall!(sess, String(tool), String(detail))
        trajectoryToolResult!(sess, ok, String(detail))
    catch err
        @debug "pdf trajectory tool failed" exception = err
    end
    if wv !== nothing
        id = string(uuid4())
        pushAgentEventToWindow(wv,
            AgentToolCallEvent(sess.id, id, String(tool), String(detail)))
        pushAgentEventToWindow(wv,
            AgentToolResultEvent(sess.id, id, ok, String(detail)))
    end
end

"Drive one PDF turn: execute actions, then reply."
function pdfTurnFor!(sess::PDFSession, wv, text::AbstractString,
                     tab::AbstractString = "", pdf_selection::AbstractString = "")
    startTrajectoryMonitor!(sess)
    trajectoryTask!(sess, text)
    noteUserMessage!(sess, text)
    conv = conversationFor(sess.id)
    recordTask!(conv, text)
    sessionCfg = sessionModelConfig(sess)
    conv.model = sessionCfg.actorModel
    setSessionStatus!(sess, "thinking")
    @async begin
        try
            fn = BROWSER_COMPLETE[]
            if fn === nothing
                fn = makeCompleteFn(sessionCfg, sessionCfg.actorModel;
                    onThinking = chunk -> (wv === nothing ? nothing :
                        pushAgentEventToWindow(wv,
                            AgentThinkingEvent(sess.id, String(chunk)))))
            end
            msgs = OllamaMessage[OllamaMessage(role = "system",
                content = PDF_SYSTEM_PROMPT * "\nCURRENT URL: " * sess.url)]
            isempty(strip(String(pdf_selection))) || push!(msgs,
                OllamaMessage(role = "system",
                    content = "SELECTED PDF TEXT:\n" * String(pdf_selection)))
            for n in takeParentNotes!(sess.id)
                push!(msgs, OllamaMessage(role = "user", content = "STEER: " * n))
            end
            append!(msgs, conversationContext(conv))
            push!(msgs, OllamaMessage(role = "user", content = "TASK: " * text))
            ctxLimit = try
                contextLengthFor(sessionCfg.actorModel)
            catch
                0
            end
            ctxUse = contextUsage(msgs; limit = ctxLimit)
            try
                trajectoryContext!(sess, ctxUse.tokens, ctxUse.limit)
            catch
            end
            wv === nothing || pushAgentEventToWindow(wv,
                AgentContextUsageEvent(sess.id, ctxUse.tokens, ctxUse.limit))
            finalText = ""
            complete = false
            for step in 1:12
                wv === nothing || pushAgentEventToWindow(
                    wv, AgentProgressEvent(sess.id, "agent working…"))
                reply = fn(msgs)
                thinking = extractThinking(reply)
                if !isempty(strip(thinking))
                    wv === nothing || pushAgentEventToWindow(
                        wv, AgentThinkingEvent(sess.id, strip(thinking)))
                end
                parsed = parsePdfReply(reply)
                if parsed.kind === :unsupported
                    finalText = "The PDF agent returned an unsupported action: " * String(parsed.text)
                    complete = true
                    break
                end
                if parsed.kind === :chat || parsed.kind === :done
                    finalText = strip(parsed.text)
                    complete = true
                    break
                end
                detail = ""
                payload = nothing
                if parsed.kind === :goto && parsed.page >= 1
                    payload = Dict("tool" => "goto", "args" => Dict("page" => parsed.page))
                    detail = "page " * string(parsed.page)
                elseif parsed.kind === :note
                    payload = Dict("tool" => "note", "args" => Dict("text" => String(parsed.text)))
                    detail = "note"
                elseif parsed.kind === :reorder
                    src = parsed.page
                    dst = parsed.position
                    payload = Dict("tool" => "reorder",
                                   "args" => Dict("source" => src, "target" => dst))
                    detail = "page " * string(src) * " → " * string(dst)
                elseif parsed.kind === :pdfcontrol
                    action = String(parsed.text)
                    payload = Dict("tool" => action, "args" => Dict{String,Any}())
                    detail = action
                elseif parsed.kind === :copy
                    payload = Dict("tool" => "copySelection", "args" => Dict{String,Any}())
                    detail = "copy selection"
                elseif parsed.kind === :matches
                    direction = lowercase(String(parsed.text))
                    payload = Dict("tool" => direction == "next" ? "nextMatch" : "previousMatch",
                                   "args" => Dict{String,Any}())
                    detail = direction * " match"
                elseif parsed.kind === :search
                    query = String(parsed.text)
                    payload = Dict("tool" => "search", "args" => Dict("query" => query))
                    detail = "search: " * query
                elseif parsed.kind === :highlight
                    payload = Dict("tool" => "highlight", "args" => Dict("color" => String(parsed.text)))
                    detail = "highlight"
                end
                if payload === nothing
                    finalText = "The PDF agent returned an unsupported action."
                    complete = true
                    break
                end
                requestId = string(uuid4())
                pdfToolWaiter!(requestId)
                localUrl = "pdf:tool:" * requestId * ":" * _uriEncode(JSON.json(payload))
                if wv !== nothing
                    pushAgentEventToWindow(wv, AgentBrowserNavigateEvent(sess.id, localUrl))
                    _, _, toolResult, toolOk = pdfToolWait(requestId)
                    ok = toolOk
                    detail = toolResult
                else
                    ok = true
                end
                pushPdfToolEvent(wv, sess, "pdf", detail; ok = ok)
                push!(msgs, OllamaMessage(role = "assistant", content = String(reply)))
                push!(msgs, OllamaMessage(role = "user",
                    content = "PDF TOOL RESULT: " * detail))
                if isempty(localUrl)
                    finalText = "The PDF agent returned an unsupported action."
                    complete = true
                    break
                end
                if wv !== nothing
                    pushAgentEventToWindow(wv, AgentBrowserNavigateEvent(sess.id, localUrl))
                end
                pushPdfToolEvent(wv, sess, "pdf", detail; ok = true)
                push!(msgs, OllamaMessage(role = "assistant", content = String(reply)))
                push!(msgs, OllamaMessage(role = "user",
                    content = "PDF TOOL RESULT: " * detail * " completed. Continue if another action is needed; otherwise return the action done with a short answer in summary."))
            end
            if !complete
                finalText = "The PDF agent stopped after too many actions."
            end
            isempty(strip(String(finalText))) && (finalText = "Done.")
            wv === nothing || pushAgentEventToWindow(wv, AgentProgressEvent(sess.id, ""))
            ev = AgentTextEvent(sess.id, String(finalText))
            recordAgentEvent!(conv, ev)
            wv === nothing || pushAgentEventToWindow(wv, ev)
            setSessionStatus!(sess, "idle")
        catch err
            setSessionStatus!(sess, "error")
            wv === nothing || pushAgentEventToWindow(wv, AgentProgressEvent(sess.id, ""))
            wv === nothing || pushAgentEventToWindow(wv,
                AgentStatusEvent(sess.id, "pdf failed: " * sprint(showerror, err),
                                 :error))
        end
        return nothing
    end
    return true
end

"Drive one browser turn: navigate or reply, in the session's chat rail."
function browserTurnFor!(sess::PanelSession, wv, text::AbstractString,
                         tab::AbstractString = "", pdf_selection::AbstractString = "")
    if sess isa PDFSession
        return pdfTurnFor!(sess, wv, text, tab, pdf_selection)
    end
    startTrajectoryMonitor!(sess)
    trajectoryTask!(sess, text)
    noteUserMessage!(sess, text)
    conv = conversationFor(sess.id)
    recordTask!(conv, text)
    sessionCfg = sessionModelConfig(sess)
    conv.model = sessionCfg.actorModel
    setSessionStatus!(sess, "thinking")
    @async begin
        try
            fn = BROWSER_COMPLETE[]
            if fn === nothing
                fn = makeCompleteFn(sessionCfg, sessionCfg.actorModel;
                    onThinking = chunk -> (wv === nothing ? nothing :
                        pushAgentEventToWindow(wv,
                            AgentThinkingEvent(sess.id, String(chunk)))))
            end
            prompt = sess isa PDFSession ? PDF_SYSTEM_PROMPT : BROWSER_SYSTEM_PROMPT
            msgs = OllamaMessage[OllamaMessage(role = "system",
                content = prompt * "\nCURRENT URL: " * sess.url)]
            isempty(strip(String(pdf_selection))) || push!(msgs,
                OllamaMessage(role = "system",
                    content = "SELECTED PDF TEXT:\n" * String(pdf_selection)))
            for n in takeParentNotes!(sess.id)
                push!(msgs, OllamaMessage(role = "user", content = "STEER: " * n))
            end
            append!(msgs, conversationContext(conv))
            push!(msgs, OllamaMessage(role = "user", content = "TASK: " * text))
            ctxLimit = try
                contextLengthFor(sessionCfg.actorModel)
            catch
                0
            end
            ctxUse = contextUsage(msgs; limit = ctxLimit)
            try
                trajectoryContext!(sess, ctxUse.tokens, ctxUse.limit)
            catch
            end
            wv === nothing || pushAgentEventToWindow(wv,
                AgentContextUsageEvent(sess.id, ctxUse.tokens, ctxUse.limit))
            wv === nothing || pushAgentEventToWindow(
                wv, AgentProgressEvent(sess.id, "thinking…"))
            reply = fn(msgs)
            thinking = extractThinking(reply)
            if !isempty(strip(thinking))
                pushAgentEventToWindow(wv, AgentThinkingEvent(sess.id, strip(thinking)))
            end
            parsed = sess isa PDFSession ? parsePdfReply(reply) : parseBrowserReply(reply)
            if parsed.kind === :navigate && !isempty(strip(parsed.url))
                url = strip(parsed.url)
                if !startswith(url, "http://") && !startswith(url, "https://") &&
                   !startswith(url, "about:")
                    url = "https://" * url
                end
                sess.url = url
                if wv !== nothing
                    pushAgentEventToWindow(
                        wv, AgentBrowserNavigateEvent(sess.id, url))
                    pushAgentEventToWindow(wv, AgentMonitorThinkingEvent(
                        sess.id, "navigated to " * url))
                end
                shown = "Opening " * url
            else
                shown = strip(parsed.text)
            end
            wv === nothing || pushAgentEventToWindow(wv, AgentProgressEvent(sess.id, ""))
            isempty(shown) && (shown = "The browser returned no answer.")
            ev = AgentTextEvent(sess.id, shown)
            recordAgentEvent!(conv, ev)
            wv === nothing || pushAgentEventToWindow(wv, ev)
            setSessionStatus!(sess, "idle")
        catch err
            setSessionStatus!(sess, "error")
            wv === nothing || pushAgentEventToWindow(wv, AgentProgressEvent(sess.id, ""))
            wv === nothing || pushAgentEventToWindow(wv,
                AgentStatusEvent(sess.id, "browser failed: " * sprint(showerror, err),
                                 :error))
        end
        return nothing
    end
    return true
end
