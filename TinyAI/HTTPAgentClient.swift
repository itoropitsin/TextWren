import Foundation

/// Placeholders a request template may use.
nonisolated struct AgentTemplateValues: Sendable {
    var transcript: String
    var sessionId: String
    var language: String
    var agentName: String

    func value(for placeholder: String) -> String? {
        switch placeholder {
        case "transcript": return transcript
        case "sessionId": return sessionId
        case "language": return language
        case "agent": return agentName
        default: return nil
        }
    }
}

nonisolated enum HTTPAgentTemplate {
    static let defaultBody = #"{"input": "{{transcript}}", "session_id": "{{sessionId}}"}"#

    /// Replace `{{name}}` placeholders.  With `jsonEscaped`, values are
    /// escaped for use inside a JSON string literal, so a transcript with
    /// quotes or new lines can't break the request body.
    static func render(_ template: String, values: AgentTemplateValues, jsonEscaped: Bool) -> String {
        var result = ""
        var remaining = Substring(template)
        while let open = remaining.range(of: "{{") {
            result += remaining[..<open.lowerBound]
            let afterOpen = remaining[open.upperBound...]
            guard let close = afterOpen.range(of: "}}") else {
                result += remaining[open.lowerBound...]
                return result
            }
            let name = afterOpen[..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            if let value = values.value(for: name) {
                result += jsonEscaped ? jsonEscape(value) : value
            } else {
                result += remaining[open.lowerBound..<close.upperBound]
            }
            remaining = afterOpen[close.upperBound...]
        }
        result += remaining
        return result
    }

    static func jsonEscape(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value], options: [.fragmentsAllowed]),
              var encoded = String(data: data, encoding: .utf8) else {
            return value
        }
        // `["…"]` → `…`
        encoded.removeFirst(2)
        encoded.removeLast(2)
        return encoded.replacingOccurrences(of: "\\/", with: "/")
    }
}

nonisolated enum JSONPath {
    /// Follow a dot path such as `choices.0.message.content` through parsed
    /// JSON.  Numeric components index arrays.
    static func value(at path: String, in object: Any) -> Any? {
        let components = path.split(separator: ".").map(String.init).filter { !$0.isEmpty }
        var current: Any? = object
        for component in components {
            if let dictionary = current as? [String: Any] {
                current = dictionary[component]
            } else if let array = current as? [Any], let index = Int(component) {
                current = array.indices.contains(index) ? array[index] : nil
            } else {
                return nil
            }
        }
        return current
    }

    static func string(at path: String, in object: Any) -> String? {
        guard let value = value(at: path, in: object) else { return nil }
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        case is NSNull:
            return nil
        default:
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]) else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        }
    }
}

/// Sends a transcript to a plain HTTP endpoint and extracts the answer.
enum HTTPAgentClient {
    static func makeRequest(
        connection: AgentConnection,
        values: AgentTemplateValues,
        secret: String
    ) throws -> URLRequest {
        let urlString = HTTPAgentTemplate.render(connection.url, values: values, jsonEscaped: false)
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw AgentError.invalidURL(connection.url)
        }
        var request = URLRequest(url: url)
        let method = connection.method.uppercased()
        request.httpMethod = method
        request.timeoutInterval = max(10, connection.timeoutSeconds)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        for header in connection.headers where !header.name.trimmingCharacters(in: .whitespaces).isEmpty {
            request.setValue(HTTPAgentTemplate.render(header.value, values: values, jsonEscaped: false),
                             forHTTPHeaderField: header.name)
        }
        if connection.auth == .header, !secret.isEmpty {
            request.setValue(secret, forHTTPHeaderField: connection.authHeaderName.isEmpty ? "Authorization" : connection.authHeaderName)
        }

        if method != "GET" && method != "HEAD" {
            let body = HTTPAgentTemplate.render(connection.bodyTemplate, values: values, jsonEscaped: true)
            request.httpBody = Data(body.utf8)
            if request.value(forHTTPHeaderField: "Content-Type") == nil {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }
        return request
    }

    /// The answer text from a response body: the configured JSON path, then
    /// common fields, then the raw body.
    static func extractText(from data: Data, path: String) -> String {
        let raw = String(data: data, encoding: .utf8) ?? ""
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let string = object as? String { return string }
        let trimmedPath = path.trimmingCharacters(in: .whitespaces)
        if !trimmedPath.isEmpty, let text = JSONPath.string(at: trimmedPath, in: object) {
            return text
        }
        for candidate in ["text", "output_text", "answer", "response", "output", "message", "content",
                          "choices.0.message.content", "result"] {
            if let text = JSONPath.string(at: candidate, in: object), !text.isEmpty {
                return text
            }
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func send(connection: AgentConnection, values: AgentTemplateValues, secret: String) async throws -> String {
        let request = try makeRequest(connection: connection, values: values, secret: secret)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        configuration.timeoutIntervalForResource = request.timeoutInterval
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw VoiceServiceError.http(status: status, message: VoiceServiceError.message(from: data))
        }
        return extractText(from: data, path: connection.responseTextPath)
    }
}

enum AgentError: LocalizedError {
    case invalidURL(String)
    case missingConnection(String)
    case missingTool(String)
    case invalidArguments(String)
    case authorizationRequired(String)
    case mcp(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "The connection URL is not valid: \(url)"
        case .missingConnection(let agent):
            return "\(agent) has no connection. Choose one in Settings → Agents."
        case .missingTool(let agent):
            return "\(agent) has no MCP tool selected. Choose one in Settings → Agents."
        case .invalidArguments(let message):
            return "The tool arguments are not valid JSON: \(message)"
        case .authorizationRequired(let name):
            return "\(name) needs you to sign in. Open Settings → Agents and choose Sign in."
        case .mcp(let message):
            return "MCP error: \(message)"
        }
    }
}
