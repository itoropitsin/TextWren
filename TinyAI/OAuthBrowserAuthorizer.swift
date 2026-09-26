import AppKit
import CryptoKit
import Foundation
import Network

/// Tokens for one connection, stored as JSON in the Keychain.
nonisolated struct OAuthTokenSet: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var tokenEndpoint: String
    var clientId: String
    var clientSecret: String?
    var resource: String?

    func isExpired(now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) < leeway
    }
}

nonisolated struct AuthorizationServerMetadata: Equatable, Sendable {
    var issuer: String?
    var authorizationEndpoint: URL
    var tokenEndpoint: URL
    var registrationEndpoint: URL?
    var scopesSupported: [String]

    init(authorizationEndpoint: URL, tokenEndpoint: URL, registrationEndpoint: URL?, issuer: String? = nil, scopesSupported: [String] = []) {
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.registrationEndpoint = registrationEndpoint
        self.issuer = issuer
        self.scopesSupported = scopesSupported
    }

    init?(json: [String: Any]) {
        guard let authorization = (json["authorization_endpoint"] as? String).flatMap(URL.init(string:)),
              let token = (json["token_endpoint"] as? String).flatMap(URL.init(string:)) else { return nil }
        self.init(
            authorizationEndpoint: authorization,
            tokenEndpoint: token,
            registrationEndpoint: (json["registration_endpoint"] as? String).flatMap(URL.init(string:)),
            issuer: json["issuer"] as? String,
            scopesSupported: json["scopes_supported"] as? [String] ?? []
        )
    }
}

nonisolated struct ProtectedResourceMetadata: Equatable, Sendable {
    var resource: String?
    var authorizationServers: [URL]
    var scopesSupported: [String]

    init?(json: [String: Any]) {
        let servers = (json["authorization_servers"] as? [String] ?? []).compactMap(URL.init(string:))
        guard !servers.isEmpty else { return nil }
        resource = json["resource"] as? String
        authorizationServers = servers
        scopesSupported = json["scopes_supported"] as? [String] ?? []
    }
}

nonisolated enum PKCE {
    static func makeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

nonisolated enum OAuthURLs {
    /// RFC 9728 locations for a resource's metadata: path-specific first,
    /// then the origin root.
    static func protectedResourceMetadataCandidates(for resource: URL) -> [URL] {
        guard let origin = origin(of: resource) else { return [] }
        let path = resource.path == "/" ? "" : resource.path
        var candidates: [URL] = []
        if !path.isEmpty, let url = URL(string: "\(origin)/.well-known/oauth-protected-resource\(path)") {
            candidates.append(url)
        }
        if let url = URL(string: "\(origin)/.well-known/oauth-protected-resource") {
            candidates.append(url)
        }
        return candidates
    }

    /// RFC 8414 and OpenID Connect discovery locations for an issuer.
    static func authorizationServerMetadataCandidates(for issuer: URL) -> [URL] {
        guard let origin = origin(of: issuer) else { return [] }
        let path = issuer.path == "/" ? "" : issuer.path
        var strings: [String] = []
        if path.isEmpty {
            strings = ["\(origin)/.well-known/oauth-authorization-server", "\(origin)/.well-known/openid-configuration"]
        } else {
            strings = [
                "\(origin)/.well-known/oauth-authorization-server\(path)",
                "\(origin)/.well-known/openid-configuration\(path)",
                "\(origin)\(path)/.well-known/openid-configuration"
            ]
        }
        return strings.compactMap(URL.init(string:))
    }

    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        if let port = url.port { return "\(scheme)://\(host):\(port)" }
        return "\(scheme)://\(host)"
    }

    /// The canonical resource identifier for an MCP server URL (RFC 8707):
    /// no fragment, and no query.
    static func canonicalResource(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        components?.query = nil
        return components?.string ?? url.absoluteString
    }

    static func authorizationURL(
        metadata: AuthorizationServerMetadata,
        clientId: String,
        redirectURI: String,
        codeChallenge: String,
        state: String,
        resource: String?,
        scope: String?
    ) -> URL? {
        var components = URLComponents(url: metadata.authorizationEndpoint, resolvingAgainstBaseURL: false)
        var items = components?.queryItems ?? []
        items += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        if let resource { items.append(URLQueryItem(name: "resource", value: resource)) }
        if let scope, !scope.isEmpty { items.append(URLQueryItem(name: "scope", value: scope)) }
        components?.queryItems = items
        return components?.url
    }

    static func formBody(_ fields: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = fields.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    /// `code` and `state` (or `error`) from a loopback request line such as
    /// `GET /callback?code=…&state=… HTTP/1.1`.
    static func callbackParameters(fromRequest request: String) -> [String: String]? {
        guard let line = request.components(separatedBy: "\r\n").first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let components = URLComponents(string: "http://127.0.0.1\(parts[1])"),
              components.path == "/callback" else { return nil }
        var result: [String: String] = [:]
        for item in components.queryItems ?? [] {
            result[item.name] = item.value ?? ""
        }
        return result
    }
}

enum OAuthError: LocalizedError {
    case discoveryFailed(String)
    case registrationUnsupported
    case registrationFailed(String)
    case browserFailed
    case denied(String)
    case stateMismatch
    case timedOut
    case tokenFailed(String)
    case listenerFailed(String)

    var errorDescription: String? {
        switch self {
        case .discoveryFailed(let message): return "Could not find the sign-in server: \(message)"
        case .registrationUnsupported: return "The server does not allow TinyAI to register for sign-in. Use a header token instead."
        case .registrationFailed(let message): return "Client registration failed: \(message)"
        case .browserFailed: return "Could not open the browser for sign-in."
        case .denied(let message): return "Sign-in was not completed: \(message)"
        case .stateMismatch: return "The sign-in response did not match this request."
        case .timedOut: return "Sign-in timed out."
        case .tokenFailed(let message): return "Could not get an access token: \(message)"
        case .listenerFailed(let message): return "Could not receive the sign-in response: \(message)"
        }
    }
}

/// OAuth 2.1 authorization for MCP servers in the user's default browser:
/// resource and server discovery, dynamic client registration, PKCE and a
/// loopback redirect on 127.0.0.1.
enum OAuthBrowserAuthorizer {
    static let signInTimeout: TimeInterval = 300

    static func authorize(serverURL: URL, challenge: WWWAuthenticateChallenge?) async throws -> OAuthTokenSet {
        var resource = OAuthURLs.canonicalResource(serverURL)
        var issuer = URL(string: OAuthURLs.origin(of: serverURL) ?? "") ?? serverURL
        var scopes: [String] = []

        let metadataCandidates = [challenge?.resourceMetadataURL].compactMap { $0 }
            + OAuthURLs.protectedResourceMetadataCandidates(for: serverURL)
        for candidate in metadataCandidates {
            if let json = try? await fetchJSON(candidate), let metadata = ProtectedResourceMetadata(json: json) {
                issuer = metadata.authorizationServers[0]
                resource = metadata.resource ?? resource
                scopes = metadata.scopesSupported
                break
            }
        }
        if let scope = challenge?.parameters["scope"], !scope.isEmpty {
            scopes = scope.split(separator: " ").map(String.init)
        }

        let metadata = try await discoverAuthorizationServer(issuer)
        let listener = try await LoopbackListener.start()
        defer { listener.stop() }
        let redirectURI = "http://127.0.0.1:\(listener.port)/callback"

        guard let registrationEndpoint = metadata.registrationEndpoint else {
            throw OAuthError.registrationUnsupported
        }
        let (clientId, clientSecret) = try await register(at: registrationEndpoint, redirectURI: redirectURI)

        let verifier = PKCE.makeVerifier()
        let state = PKCE.makeVerifier()
        guard let authorizationURL = OAuthURLs.authorizationURL(
            metadata: metadata, clientId: clientId, redirectURI: redirectURI,
            codeChallenge: PKCE.challenge(for: verifier), state: state,
            resource: resource, scope: scopes.isEmpty ? nil : scopes.joined(separator: " ")
        ) else {
            throw OAuthError.discoveryFailed("invalid authorization endpoint")
        }
        guard NSWorkspace.shared.open(authorizationURL) else { throw OAuthError.browserFailed }

        let parameters = try await listener.waitForCallback(timeout: signInTimeout)
        if let error = parameters["error"] {
            throw OAuthError.denied(parameters["error_description"] ?? error)
        }
        guard parameters["state"] == state else { throw OAuthError.stateMismatch }
        guard let code = parameters["code"], !code.isEmpty else { throw OAuthError.denied("no authorization code") }

        var fields: [(String, String)] = [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("client_id", clientId),
            ("code_verifier", verifier),
            ("resource", resource)
        ]
        if let clientSecret { fields.append(("client_secret", clientSecret)) }
        let token = try await requestToken(at: metadata.tokenEndpoint, fields: fields)
        return OAuthTokenSet(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            expiresAt: token.expiresAt,
            tokenEndpoint: metadata.tokenEndpoint.absoluteString,
            clientId: clientId,
            clientSecret: clientSecret,
            resource: resource
        )
    }

    static func refresh(_ tokens: OAuthTokenSet) async throws -> OAuthTokenSet {
        guard let refreshToken = tokens.refreshToken, let endpoint = URL(string: tokens.tokenEndpoint) else {
            throw OAuthError.tokenFailed("no refresh token")
        }
        var fields: [(String, String)] = [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", tokens.clientId)
        ]
        if let resource = tokens.resource { fields.append(("resource", resource)) }
        if let secret = tokens.clientSecret { fields.append(("client_secret", secret)) }
        let token = try await requestToken(at: endpoint, fields: fields)
        var updated = tokens
        updated.accessToken = token.accessToken
        updated.refreshToken = token.refreshToken ?? tokens.refreshToken
        updated.expiresAt = token.expiresAt
        return updated
    }

    // MARK: Steps

    private static func discoverAuthorizationServer(_ issuer: URL) async throws -> AuthorizationServerMetadata {
        for candidate in OAuthURLs.authorizationServerMetadataCandidates(for: issuer) {
            if let json = try? await fetchJSON(candidate), let metadata = AuthorizationServerMetadata(json: json) {
                return metadata
            }
        }
        // Servers from the first MCP authorization revision use fixed paths
        // at the issuer origin.
        guard let origin = OAuthURLs.origin(of: issuer),
              let authorize = URL(string: "\(origin)/authorize"),
              let token = URL(string: "\(origin)/token") else {
            throw OAuthError.discoveryFailed(issuer.absoluteString)
        }
        return AuthorizationServerMetadata(authorizationEndpoint: authorize, tokenEndpoint: token,
                                           registrationEndpoint: URL(string: "\(origin)/register"))
    }

    private static func register(at endpoint: URL, redirectURI: String) async throws -> (String, String?) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_name": "TinyAI",
            "redirect_uris": [redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none"
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clientId = json["client_id"] as? String else {
            if status == 404 { throw OAuthError.registrationUnsupported }
            throw OAuthError.registrationFailed(VoiceServiceError.message(from: data))
        }
        return (clientId, json["client_secret"] as? String)
    }

    private struct TokenResponse {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
    }

    private static func requestToken(at endpoint: URL, fields: [(String, String)]) async throws -> TokenResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = OAuthURLs.formBody(fields)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = (json?["error_description"] as? String) ?? (json?["error"] as? String)
                ?? VoiceServiceError.message(from: data)
            throw OAuthError.tokenFailed(message)
        }
        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue
        return TokenResponse(
            accessToken: accessToken,
            refreshToken: json["refresh_token"] as? String,
            expiresAt: expiresIn.map { Date().addingTimeInterval($0) }
        )
    }

    private static func fetchJSON(_ url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(MCPMessages.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OAuthError.discoveryFailed(url.absoluteString)
        }
        return json
    }
}

/// A one-shot HTTP listener on 127.0.0.1 that receives the OAuth redirect.
final class LoopbackListener {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "IT.TinyAI.OAuthLoopback")
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var pendingResult: Result<[String: String], Error>?
    private let lock = NSLock()
    private(set) var port: UInt16 = 0

    private init(listener: NWListener) {
        self.listener = listener
    }

    static func start() async throws -> LoopbackListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let nwListener: NWListener
        do {
            nwListener = try NWListener(using: parameters)
        } catch {
            throw OAuthError.listenerFailed(error.localizedDescription)
        }
        let loopback = LoopbackListener(listener: nwListener)
        try await loopback.run()
        return loopback
    }

    private func run() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { (ready: CheckedContinuation<UInt16, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { [weak listener] state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    ready.resume(returning: listener?.port?.rawValue ?? 0)
                case .failed(let error):
                    resumed = true
                    ready.resume(throwing: OAuthError.listenerFailed(error.localizedDescription))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        self.port = port
    }

    func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self?.finish(.failure(OAuthError.timedOut))
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let pending = pendingResult {
                pendingResult = nil
                lock.unlock()
                continuation.resume(with: pending)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func stop() {
        listener.cancel()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<[String: String], Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil, pendingResult == nil, case .success = result {
            pendingResult = result
        }
        lock.unlock()
        continuation?.resume(with: result)
    }

    private nonisolated func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let parameters = OAuthURLs.callbackParameters(fromRequest: request)
            let succeeded = parameters != nil && parameters?["error"] == nil
            let message = parameters == nil
                ? "Not found."
                : (succeeded ? "TinyAI is signed in. You can close this tab." : "Sign-in was not completed. You can close this tab.")
            let html = "<!doctype html><meta charset=utf-8><title>TinyAI</title><body style=\"font:16px -apple-system;padding:40px\">\(message)</body>"
            let status = parameters == nil ? "404 Not Found" : "200 OK"
            let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
            if let parameters {
                DispatchQueue.main.async { self?.finish(.success(parameters)) }
            }
        }
    }
}
