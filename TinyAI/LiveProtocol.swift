import Foundation

/// Wire format for the GPT-Live WebSocket API
/// (`wss://api.openai.com/v1/live/sessions`).  Kept separate from the
/// session so the JSON can be checked in tests and adjusted in one place.
nonisolated enum LiveProtocol {
    static let url = URL(string: "wss://api.openai.com/v1/live/sessions")!
    static let sampleRate = 24_000

    static func sessionStart(settings: LiveAgentSettings, tools: [[String: Any]], eventId: String = "tinyai_start") -> [String: Any] {
        var responses: [String: Any] = [
            "model": settings.backendModel,
            "tool_choice": "auto"
        ]
        if !tools.isEmpty {
            responses["tools"] = tools
            responses["parallel_tool_calls"] = true
        }
        let backendInstructions = settings.backendInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !backendInstructions.isEmpty {
            responses["instructions"] = backendInstructions
        }
        if !settings.backendReasoning.isEmpty && settings.backendReasoning != "none" {
            responses["reasoning"] = ["effort": settings.backendReasoning]
        }

        var session: [String: Any] = [
            "model": settings.model,
            "audio": [
                "format": ["type": "audio/pcm", "rate": sampleRate],
                "output": ["voice": settings.voice]
            ],
            "delegation": [
                "type": "responses",
                "responses": responses
            ]
        ]
        let instructions = settings.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instructions.isEmpty {
            session["instructions"] = instructions
        }
        return ["type": "session.start", "event_id": eventId, "session": session]
    }

    static func inputAudio(_ pcm16: Data) -> [String: Any] {
        ["type": "session.input_audio.append", "audio": pcm16.base64EncodedString()]
    }

    static func functionOutput(callId: String, output: String, eventId: String) -> [String: Any] {
        [
            "type": "response.item.create",
            "event_id": eventId,
            "item": ["type": "function_call_output", "call_id": callId, "output": output]
        ]
    }

    static func continueResponse(eventId: String) -> [String: Any] {
        ["type": "response.create", "event_id": eventId]
    }

    static func close() -> [String: Any] {
        ["type": "session.close"]
    }

    enum ServerEvent: Equatable {
        case started
        case closed
        case inputTranscriptDelta(String)
        case outputTranscriptDelta(String)
        case outputAudio(Data)
        case functionCall(callId: String, name: String, arguments: String)
        case userStartedSpeaking
        case error(String)
        case ignored(String)
    }

    static func parse(_ text: String) -> ServerEvent? {
        guard let data = text.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return nil }
        switch type {
        case "session.started":
            return .started
        case "session.closed":
            return .closed
        case "session.input_transcript.delta":
            return .inputTranscriptDelta(event["delta"] as? String ?? "")
        case "session.output_transcript.delta":
            return .outputTranscriptDelta(event["delta"] as? String ?? "")
        case "session.output_audio.delta":
            guard let base64 = event["delta"] as? String, let audio = Data(base64Encoded: base64) else {
                return .ignored(type)
            }
            return .outputAudio(audio)
        case "error":
            let error = event["error"] as? [String: Any]
            return .error(error?["message"] as? String ?? event["message"] as? String ?? "Unknown error")
        case "response.event":
            guard let nested = event["event"] as? [String: Any],
                  nested["type"] as? String == "response.output_item.done",
                  let item = nested["item"] as? [String: Any],
                  item["type"] as? String == "function_call",
                  let callId = item["call_id"] as? String,
                  let name = item["name"] as? String else {
                return .ignored(type)
            }
            return .functionCall(callId: callId, name: name, arguments: item["arguments"] as? String ?? "{}")
        default:
            // The user talking over the model (barge-in) must stop playback;
            // accept the event names the API uses for speech start.
            if type.hasSuffix("speech_started") || type.hasSuffix("input_speech.started") || type.contains("interrupt") {
                return .userStartedSpeaking
            }
            return .ignored(type)
        }
    }
}

/// Function tools exposed to the live model, and where each one runs.
nonisolated struct LiveToolRegistry {
    enum Route: Equatable {
        case mcp(connectionId: UUID, tool: String)
        case agent(UUID)
    }

    private(set) var definitions: [[String: Any]] = []
    private(set) var routes: [String: Route] = [:]

    init(settings: LiveAgentSettings, connections: [AgentConnection], agents: [AgentProfile]) {
        for connectionId in settings.mcpConnectionIds {
            guard let connection = connections.first(where: { $0.id == connectionId && $0.kind == .mcp }) else { continue }
            for tool in connection.cachedTools {
                let name = uniqueName(Self.sanitize("\(connection.name)__\(tool.name)"))
                let schema = (try? JSONSerialization.jsonObject(with: Data(tool.inputSchemaJSON.utf8))) as? [String: Any]
                    ?? ["type": "object", "properties": [String: Any]()]
                definitions.append([
                    "type": "function",
                    "name": name,
                    "description": String((tool.description.isEmpty ? "\(tool.name) on \(connection.name)" : tool.description).prefix(1000)),
                    "parameters": schema
                ])
                routes[name] = .mcp(connectionId: connection.id, tool: tool.name)
            }
        }
        for agentId in settings.agentIdsAsTools {
            guard let agent = agents.first(where: { $0.id == agentId }) else { continue }
            let name = uniqueName(Self.sanitize("ask_\(agent.name)"))
            let summary = agent.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            definitions.append([
                "type": "function",
                "name": name,
                "description": summary.isEmpty ? "Ask the \(agent.name) agent. It may take a while to think." : summary,
                "parameters": [
                    "type": "object",
                    "properties": ["question": ["type": "string", "description": "The full question or task for the agent."]],
                    "required": ["question"]
                ]
            ])
            routes[name] = .agent(agent.id)
        }
        if settings.webSearch {
            definitions.append(["type": "web_search"])
        }
    }

    /// Function names allow letters, digits, `_` and `-`, up to 64 characters.
    static func sanitize(_ name: String) -> String {
        var result = ""
        for scalar in name.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-" {
                result.unicodeScalars.append(scalar)
            } else {
                result.append("_")
            }
        }
        while result.contains("___") { result = result.replacingOccurrences(of: "___", with: "__") }
        if result.isEmpty { result = "tool" }
        return String(result.prefix(64))
    }

    private mutating func uniqueName(_ base: String) -> String {
        guard routes[base] != nil else { return base }
        var index = 2
        while true {
            let suffix = "_\(index)"
            let candidate = String(base.prefix(64 - suffix.count)) + suffix
            if routes[candidate] == nil { return candidate }
            index += 1
        }
    }
}
