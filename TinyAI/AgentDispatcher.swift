import Foundation

/// Sends transcripts to agent connections (HTTP or MCP) and owns the MCP
/// clients, conversation session ids and OAuth tokens they need.
final class AgentDispatcher {
    private let store: VoiceSettingsStore
    private var sessions: [UUID: (id: String, lastUsed: Date)] = [:]
    private var mcpClients: [UUID: (url: String, client: MCPClient)] = [:]
    private var signInTasks: [UUID: Task<OAuthTokenSet, Error>] = [:]

    init(store: VoiceSettingsStore) {
        self.store = store
    }

    /// Ask an agent profile.  Returns the answer text.
    func send(profile: AgentProfile, transcript: String, language: String) async throws -> String {
        guard let connection = store.connection(id: profile.connectionId) else {
            throw AgentError.missingConnection(profile.name)
        }
        let values = AgentTemplateValues(
            transcript: transcript,
            sessionId: sessionId(for: profile),
            language: language,
            agentName: profile.name
        )
        switch connection.kind {
        case .http:
            return try await HTTPAgentClient.send(
                connection: connection, values: values, secret: store.headerSecret(for: connection)
            )
        case .mcp:
            let toolName = profile.mcpToolName.trimmingCharacters(in: .whitespaces)
            guard !toolName.isEmpty else { throw AgentError.missingTool(profile.name) }
            let arguments = try Self.arguments(from: profile.argumentsTemplate, values: values)
            return try await callTool(connection: connection, name: toolName, arguments: arguments)
        }
    }

    static func arguments(from template: String, values: AgentTemplateValues) throws -> [String: Any] {
        let rendered = HTTPAgentTemplate.render(template, values: values, jsonEscaped: true)
        guard !rendered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        do {
            guard let object = try JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any] else {
                throw AgentError.invalidArguments("the template must be a JSON object")
            }
            return object
        } catch let error as AgentError {
            throw error
        } catch {
            throw AgentError.invalidArguments(error.localizedDescription)
        }
    }

    func listTools(connection: AgentConnection) async throws -> [MCPToolSummary] {
        try await withAuthorization(connection) { client in
            try await client.listTools()
        }
    }

    func callTool(connection: AgentConnection, name: String, arguments: [String: Any]) async throws -> String {
        try await withAuthorization(connection) { client in
            try await client.callTool(name: name, arguments: arguments)
        }
    }

    /// Run the browser sign-in for a connection and store its tokens.
    @discardableResult
    func signIn(connection: AgentConnection, challenge: WWWAuthenticateChallenge? = nil) async throws -> OAuthTokenSet {
        if let running = signInTasks[connection.id] {
            return try await running.value
        }
        guard let url = URL(string: connection.url) else { throw AgentError.invalidURL(connection.url) }
        let task = Task { try await OAuthBrowserAuthorizer.authorize(serverURL: url, challenge: challenge) }
        signInTasks[connection.id] = task
        defer { signInTasks[connection.id] = nil }
        let tokens = try await task.value
        store.setOAuthTokens(tokens, for: connection)
        mcpClients[connection.id] = nil
        return tokens
    }

    func signOut(connection: AgentConnection) {
        store.setOAuthTokens(nil, for: connection)
        mcpClients[connection.id] = nil
    }

    func resetSessions() {
        sessions = [:]
        mcpClients = [:]
    }

    // MARK: Private

    private func sessionId(for profile: AgentProfile) -> String {
        let now = Date()
        let idle = TimeInterval(max(1, profile.sessionIdleMinutes) * 60)
        if let existing = sessions[profile.id], now.timeIntervalSince(existing.lastUsed) < idle {
            sessions[profile.id] = (existing.id, now)
            return existing.id
        }
        let id = UUID().uuidString
        sessions[profile.id] = (id, now)
        return id
    }

    private func withAuthorization<T>(_ connection: AgentConnection, _ body: (MCPClient) async throws -> T) async throws -> T {
        let client = try mcpClient(for: connection)
        do {
            return try await body(client)
        } catch MCPClientError.unauthorized(let challenge) {
            guard connection.auth == .oauth else {
                throw AgentError.authorizationRequired(connection.name)
            }
            try await signIn(connection: connection, challenge: challenge)
            return try await body(try mcpClient(for: connection))
        }
    }

    private func mcpClient(for connection: AgentConnection) throws -> MCPClient {
        if let cached = mcpClients[connection.id], cached.url == connection.url {
            return cached.client
        }
        guard let url = URL(string: connection.url.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw AgentError.invalidURL(connection.url)
        }
        var headers: [String: String] = [:]
        for header in connection.headers where !header.name.trimmingCharacters(in: .whitespaces).isEmpty {
            headers[header.name] = header.value
        }
        if connection.auth == .header {
            let secret = store.headerSecret(for: connection)
            if !secret.isEmpty {
                headers[connection.authHeaderName.isEmpty ? "Authorization" : connection.authHeaderName] = secret
            }
        }
        let tokenProvider: MCPClient.TokenProvider
        if connection.auth == .oauth {
            tokenProvider = { [weak self] in
                try await self?.accessToken(for: connection)
            }
        } else {
            tokenProvider = { nil }
        }
        let client = MCPClient(endpoint: url, headers: headers, timeout: max(30, connection.timeoutSeconds), tokenProvider: tokenProvider)
        mcpClients[connection.id] = (connection.url, client)
        return client
    }

    private func accessToken(for connection: AgentConnection) async throws -> String? {
        guard var tokens = store.oauthTokens(for: connection) else { return nil }
        if tokens.isExpired() {
            guard tokens.refreshToken != nil else { return nil }
            do {
                tokens = try await OAuthBrowserAuthorizer.refresh(tokens)
                store.setOAuthTokens(tokens, for: connection)
            } catch {
                return nil
            }
        }
        return tokens.accessToken
    }
}
