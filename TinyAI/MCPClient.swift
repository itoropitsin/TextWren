import Foundation

/// Incremental parser for `text/event-stream` bodies: feed lines, receive
/// the `data` payload of each completed event.
nonisolated struct SSEParser {
    private var dataLines: [String] = []

    /// Returns the event data when `line` completes an event (blank line).
    mutating func feed(line rawLine: String) -> String? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if line.isEmpty {
            return flush()
        }
        if line.hasPrefix(":") { return nil }
        if line.hasPrefix("data:") {
            var value = String(line.dropFirst(5))
            if value.hasPrefix(" ") { value.removeFirst() }
            dataLines.append(value)
        }
        return nil
    }

    /// Emit whatever is buffered at the end of the stream.
    mutating func flush() -> String? {
        guard !dataLines.isEmpty else { return nil }
        let data = dataLines.joined(separator: "\n")
        dataLines = []
        return data
    }

    static func events(in body: String) -> [String] {
        var parser = SSEParser()
        var events: [String] = []
        for line in body.components(separatedBy: "\n") {
            if let event = parser.feed(line: line) { events.append(event) }
        }
        if let last = parser.flush() { events.append(last) }
        return events
    }
}

nonisolated struct WWWAuthenticateChallenge: Equatable, Sendable {
    var scheme: String
    var parameters: [String: String]

    var resourceMetadataURL: URL? {
        parameters["resource_metadata"].flatMap(URL.init(string:))
    }

    /// Parse the first challenge of a `WWW-Authenticate` header, e.g.
    /// `Bearer resource_metadata="https://…", scope="files:read"`.
    static func parse(_ header: String) -> WWWAuthenticateChallenge? {
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let scheme = String(trimmed.prefix { !$0.isWhitespace })
        var rest = Substring(trimmed.dropFirst(scheme.count))
        var parameters: [String: String] = [:]
        while true {
            rest = rest.drop { $0.isWhitespace || $0 == "," }
            guard let equals = rest.firstIndex(of: "=") else { break }
            let key = rest[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            rest = rest[rest.index(after: equals)...]
            var value = ""
            if rest.first == "\"" {
                rest = rest.dropFirst()
                var escaped = false
                var index = rest.startIndex
                while index < rest.endIndex {
                    let character = rest[index]
                    if escaped {
                        value.append(character)
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        break
                    } else {
                        value.append(character)
                    }
                    index = rest.index(after: index)
                }
                rest = index < rest.endIndex ? rest[rest.index(after: index)...] : rest[rest.endIndex...]
            } else {
                let end = rest.firstIndex(of: ",") ?? rest.endIndex
                value = rest[..<end].trimmingCharacters(in: .whitespaces)
                rest = rest[end...]
            }
            if !key.isEmpty { parameters[key] = value }
        }
        return WWWAuthenticateChallenge(scheme: scheme, parameters: parameters)
    }
}

enum MCPClientError: LocalizedError {
    case unauthorized(WWWAuthenticateChallenge?)
    case rpc(code: Int, message: String)
    case toolFailed(String)
    case http(status: Int, message: String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "The MCP server needs authorization."
        case .rpc(let code, let message):
            return "MCP error \(code): \(message)"
        case .toolFailed(let message):
            return "The tool reported an error: \(message)"
        case .http(let status, let message):
            return "MCP request failed (\(status)): \(message)"
        case .invalidResponse(let message):
            return "Unexpected MCP response: \(message)"
        }
    }
}

nonisolated enum MCPMessages {
    static let protocolVersion = "2025-06-18"

    static func request(id: Int, method: String, params: [String: Any]?) -> [String: Any] {
        var message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { message["params"] = params }
        return message
    }

    static func notification(method: String) -> [String: Any] {
        ["jsonrpc": "2.0", "method": method]
    }

    static func initializeParams() -> [String: Any] {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return [
            "protocolVersion": protocolVersion,
            "capabilities": [String: Any](),
            "clientInfo": ["name": "TextWren", "version": version]
        ]
    }

    static func tools(fromListResult result: [String: Any]) -> [MCPToolSummary] {
        let tools = result["tools"] as? [[String: Any]] ?? []
        return tools.compactMap { tool in
            guard let name = tool["name"] as? String else { return nil }
            var schemaJSON = #"{"type":"object"}"#
            if let schema = tool["inputSchema"],
               JSONSerialization.isValidJSONObject(schema),
               let data = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]),
               let string = String(data: data, encoding: .utf8) {
                schemaJSON = string
            }
            let description = (tool["description"] as? String) ?? (tool["title"] as? String) ?? ""
            return MCPToolSummary(name: name, description: description, inputSchemaJSON: schemaJSON)
        }
    }

    /// The readable text of a `tools/call` result.
    static func text(fromCallResult result: [String: Any]) throws -> String {
        var parts: [String] = []
        for item in result["content"] as? [[String: Any]] ?? [] {
            switch item["type"] as? String {
            case "text":
                if let text = item["text"] as? String { parts.append(text) }
            case "resource":
                if let resource = item["resource"] as? [String: Any], let text = resource["text"] as? String {
                    parts.append(text)
                }
            case "resource_link":
                if let uri = item["uri"] as? String { parts.append(uri) }
            default:
                break
            }
        }
        if parts.isEmpty, let structured = result["structuredContent"],
           JSONSerialization.isValidJSONObject(structured),
           let data = try? JSONSerialization.data(withJSONObject: structured, options: [.prettyPrinted, .sortedKeys]),
           let string = String(data: data, encoding: .utf8) {
            parts.append(string)
        }
        let text = parts.joined(separator: "\n\n")
        if result["isError"] as? Bool == true {
            throw MCPClientError.toolFailed(text.isEmpty ? "No details." : text)
        }
        return text
    }
}

/// A client for one MCP server over the Streamable HTTP transport.
final class MCPClient {
    typealias TokenProvider = () async throws -> String?

    let endpoint: URL
    private let staticHeaders: [String: String]
    private let tokenProvider: TokenProvider
    private let timeout: TimeInterval
    private var sessionId: String?
    private var negotiatedVersion: String?
    private var initialized = false
    private var nextId = 1

    init(endpoint: URL, headers: [String: String] = [:], timeout: TimeInterval = 300, tokenProvider: @escaping TokenProvider = { nil }) {
        self.endpoint = endpoint
        self.staticHeaders = headers
        self.timeout = timeout
        self.tokenProvider = tokenProvider
    }

    func listTools() async throws -> [MCPToolSummary] {
        try await ensureInitialized()
        var tools: [MCPToolSummary] = []
        var cursor: String?
        repeat {
            let params: [String: Any]? = cursor.map { ["cursor": $0] }
            let result = try await call("tools/list", params: params)
            tools += MCPMessages.tools(fromListResult: result)
            cursor = result["nextCursor"] as? String
        } while cursor != nil && tools.count < 1000
        return tools
    }

    func callTool(name: String, arguments: [String: Any]) async throws -> String {
        try await ensureInitialized()
        let result = try await call("tools/call", params: ["name": name, "arguments": arguments])
        return try MCPMessages.text(fromCallResult: result)
    }

    private func ensureInitialized() async throws {
        guard !initialized else { return }
        let result = try await rpc("initialize", params: MCPMessages.initializeParams())
        negotiatedVersion = result["protocolVersion"] as? String ?? MCPMessages.protocolVersion
        initialized = true
        try await post(MCPMessages.notification(method: "notifications/initialized"), expectsResponse: false)
    }

    /// A request after initialization; an expired session is re-created once.
    private func call(_ method: String, params: [String: Any]?) async throws -> [String: Any] {
        do {
            return try await rpc(method, params: params)
        } catch MCPClientError.http(let status, _) where status == 404 && sessionId != nil {
            sessionId = nil
            initialized = false
            try await ensureInitialized()
            return try await rpc(method, params: params)
        }
    }

    private func rpc(_ method: String, params: [String: Any]?) async throws -> [String: Any] {
        let id = nextId
        nextId += 1
        let response = try await post(MCPMessages.request(id: id, method: method, params: params), expectsResponse: true, id: id)
        guard let response else { throw MCPClientError.invalidResponse("no response to \(method)") }
        if let error = response["error"] as? [String: Any] {
            throw MCPClientError.rpc(code: error["code"] as? Int ?? 0, message: error["message"] as? String ?? "Unknown error")
        }
        return response["result"] as? [String: Any] ?? [:]
    }

    @discardableResult
    private func post(_ message: [String: Any], expectsResponse: Bool, id: Int? = nil) async throws -> [String: Any]? {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (name, value) in staticHeaders { request.setValue(value, forHTTPHeaderField: name) }
        if let sessionId { request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id") }
        if let negotiatedVersion { request.setValue(negotiatedVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        if let token = try await tokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: message)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MCPClientError.invalidResponse("not an HTTP response")
        }
        if let newSession = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
            sessionId = newSession
        }
        if http.statusCode == 401 || http.statusCode == 403 && http.value(forHTTPHeaderField: "WWW-Authenticate") != nil {
            let challenge = http.value(forHTTPHeaderField: "WWW-Authenticate").flatMap(WWWAuthenticateChallenge.parse)
            throw MCPClientError.unauthorized(challenge)
        }
        guard (200..<300).contains(http.statusCode) else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count > 4096 { break }
            }
            throw MCPClientError.http(status: http.statusCode, message: VoiceServiceError.message(from: body))
        }
        guard expectsResponse, let id else { return nil }

        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if contentType.contains("text/event-stream") {
            var parser = SSEParser()
            for try await line in bytes.lines {
                // `lines` drops empty lines, so every data line is its own
                // event here; that matches servers sending one JSON per event.
                _ = parser.feed(line: line)
                if let data = parser.flush(), let match = Self.response(in: data, id: id) {
                    return match
                }
            }
            throw MCPClientError.invalidResponse("the event stream ended without a result")
        }

        var body = Data()
        for try await byte in bytes { body.append(byte) }
        guard let object = try? JSONSerialization.jsonObject(with: body) else {
            throw MCPClientError.invalidResponse(String(data: body, encoding: .utf8) ?? "")
        }
        if let single = object as? [String: Any] { return single }
        if let batch = object as? [[String: Any]] {
            return batch.first { ($0["id"] as? Int) == id } ?? batch.first
        }
        throw MCPClientError.invalidResponse("unexpected JSON")
    }

    /// The JSON-RPC response with `id` in one SSE event payload, ignoring
    /// notifications and server requests.
    static func response(in eventData: String, id: Int) -> [String: Any]? {
        guard let data = eventData.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let candidates = (object as? [[String: Any]]) ?? [(object as? [String: Any])].compactMap { $0 }
        return candidates.first { candidate in
            guard candidate["result"] != nil || candidate["error"] != nil else { return false }
            if let number = candidate["id"] as? Int { return number == id }
            if let string = candidate["id"] as? String { return string == String(id) }
            return false
        }
    }
}
