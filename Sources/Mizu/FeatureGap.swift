import Foundation

/// Lets your app's AI chat notice when a user wants something the app can't do yet, ask a question or two,
/// and pass it to you (and Claude) as a report filed by the app's AI.
///
/// 1. Add `FeatureGap.systemPrompt` to your chat's system prompt.
/// 2. Offer the tool: `FeatureGap.anthropicTool` (Anthropic Messages API) or `FeatureGap.openAITool` (OpenAI-style).
/// 3. When the model calls `report_unsupported_request`, hand the input to `Mizu.handleFeatureGap(input:conversation:)`
///    and send the string it returns back as the tool result.
public enum FeatureGap {
    public static let toolName = "report_unsupported_request"

    public static let systemPrompt = """
    If the user asks for something you or this app can't do yet, don't pretend and don't just say no. \
    If it isn't clear what they want or why, ask one or two short questions first. Then call \
    \(toolName) and tell them, in a sentence, that you've passed it on to the developer.
    """

    static let toolDescription = """
    Pass a request on to the app's developer when the user wants something this app can't do yet. \
    Ask at most one or two short clarifying questions first if what they want or why is unclear. \
    After calling it, tell the user briefly that it's been passed on.
    """

    static let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "want": ["type": "string", "description": "One sentence: what the user is trying to do, in their terms."],
            "user_words": ["type": "string", "description": "The user's own words when they asked, quoted."],
            "why": ["type": "string", "description": "What they'd use it for, if known."],
            "details": ["type": "string", "description": "Anything specific learned from clarifying questions."],
        ],
        "required": ["want", "user_words"],
    ]

    /// For the Anthropic Messages API `tools` array.
    public static var anthropicTool: [String: Any] {
        ["name": toolName, "description": toolDescription, "input_schema": inputSchema]
    }

    /// For OpenAI-style `tools` arrays (Chat Completions and compatible APIs).
    public static var openAITool: [String: Any] {
        ["type": "function", "function": ["name": toolName, "description": toolDescription, "parameters": inputSchema]]
    }

    /// What to send back as the tool result. The model then tells the user it's been passed on.
    public static let toolResult = "Passed on to the developer. Briefly tell the user it's been noted."

    /// Turns the tool call's input into the request body for `POST /v1/requests`, or nil if there's no `want`.
    static func requestBody(input: [String: Any], conversation: [LLMMessage], userRef: String?) -> [String: Any]? {
        func text(_ key: String) -> String? {
            (input[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        guard let want = text("want") else { return nil }
        var body: [String: Any] = ["want": want]
        body["user_words"] = text("user_words")
        body["why"] = text("why")
        body["details"] = text("details")
        if !conversation.isEmpty {
            body["conversation"] = conversation.suffix(12).map { ["role": $0.role, "content": String($0.content.prefix(4000))] }
        }
        body["user_ref"] = userRef
        return body
    }
}

extension Mizu {
    /// Call when the model uses `report_unsupported_request`. Returns the tool result to send back to the model.
    /// Safe to call when Mizu isn't running: nothing is sent, the model still gets a sensible result.
    ///
    ///     case FeatureGap.toolName:
    ///         let result = Mizu.handleFeatureGap(input: toolUse.input, conversation: history)
    ///
    /// - Parameters:
    ///   - conversation: the chat so far (the last 12 messages are sent), so you can see how the request came up.
    ///   - userRef: optional anonymous id for whoever asked, if you want to follow up with them later.
    @discardableResult
    public static func handleFeatureGap(input: [String: Any], conversation: [LLMMessage] = [], userRef: String? = nil) -> String {
        guard var body = FeatureGap.requestBody(input: input, conversation: conversation, userRef: userRef) else {
            return "Couldn't pass that on: \"want\" was missing. Ask the user what they're trying to do, then call again."
        }
        timeline?.record("feature_request", ["want": .string(LLMStore.preview(body["want"] as? String ?? "", max: 120))])
        guard let client else { return FeatureGap.toolResult }
        let app = DeviceInfo.appMeta()
        body["app_version"] = app["app_version"]
        body["build"] = app["build"]
        body["screen"] = currentScreen()
        body["install_id"] = installID
        client.send(meta: body, parts: [], path: "v1/requests")
        return FeatureGap.toolResult
    }

    /// Same, for tool inputs you have as JSON (`Data` or a `String`).
    @discardableResult
    public static func handleFeatureGap(inputJSON: Data, conversation: [LLMMessage] = [], userRef: String? = nil) -> String {
        let input = (try? JSONSerialization.jsonObject(with: inputJSON)) as? [String: Any] ?? [:]
        return handleFeatureGap(input: input, conversation: conversation, userRef: userRef)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
