import Foundation
import Combine

/// Persists the voice, agent and live-conversation settings.  Plain settings
/// live in UserDefaults as JSON; secrets (header values, OAuth tokens) live in
/// the Keychain under the connection's id.
final class VoiceSettingsStore: ObservableObject {
    static let transcriptionKey = "VoiceSettingsV1"
    static let connectionsKey = "AgentConnectionsV1"
    static let agentsKey = "AgentProfilesV1"
    static let liveKey = "LiveAgentSettingsV1"
    static let keychainService = "IT.TinyAI"

    @Published private(set) var configuration: VoiceConfiguration

    private let defaults: UserDefaults
    private let keychain: KeychainClient

    var transcription: TranscriptionSettings { configuration.transcription }
    var connections: [AgentConnection] { configuration.connections }
    var agents: [AgentProfile] { configuration.agents }
    var live: LiveAgentSettings { configuration.live }

    init(defaults: UserDefaults = TinyAIRuntime.userDefaults, keychain: KeychainClient = KeychainStore.client) {
        self.defaults = defaults
        self.keychain = keychain
        configuration = VoiceConfiguration(
            transcription: Self.decode(TranscriptionSettings.self, key: Self.transcriptionKey, defaults: defaults)
                ?? TranscriptionSettings(),
            connections: Self.decode([AgentConnection].self, key: Self.connectionsKey, defaults: defaults) ?? [],
            agents: Self.decode([AgentProfile].self, key: Self.agentsKey, defaults: defaults) ?? [],
            live: Self.decode(LiveAgentSettings.self, key: Self.liveKey, defaults: defaults) ?? LiveAgentSettings()
        )
    }

    func save(_ newValue: VoiceConfiguration) {
        let removedConnections = Set(configuration.connections.map(\.id))
            .subtracting(newValue.connections.map(\.id))
        for id in removedConnections {
            if let connection = configuration.connections.first(where: { $0.id == id }) {
                deleteSecrets(for: connection)
            }
        }

        var cleaned = newValue
        let connectionIds = Set(cleaned.connections.map(\.id))
        let agentIds = Set(cleaned.agents.map(\.id))
        cleaned.live.mcpConnectionIds.removeAll { !connectionIds.contains($0) }
        cleaned.live.agentIdsAsTools.removeAll { !agentIds.contains($0) }

        configuration = cleaned
        Self.encode(cleaned.transcription, key: Self.transcriptionKey, defaults: defaults)
        Self.encode(cleaned.connections, key: Self.connectionsKey, defaults: defaults)
        Self.encode(cleaned.agents, key: Self.agentsKey, defaults: defaults)
        Self.encode(cleaned.live, key: Self.liveKey, defaults: defaults)
    }

    /// Persist a connection change made outside the Settings draft, such as
    /// the tool list fetched by "Test connection".
    func updateConnection(_ connection: AgentConnection) {
        guard let index = configuration.connections.firstIndex(where: { $0.id == connection.id }) else { return }
        var updated = configuration
        updated.connections[index] = connection
        save(updated)
    }

    func connection(id: UUID?) -> AgentConnection? {
        guard let id else { return nil }
        return configuration.connections.first { $0.id == id }
    }

    func agent(id: UUID) -> AgentProfile? {
        configuration.agents.first { $0.id == id }
    }

    // MARK: Secrets

    func headerSecret(for connection: AgentConnection) -> String {
        readSecret(account: connection.headerSecretAccount) ?? ""
    }

    @discardableResult
    func setHeaderSecret(_ value: String, for connection: AgentConnection) -> Bool {
        writeSecret(value, account: connection.headerSecretAccount)
    }

    func oauthTokens(for connection: AgentConnection) -> OAuthTokenSet? {
        guard let json = readSecret(account: connection.oauthAccount),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(OAuthTokenSet.self, from: data)
    }

    @discardableResult
    func setOAuthTokens(_ tokens: OAuthTokenSet?, for connection: AgentConnection) -> Bool {
        guard let tokens,
              let data = try? JSONEncoder().encode(tokens),
              let json = String(data: data, encoding: .utf8) else {
            return keychain.delete(service: Self.keychainService, account: connection.oauthAccount, allowInteraction: true)
        }
        return writeSecret(json, account: connection.oauthAccount)
    }

    private func deleteSecrets(for connection: AgentConnection) {
        _ = keychain.delete(service: Self.keychainService, account: connection.headerSecretAccount, allowInteraction: true)
        _ = keychain.delete(service: Self.keychainService, account: connection.oauthAccount, allowInteraction: true)
    }

    private func readSecret(account: String) -> String? {
        if case .value(let value) = keychain.readString(service: Self.keychainService, account: account, allowInteraction: false) {
            return value
        }
        return nil
    }

    private func writeSecret(_ value: String, account: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return keychain.delete(service: Self.keychainService, account: account, allowInteraction: true)
        }
        return keychain.saveString(trimmed, service: Self.keychainService, account: account, allowInteraction: true)
    }

    // MARK: Coding

    private static func decode<T: Decodable>(_ type: T.Type, key: String, defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func encode<T: Encodable>(_ value: T, key: String, defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
