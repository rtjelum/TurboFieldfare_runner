import Foundation

/// Token sequences for a tool loop driven onto a retained KV, one piece at a
/// time, rather than rendered as a whole transcript.
///
/// Every sequence here is cut out of the pinned Jinja template's own rendering
/// and checked against the boundary it is spliced at. Nothing is assembled by
/// hand, so a template revision that moves a marker is a thrown error instead
/// of a context the model was never trained to read.
extension GFTokenizer {
    /// The opening of a conversation that declares `tools`: `<bos>` and the
    /// whole system turn, instructions and declarations included.
    ///
    /// It stands where the first user turn's own `<bos>` would: this followed
    /// by that turn's opening rendering without its `<bos>` is the template's
    /// rendering of the two together, exactly.
    public func encodeToolPreamble(system: String?,
                                   tools: [FunctionDefinition]) throws -> [Int32] {
        let probe = "x"
        var messages: [Message] = []
        if let system { messages.append(Message(role: .system, content: system)) }
        messages.append(Message(role: .user, content: probe))
        let full = try encodeToolChat(messages: messages, tools: tools)
        let userTurn = encode(
            try applyChatTemplate([Message(role: .user, content: probe)]),
            addBOS: false).dropFirst()
        guard full.count > userTurn.count,
              full.first == bosID,
              full.suffix(userTurn.count).elementsEqual(userTurn) else {
            throw GFTokenizerError.invalidChatTemplate(
                "tool declaration does not end at a user-turn boundary")
        }
        return Array(full.dropLast(userTurn.count))
    }

    /// The declaration block and the end of its system turn, as they sit in
    /// any preamble for `tools` whatever instructions precede them. A lineage whose opening contains
    /// these tokens was opened with the tools declared.
    public func encodeToolDeclarations(tools: [FunctionDefinition]) throws -> [Int32] {
        let bare = try encodeToolPreamble(system: nil, tools: tools)
        let header = [bosID] + encode("<|turn>system\n", addBOS: false)
        guard bare.count > header.count, bare.starts(with: header) else {
            throw GFTokenizerError.invalidChatTemplate(
                "tool declaration does not follow the system turn's opening")
        }
        return Array(bare.dropFirst(header.count))
    }

    /// The tool-response blocks that answer `calls`, starting at the
    /// `<|tool_response>` marker the model stopped on and ending where the
    /// model resumes its own turn.
    ///
    /// `results` is untrusted text. It is stripped of anything the tokenizer
    /// would read as a control token, and the rendering is then compared with
    /// one made from inert content: a result that still changed the marker
    /// structure is refused rather than prefilled.
    public func encodeToolResponses(calls: [HistoricalToolCall],
                                    results: [String],
                                    tools: [FunctionDefinition]) throws -> [Int32] {
        guard !calls.isEmpty, calls.count == results.count else {
            throw GFTokenizerError.invalidChatTemplate(
                "tool responses must answer every call")
        }
        let rendered = try renderToolResponses(
            calls: calls, results: results.map(strippingControlTokens), tools: tools)
        let inert = try renderToolResponses(
            calls: calls, results: results.map { _ in "ok" }, tools: tools)
        let markers = Set([toolResponseID, toolResponseEndID, toolCallStartID,
                           toolCallEndID, endOfTurnID, bosID, eosID])
            .union(specialTokenIDs)
        guard rendered.last == toolResponseEndID,
              rendered.filter(markers.contains) == inert.filter(markers.contains) else {
            throw GFTokenizerError.invalidChatTemplate(
                "tool result changed the response block's structure")
        }
        return rendered
    }

    /// `text` with nothing left in it that encodes to a control token.
    ///
    /// Removing a marker can join its neighbours into a new one, so the strip
    /// repeats until an encode comes back clean.
    public func strippingControlTokens(_ text: String) -> String {
        var current = text
            .replacingOccurrences(of: "<|", with: "<")
            .replacingOccurrences(of: "|>", with: ">")
        for _ in 0..<4 {
            let ids = encode(current, addBOS: false)
            guard ids.contains(where: specialTokenIDs.contains) else { return current }
            current = decode(ids, skipSpecialTokens: true)
        }
        return current.filter { $0 != "<" && $0 != ">" }
    }

    private func renderToolResponses(calls: [HistoricalToolCall],
                                     results: [String],
                                     tools: [FunctionDefinition]) throws -> [Int32] {
        let user = Message(role: .user, content: "x")
        let assistant = Message(role: .assistant, content: nil, toolCalls: calls)
        let responses = zip(calls, results).map { call, result in
            Message(role: .tool, content: result, toolCallID: call.id, name: call.name)
        }
        return try encodeToolResultContinuation(
            cachedMessages: [user],
            assistant: assistant,
            incomingMessages: [user, assistant] + responses,
            tools: tools)
    }
}
