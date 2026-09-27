import Testing
import Foundation
import AppKit
@testable import TinyAI

@MainActor
private final class MemoryKeychain: KeychainClient {
    var values: [String: String] = [:]

    func readString(service: String, account: String, allowInteraction: Bool) -> KeychainReadResult {
        values[account].map { .value($0) } ?? .missing
    }

    func saveString(_ value: String, service: String, account: String, allowInteraction: Bool) -> Bool {
        values[account] = value
        return true
    }

    func delete(service: String, account: String, allowInteraction: Bool) -> Bool {
        values[account] = nil
        return true
    }
}

private func freshDefaults() -> UserDefaults {
    let suite = "IT.TinyAI.VoiceTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

private func json(_ data: Data?) -> [String: Any] {
    guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return object
}

// MARK: - Settings

@MainActor
struct VoiceSettingsTests {
    @Test func transcriptionDefaultsWhenDecodingEmptyObject() throws {
        let settings = try JSONDecoder().decode(TranscriptionSettings.self, from: Data("{}".utf8))
        #expect(settings == TranscriptionSettings())
        #expect(settings.dictationHotkey == VoiceHotkey(shortcut: .modifierOnly([.function, .control]), mode: .holdOrToggle))
        #expect(settings.engine == .openAI)
        #expect(settings.openAIModel == "gpt-live-transcribe")
    }

    @Test func firstLaunchDictationHotkeyIsFnControl() {
        let suite = "TinyAI.Tests.FirstLaunch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = VoiceSettingsStore(defaults: defaults)
        #expect(store.configuration.transcription.dictationHotkey?.shortcut == .modifierOnly([.function, .control]))
        #expect(store.configuration.transcription.dictationHotkey?.displayString == "fn ⌃")
    }

    @Test func savedDictationHotkeySurvivesTheNewDefault() throws {
        var saved = TranscriptionSettings()
        saved.dictationHotkey = VoiceHotkey(keyCode: 9, modifiers: [.control]) // ⌃V from an older version
        let decoded = try JSONDecoder().decode(TranscriptionSettings.self, from: JSONEncoder().encode(saved))
        #expect(decoded.dictationHotkey == VoiceHotkey(keyCode: 9, modifiers: [.control]))
    }

    @Test func clearedDictationHotkeyStaysCleared() throws {
        var settings = TranscriptionSettings()
        settings.dictationHotkey = nil
        let decoded = try JSONDecoder().decode(TranscriptionSettings.self, from: JSONEncoder().encode(settings))
        #expect(decoded.dictationHotkey == nil)
    }

    @Test func profilesRoundTrip() throws {
        var connection = AgentConnection()
        connection.kind = .mcp
        connection.url = "https://mcp.example.com/mcp"
        connection.auth = .oauth
        connection.cachedTools = [MCPToolSummary(name: "search", description: "Find", inputSchemaJSON: #"{"type":"object"}"#)]
        var agent = AgentProfile()
        agent.connectionId = connection.id
        agent.hotkey = VoiceHotkey(keyCode: 0, modifiers: [.control, .option], mode: .pushToTalk)
        agent.speech.engine = .openAI
        var live = LiveAgentSettings()
        live.backendModel = "gpt-6-sol"
        live.mcpConnectionIds = [connection.id]

        #expect(try JSONDecoder().decode(AgentConnection.self, from: JSONEncoder().encode(connection)) == connection)
        #expect(try JSONDecoder().decode(AgentProfile.self, from: JSONEncoder().encode(agent)) == agent)
        #expect(try JSONDecoder().decode(LiveAgentSettings.self, from: JSONEncoder().encode(live)) == live)
    }

    @Test func localModelCatalogIsPinned() {
        for model in LocalTranscriptionModel.allCases {
            #expect(model.sha256.count == 64)
            #expect(model.sha256.allSatisfy { $0.isHexDigit })
            #expect(model.revision.count == 40)
            #expect(model.downloadURLs.first?.absoluteString
                    == "https://huggingface.co/\(model.repository)/resolve/\(model.revision)/\(model.filename)")
            #expect(model.downloadURLs.count == 2)
            #expect(model.filename.hasSuffix(".gguf"))
            #expect(model.modelCardURL.absoluteString == "https://huggingface.co/\(model.repository)")
        }
        #expect(LocalTranscriptionModel.voxtralMini4BRealtime.languages.contains("ru"))
        #expect(LocalTranscriptionModel.nemotronStreaming35.languages.contains("ru"))
        #expect(!LocalTranscriptionModel.canary180MFlash.supportsStreaming)
        #expect(LocalTranscriptionModel.voxtralMini4BRealtime.supportsStreaming)
    }

    @Test func unknownOpenAIModelFallsBackToDefault() {
        #expect(OpenAITranscriptionModel.all.map(\.id) == ["gpt-live-transcribe", "gpt-transcribe"])
        #expect(OpenAITranscriptionModel.resolve("whisper-0").id == "gpt-live-transcribe")
        #expect(OpenAITranscriptionModel.resolve("gpt-live-transcribe").mode == .realtime)
    }

    @Test func existingTranscriptionChoiceIsPreserved() throws {
        let settings = try JSONDecoder().decode(TranscriptionSettings.self,
                                                from: Data(#"{"openAIModel":"gpt-transcribe"}"#.utf8))
        #expect(settings.openAIModel == "gpt-transcribe")
    }

    @Test func nemotronOnboardingOnlyWhenNoVoiceEngineIsAvailable() {
        #expect(VoiceOnboarding.shouldOfferNemotron(hasOpenAIKey: false, hasDownloadedModel: false, alreadyPrompted: false))
        #expect(!VoiceOnboarding.shouldOfferNemotron(hasOpenAIKey: true, hasDownloadedModel: false, alreadyPrompted: false))
        #expect(!VoiceOnboarding.shouldOfferNemotron(hasOpenAIKey: false, hasDownloadedModel: true, alreadyPrompted: false))
        #expect(!VoiceOnboarding.shouldOfferNemotron(hasOpenAIKey: false, hasDownloadedModel: false, alreadyPrompted: true))
    }

    @Test func storePersistsAndCleansUp() {
        let defaults = freshDefaults()
        let keychain = MemoryKeychain()
        let store = VoiceSettingsStore(defaults: defaults, keychain: keychain)
        var configuration = store.configuration
        var connection = AgentConnection()
        connection.auth = .header
        var agent = AgentProfile()
        agent.connectionId = connection.id
        configuration.connections = [connection]
        configuration.agents = [agent]
        configuration.live.mcpConnectionIds = [connection.id, UUID()]
        configuration.live.agentIdsAsTools = [agent.id]
        store.save(configuration)
        store.setHeaderSecret("Bearer secret", for: connection)

        #expect(store.configuration.live.mcpConnectionIds == [connection.id])
        let reloaded = VoiceSettingsStore(defaults: defaults, keychain: keychain)
        #expect(reloaded.configuration == store.configuration)
        #expect(reloaded.headerSecret(for: connection) == "Bearer secret")

        var removed = reloaded.configuration
        removed.connections = []
        reloaded.save(removed)
        #expect(keychain.values[connection.headerSecretAccount] == nil)
        #expect(reloaded.configuration.live.mcpConnectionIds.isEmpty)
    }

    @Test func oauthTokensRoundTripThroughKeychain() {
        let store = VoiceSettingsStore(defaults: freshDefaults(), keychain: MemoryKeychain())
        let connection = AgentConnection()
        let tokens = OAuthTokenSet(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
                                   tokenEndpoint: "https://auth.example.com/token", clientId: "c", clientSecret: nil,
                                   resource: "https://mcp.example.com/mcp")
        store.setOAuthTokens(tokens, for: connection)
        #expect(store.oauthTokens(for: connection) == tokens)
        store.setOAuthTokens(nil, for: connection)
        #expect(store.oauthTokens(for: connection) == nil)
    }

    @Test func tokenExpiry() {
        let now = Date()
        var tokens = OAuthTokenSet(accessToken: "a", refreshToken: nil, expiresAt: now.addingTimeInterval(30),
                                   tokenEndpoint: "", clientId: "", clientSecret: nil, resource: nil)
        #expect(tokens.isExpired(now: now))
        tokens.expiresAt = now.addingTimeInterval(3600)
        #expect(!tokens.isExpired(now: now))
        tokens.expiresAt = nil
        #expect(!tokens.isExpired(now: now))
    }
}

// MARK: - Hotkeys

@MainActor
struct VoiceHotkeyTests {
    private let popup = KeyboardShortcut(keyCode: 8, modifiers: [.command])

    @Test func voiceShortcutsNeedAModifier() {
        #expect(KeyboardMonitor.voiceValidationError(for: KeyboardShortcut(keyCode: 49, modifiers: []), popupHotkey: popup, otherVoiceHotkeys: []) != nil)
        #expect(KeyboardMonitor.voiceValidationError(for: KeyboardShortcut(keyCode: 49, modifiers: [.shift]), popupHotkey: popup, otherVoiceHotkeys: []) != nil)
        #expect(KeyboardMonitor.voiceValidationError(for: KeyboardShortcut(keyCode: 49, modifiers: [.option]), popupHotkey: popup, otherVoiceHotkeys: []) == nil)
        #expect(KeyboardMonitor.voiceValidationError(for: KeyboardShortcut(keyCode: 9, modifiers: [.control]), popupHotkey: popup, otherVoiceHotkeys: []) == nil)
    }

    @Test func voiceShortcutsAvoidReservedAndTakenKeys() {
        #expect(KeyboardMonitor.voiceValidationError(for: popup, popupHotkey: popup, otherVoiceHotkeys: []) != nil)
        #expect(KeyboardMonitor.voiceValidationError(for: KeyboardShortcut(keyCode: 18, modifiers: [.command]), popupHotkey: popup, otherVoiceHotkeys: []) != nil)
        #expect(KeyboardMonitor.voiceValidationError(for: KeyboardShortcut(keyCode: 49, modifiers: [.command]), popupHotkey: popup, otherVoiceHotkeys: []) != nil)
        #expect(KeyboardMonitor.voiceValidationError(for: KeyboardShortcut(keyCode: 49, modifiers: [.control]), popupHotkey: popup, otherVoiceHotkeys: []) != nil)
        #expect(KeyboardMonitor.voiceValidationError(for: KeyboardShortcut(keyCode: 53, modifiers: [.option]), popupHotkey: popup, otherVoiceHotkeys: []) != nil)
        let taken = KeyboardShortcut(keyCode: 0, modifiers: [.control, .option])
        #expect(KeyboardMonitor.voiceValidationError(for: taken, popupHotkey: popup, otherVoiceHotkeys: [taken]) != nil)
    }

    @Test func draftConflictsAreReported() {
        var draft = VoiceConfiguration()
        var agent = AgentProfile()
        agent.name = "Research"
        agent.hotkey = draft.transcription.dictationHotkey
        draft.agents = [agent]
        #expect(VoiceHotkeySlots.firstError(in: draft, popupHotkey: popup) != nil)
        draft.agents[0].hotkey = VoiceHotkey(keyCode: 15, modifiers: [.control, .option])
        #expect(VoiceHotkeySlots.firstError(in: draft, popupHotkey: popup) == nil)
    }

    @Test func triggerIdsRoundTrip() {
        let id = UUID()
        #expect(VoiceTrigger(hotkeyId: VoiceTrigger.agent(id).hotkeyId) == .agent(id))
        #expect(VoiceTrigger(hotkeyId: "dictation") == .dictation)
        #expect(VoiceTrigger(hotkeyId: "live") == nil)
    }

    @Test func holdOrToggleHoldStopsOnRelease() {
        var interpreter = HotkeyPressInterpreter(mode: .holdOrToggle)
        let start = Date()
        #expect(interpreter.keyDown(at: start) == .start)
        #expect(interpreter.keyUp(at: start.addingTimeInterval(1)) == .stop)
        #expect(!interpreter.isActive)
    }

    @Test func holdOrToggleTapKeepsRecordingUntilNextPress() {
        var interpreter = HotkeyPressInterpreter(mode: .holdOrToggle)
        let start = Date()
        #expect(interpreter.keyDown(at: start) == .start)
        #expect(interpreter.keyUp(at: start.addingTimeInterval(0.1)) == .none)
        #expect(interpreter.keyDown(at: start.addingTimeInterval(3)) == .stop)
        #expect(interpreter.keyUp(at: start.addingTimeInterval(3.1)) == .none)
    }

    @Test func pushToTalkAndToggleModes() {
        var push = HotkeyPressInterpreter(mode: .pushToTalk)
        #expect(push.keyDown() == .start)
        #expect(push.keyDown() == .none)
        #expect(push.keyUp() == .stop)

        var toggle = HotkeyPressInterpreter(mode: .toggle)
        #expect(toggle.keyDown() == .start)
        #expect(toggle.keyUp() == .none)
        #expect(toggle.keyDown() == .stop)
    }

    // MARK: Modifier-only shortcuts

    private let fnControl = KeyboardShortcut.modifierOnly([.function, .control])

    @Test func modifierOnlyShortcut_displaysAndRoundTrips() {
        #expect(fnControl.isModifierOnly)
        #expect(fnControl.displayString == "fn ⌃")
        let stored = VoiceHotkey(shortcut: fnControl, mode: .holdOrToggle)
        #expect(stored.shortcut == fnControl)
        #expect(!KeyboardShortcut(keyCode: 9, modifiers: [.control]).isModifierOnly)
    }

    @Test func modifierOnlyShortcut_validation() {
        #expect(KeyboardMonitor.voiceValidationError(for: fnControl, popupHotkey: popup, otherVoiceHotkeys: []) == nil)
        #expect(KeyboardMonitor.voiceValidationError(for: .modifierOnly([.control, .option]), popupHotkey: popup, otherVoiceHotkeys: []) == nil)
        // One modifier alone, or fn/⇧ without ⌘, ⌥ or ⌃, is rejected.
        #expect(KeyboardMonitor.voiceValidationError(for: .modifierOnly([.control]), popupHotkey: popup, otherVoiceHotkeys: []) != nil)
        #expect(KeyboardMonitor.voiceValidationError(for: .modifierOnly([.function, .shift]), popupHotkey: popup, otherVoiceHotkeys: []) != nil)
        // ⌃⌥ held would block ⌃⌥R, in either order of assignment.
        let keyed = KeyboardShortcut(keyCode: 15, modifiers: [.control, .option])
        #expect(KeyboardMonitor.voiceValidationError(for: .modifierOnly([.control, .option]), popupHotkey: popup, otherVoiceHotkeys: [keyed]) != nil)
        #expect(KeyboardMonitor.voiceValidationError(for: keyed, popupHotkey: popup, otherVoiceHotkeys: [.modifierOnly([.control, .option])]) != nil)
        // Keyed shortcuts never carry fn, so fn⌃ and ⌃V can coexist.
        #expect(KeyboardMonitor.voiceValidationError(for: fnControl, popupHotkey: popup, otherVoiceHotkeys: [KeyboardShortcut(keyCode: 9, modifiers: [.control])]) == nil)
        #expect(KeyboardMonitor.voiceValidationError(for: fnControl, popupHotkey: popup, otherVoiceHotkeys: [fnControl]) != nil)
    }

    @Test func popupShortcut_needsAKey() {
        #expect(KeyboardMonitor.validationError(for: .modifierOnly([.command, .shift]), pressMode: .doublePress) != nil)
    }

    @Test func modifierOnlyTransitions() {
        let registrations = [VoiceHotkeyRegistration(id: "dictation", shortcut: fnControl)]
        func transition(_ held: ShortcutModifiers, heldId: String? = nil, keyCode: Int64? = nil) -> KeyboardMonitor.ModifierOnlyTransition? {
            KeyboardMonitor.modifierOnlyTransition(held: held, heldVoiceHotkeyId: heldId, heldVoiceKeyCode: keyCode, registrations: registrations)
        }
        let heldCode = KeyboardShortcut.modifierOnlyKeyCode

        // Pressing fn, then ⌃: only the exact set starts it.
        #expect(transition([.function]) == nil)
        #expect(transition([.function, .control]) == .down("dictation"))
        #expect(transition([.function, .control, .shift]) == nil)
        // Adding a modifier while held keeps it down; releasing either one stops it.
        #expect(transition([.function, .control, .shift], heldId: "dictation", keyCode: heldCode) == nil)
        #expect(transition([.control], heldId: "dictation", keyCode: heldCode) == .up("dictation"))
        #expect(transition([], heldId: "dictation", keyCode: heldCode) == .up("dictation"))
        // A held keyed shortcut is left to its own key-up.
        #expect(transition([.control], heldId: "dictation", keyCode: 9) == nil)
    }
}

// MARK: - Audio

struct AudioCodingTests {
    @Test func wavHeaderDescribesMonoPCM16() {
        let wav = AudioCoding.wavData(samples: [0, 0.5, -0.5, 1], sampleRate: 16_000)
        #expect(wav.count == 44 + 8)
        #expect(String(data: wav.prefix(4), encoding: .ascii) == "RIFF")
        #expect(String(data: wav.subdata(in: 8..<12), encoding: .ascii) == "WAVE")
        let sampleRate = wav.subdata(in: 24..<28).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(UInt32(littleEndian: sampleRate) == 16_000)
        let dataSize = wav.subdata(in: 40..<44).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(UInt32(littleEndian: dataSize) == 8)
    }

    @Test func pcm16RoundTripAndClamping() {
        let samples: [Float] = [0, 0.25, -0.25, 2, -2]
        let decoded = AudioCoding.floatSamples(fromPCM16: AudioCoding.pcm16Data(from: samples))
        #expect(decoded.count == 5)
        #expect(abs(decoded[1] - 0.25) < 0.001)
        #expect(abs(decoded[2] + 0.25) < 0.001)
        #expect(decoded[3] > 0.999)
        #expect(decoded[4] == -1)
    }

    @Test func rmsLevel() {
        #expect(AudioCoding.rmsLevel([]) == 0)
        #expect(abs(AudioCoding.rmsLevel([0.5, -0.5]) - 0.5) < 0.0001)
    }
}

// MARK: - HTTP agents

@MainActor
struct HTTPAgentTests {
    private let values = AgentTemplateValues(transcript: "Say \"hi\"\nи ещё строка", sessionId: "s-1", language: "ru", agentName: "Research")

    @Test func bodyTemplateEscapesTranscript() throws {
        let body = HTTPAgentTemplate.render(HTTPAgentTemplate.defaultBody, values: values, jsonEscaped: true)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: String])
        #expect(object["input"] == "Say \"hi\"\nи ещё строка")
        #expect(object["session_id"] == "s-1")
    }

    @Test func unknownPlaceholdersAreKept() {
        #expect(HTTPAgentTemplate.render("{{ transcript }} {{other}} {{", values: values, jsonEscaped: false)
                == "Say \"hi\"\nи ещё строка {{other}} {{")
    }

    @Test func jsonPathFollowsKeysAndIndexes() throws {
        let object = try JSONSerialization.jsonObject(with: Data(#"{"choices":[{"message":{"content":"Answer"}}],"n":3}"#.utf8))
        #expect(JSONPath.string(at: "choices.0.message.content", in: object) == "Answer")
        #expect(JSONPath.string(at: "n", in: object) == "3")
        #expect(JSONPath.string(at: "choices.4.message", in: object) == nil)
    }

    @Test func answerExtractionFallsBack() {
        #expect(HTTPAgentClient.extractText(from: Data(#"{"data":{"reply":"x"}}"#.utf8), path: "data.reply") == "x")
        #expect(HTTPAgentClient.extractText(from: Data(#"{"output_text":"y"}"#.utf8), path: "missing") == "y")
        #expect(HTTPAgentClient.extractText(from: Data("plain answer\n".utf8), path: "text") == "plain answer")
        #expect(HTTPAgentClient.extractText(from: Data(#""quoted""#.utf8), path: "") == "quoted")
    }

    @Test func requestCarriesHeadersSecretAndBody() throws {
        var connection = AgentConnection()
        connection.url = "https://agents.example.com/ask?agent={{agent}}"
        connection.auth = .header
        connection.authHeaderName = "X-Api-Key"
        connection.headers = [HTTPHeaderField(name: "X-Session", value: "{{sessionId}}")]
        let request = try HTTPAgentClient.makeRequest(connection: connection, values: values, secret: "k-123")
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://agents.example.com/ask?agent=Research")
        #expect(request.value(forHTTPHeaderField: "X-Api-Key") == "k-123")
        #expect(request.value(forHTTPHeaderField: "X-Session") == "s-1")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(json(request.httpBody)["session_id"] as? String == "s-1")
        #expect(request.timeoutInterval == 300)
    }

    @Test func getRequestsHaveNoBodyAndBadURLsFail() throws {
        var connection = AgentConnection()
        connection.url = "https://agents.example.com/ask"
        connection.method = "GET"
        #expect(try HTTPAgentClient.makeRequest(connection: connection, values: values, secret: "").httpBody == nil)
        connection.url = "ftp://example.com"
        #expect(throws: AgentError.self) { try HTTPAgentClient.makeRequest(connection: connection, values: values, secret: "") }
    }

    @Test func mcpArgumentsTemplate() throws {
        let arguments = try AgentDispatcher.arguments(from: #"{"query": "{{transcript}}", "limit": 3}"#, values: values)
        #expect(arguments["query"] as? String == values.transcript)
        #expect(arguments["limit"] as? Int == 3)
        #expect(throws: AgentError.self) { try AgentDispatcher.arguments(from: "[1]", values: values) }
        #expect(throws: AgentError.self) { try AgentDispatcher.arguments(from: "{oops", values: values) }
    }
}

// MARK: - MCP

@MainActor
struct MCPProtocolTests {
    @Test func sseParserSplitsEvents() {
        let body = ": comment\nevent: message\ndata: {\"a\":1}\n\ndata: line1\ndata: line2\n\ndata: tail"
        #expect(SSEParser.events(in: body) == ["{\"a\":1}", "line1\nline2", "tail"])
    }

    @Test func responseMatchingIgnoresNotifications() {
        #expect(MCPClient.response(in: #"{"jsonrpc":"2.0","method":"notifications/progress","params":{}}"#, id: 2) == nil)
        #expect(MCPClient.response(in: #"{"jsonrpc":"2.0","id":1,"result":{}}"#, id: 2) == nil)
        #expect(MCPClient.response(in: #"{"jsonrpc":"2.0","id":2,"result":{"ok":true}}"#, id: 2) != nil)
        #expect(MCPClient.response(in: #"[{"jsonrpc":"2.0","id":"2","error":{"code":-1,"message":"x"}}]"#, id: 2) != nil)
    }

    @Test func toolsAndResultsAreParsed() throws {
        let tools = MCPMessages.tools(fromListResult: [
            "tools": [["name": "search", "description": "Search docs", "inputSchema": ["type": "object", "properties": ["q": ["type": "string"]]]],
                      ["description": "nameless"]]
        ])
        #expect(tools.map(\.name) == ["search"])
        #expect(tools[0].inputSchemaJSON.contains("\"q\""))

        #expect(try MCPMessages.text(fromCallResult: ["content": [["type": "text", "text": "a"], ["type": "image"], ["type": "text", "text": "b"]]]) == "a\n\nb")
        #expect(try MCPMessages.text(fromCallResult: ["content": [], "structuredContent": ["x": 1]]).contains("\"x\""))
        #expect(throws: MCPClientError.self) {
            try MCPMessages.text(fromCallResult: ["content": [["type": "text", "text": "bad"]], "isError": true])
        }
    }

    @Test func initializeAndRequestShapes() {
        let request = MCPMessages.request(id: 7, method: "tools/call", params: ["name": "x"])
        #expect(request["jsonrpc"] as? String == "2.0")
        #expect(request["id"] as? Int == 7)
        let params = MCPMessages.initializeParams()
        #expect(params["protocolVersion"] as? String == MCPMessages.protocolVersion)
        #expect((params["clientInfo"] as? [String: Any])?["name"] as? String == "TextWren")
        #expect(MCPMessages.notification(method: "notifications/initialized")["id"] == nil)
    }

    @Test func wwwAuthenticateParsing() {
        let challenge = WWWAuthenticateChallenge.parse(#"Bearer error="invalid_token", resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource", scope="read write""#)
        #expect(challenge?.scheme == "Bearer")
        #expect(challenge?.resourceMetadataURL?.absoluteString == "https://mcp.example.com/.well-known/oauth-protected-resource")
        #expect(challenge?.parameters["scope"] == "read write")
        #expect(challenge?.parameters["error"] == "invalid_token")
        #expect(WWWAuthenticateChallenge.parse("Bearer realm=example")?.parameters["realm"] == "example")
    }
}

/// Serves a scripted MCP server for `mcp.tinyai.test`.
private final class MCPStubProtocol: URLProtocol {
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "mcp.tinyai.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
        }
        var recorded = request
        recorded.httpBody = body
        Self.requests.append(recorded)
        let message = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        let method = message["method"] as? String ?? ""
        let id = message["id"] as? Int ?? 0

        var headers = ["Mcp-Session-Id": "session-42"]
        var payload = Data()
        switch method {
        case "initialize":
            headers["Content-Type"] = "application/json"
            payload = Data(#"{"jsonrpc":"2.0","id":\#(id),"result":{"protocolVersion":"2025-06-18","capabilities":{}}}"#.utf8)
        case "notifications/initialized":
            payload = Data()
        case "tools/list":
            headers["Content-Type"] = "text/event-stream"
            let cursor = (message["params"] as? [String: Any])?["cursor"] as? String
            let result = cursor == nil
                ? #"{"tools":[{"name":"one","inputSchema":{"type":"object"}}],"nextCursor":"p2"}"#
                : #"{"tools":[{"name":"two","inputSchema":{"type":"object"}}]}"#
            payload = Data("data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\"}\n\ndata: {\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":\(result)}\n\n".utf8)
        case "tools/call":
            headers["Content-Type"] = "application/json"
            payload = Data(#"{"jsonrpc":"2.0","id":\#(id),"result":{"content":[{"type":"text","text":"called"}]}}"#.utf8)
        default:
            break
        }
        let status = method == "notifications/initialized" ? 202 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
@Suite(.serialized)
struct MCPClientStubTests {
    @Test func listsToolsAcrossPagesAndCallsTools() async throws {
        URLProtocol.registerClass(MCPStubProtocol.self)
        defer { URLProtocol.unregisterClass(MCPStubProtocol.self) }
        MCPStubProtocol.requests = []

        let client = MCPClient(endpoint: URL(string: "https://mcp.tinyai.test/mcp")!, headers: ["X-Key": "k"]) { "token-1" }
        let tools = try await client.listTools()
        #expect(tools.map(\.name) == ["one", "two"])
        #expect(try await client.callTool(name: "one", arguments: ["q": "hi"]) == "called")

        let methods = MCPStubProtocol.requests.map { json($0.httpBody)["method"] as? String ?? "" }
        #expect(methods == ["initialize", "notifications/initialized", "tools/list", "tools/list", "tools/call"])
        let later = MCPStubProtocol.requests[2]
        #expect(later.value(forHTTPHeaderField: "Mcp-Session-Id") == "session-42")
        #expect(later.value(forHTTPHeaderField: "MCP-Protocol-Version") == "2025-06-18")
        #expect(later.value(forHTTPHeaderField: "Authorization") == "Bearer token-1")
        #expect(later.value(forHTTPHeaderField: "X-Key") == "k")
        #expect(later.value(forHTTPHeaderField: "Accept") == "application/json, text/event-stream")
    }
}

// MARK: - OAuth

struct OAuthTests {
    @Test func pkceMatchesRFC7636Vector() {
        #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let verifier = PKCE.makeVerifier()
        #expect(verifier.count == 43)
        #expect(!verifier.contains("=") && !verifier.contains("+") && !verifier.contains("/"))
    }

    @Test func discoveryCandidates() {
        let server = URL(string: "https://mcp.example.com/v1/mcp")!
        #expect(OAuthURLs.protectedResourceMetadataCandidates(for: server).map(\.absoluteString) == [
            "https://mcp.example.com/.well-known/oauth-protected-resource/v1/mcp",
            "https://mcp.example.com/.well-known/oauth-protected-resource"
        ])
        #expect(OAuthURLs.authorizationServerMetadataCandidates(for: URL(string: "https://auth.example.com")!).map(\.absoluteString) == [
            "https://auth.example.com/.well-known/oauth-authorization-server",
            "https://auth.example.com/.well-known/openid-configuration"
        ])
        #expect(OAuthURLs.authorizationServerMetadataCandidates(for: URL(string: "https://auth.example.com/tenant")!).count == 3)
        #expect(OAuthURLs.canonicalResource(URL(string: "https://mcp.example.com/mcp?x=1#frag")!) == "https://mcp.example.com/mcp")
    }

    @Test func metadataParsing() {
        let server = AuthorizationServerMetadata(json: [
            "issuer": "https://auth.example.com",
            "authorization_endpoint": "https://auth.example.com/authorize",
            "token_endpoint": "https://auth.example.com/token",
            "registration_endpoint": "https://auth.example.com/register"
        ])
        #expect(server?.registrationEndpoint?.absoluteString == "https://auth.example.com/register")
        #expect(AuthorizationServerMetadata(json: ["issuer": "x"]) == nil)
        let resource = ProtectedResourceMetadata(json: ["resource": "https://mcp.example.com/mcp", "authorization_servers": ["https://auth.example.com"]])
        #expect(resource?.authorizationServers.first?.absoluteString == "https://auth.example.com")
        #expect(ProtectedResourceMetadata(json: ["resource": "x"]) == nil)
    }

    @Test func authorizationURLCarriesPKCEStateAndResource() throws {
        let metadata = AuthorizationServerMetadata(authorizationEndpoint: URL(string: "https://auth.example.com/authorize?prompt=consent")!,
                                                   tokenEndpoint: URL(string: "https://auth.example.com/token")!,
                                                   registrationEndpoint: nil)
        let url = try #require(OAuthURLs.authorizationURL(metadata: metadata, clientId: "client", redirectURI: "http://127.0.0.1:5000/callback",
                                                         codeChallenge: "abc", state: "xyz", resource: "https://mcp.example.com/mcp", scope: "read"))
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["prompt"] == "consent")
        #expect(items["response_type"] == "code")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["code_challenge"] == "abc")
        #expect(items["state"] == "xyz")
        #expect(items["resource"] == "https://mcp.example.com/mcp")
        #expect(items["redirect_uri"] == "http://127.0.0.1:5000/callback")
        #expect(items["scope"] == "read")
    }

    @Test func loopbackCallbackParsing() {
        #expect(OAuthURLs.callbackParameters(fromRequest: "GET /callback?code=c1&state=s1 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n") == ["code": "c1", "state": "s1"])
        #expect(OAuthURLs.callbackParameters(fromRequest: "GET /callback?error=access_denied HTTP/1.1\r\n\r\n")?["error"] == "access_denied")
        #expect(OAuthURLs.callbackParameters(fromRequest: "GET /favicon.ico HTTP/1.1\r\n\r\n") == nil)
        #expect(OAuthURLs.callbackParameters(fromRequest: "POST /callback HTTP/1.1\r\n\r\n") == nil)
    }

    @Test func formBodyIsPercentEncoded() {
        let body = String(data: OAuthURLs.formBody([("redirect_uri", "http://127.0.0.1:1/callback"), ("code", "a b+c")]), encoding: .utf8)
        #expect(body == "redirect_uri=http%3A%2F%2F127.0.0.1%3A1%2Fcallback&code=a%20b%2Bc")
    }
}

// MARK: - OpenAI audio

@MainActor
struct OpenAIAudioTests {
    @Test func transcriptionRequestIsMultipart() throws {
        let request = OpenAITranscriptionClient.transcriptionRequest(wav: Data([1, 2, 3]), model: "gpt-transcribe",
                                                                    language: "ru", prompt: "TinyAI", apiKey: "sk-test")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let contentType = try #require(request.value(forHTTPHeaderField: "Content-Type"))
        #expect(contentType.hasPrefix("multipart/form-data; boundary="))
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("name=\"model\"\r\n\r\ngpt-transcribe"))
        #expect(body.contains("name=\"language\"\r\n\r\nru"))
        #expect(body.contains("name=\"prompt\"\r\n\r\nTinyAI"))
        #expect(body.contains("filename=\"speech.wav\""))
        #expect(body.hasSuffix("--\r\n"))
    }

    @Test func realtimeSessionUpdateShape() throws {
        let update = OpenAIRealtimeTranscriber.sessionUpdate(model: "gpt-live-transcribe", language: "en", prompt: "")
        #expect(update["type"] as? String == "session.update")
        let session = try #require(update["session"] as? [String: Any])
        #expect(session["type"] as? String == "transcription")
        let input = try #require((session["audio"] as? [String: Any])?["input"] as? [String: Any])
        #expect((input["format"] as? [String: Any])?["rate"] as? Int == 24_000)
        #expect(input["turn_detection"] is NSNull)
        let transcription = try #require(input["transcription"] as? [String: Any])
        #expect(transcription["model"] as? String == "gpt-live-transcribe")
        #expect(transcription["languages"] as? [String] == ["en"])
        #expect(transcription["prompt"] == nil)
    }

    @Test func speechRequestSendsInstructionsOnlyToGPTVoices() {
        var config = VoiceOutputConfig()
        config.instructions = "Calm"
        #expect(json(SpeechPlayer.speechRequest(text: "hi", config: config, apiKey: "k").httpBody)["instructions"] as? String == "Calm")
        config.openAIModel = "tts-1"
        #expect(json(SpeechPlayer.speechRequest(text: "hi", config: config, apiKey: "k").httpBody)["instructions"] == nil)
    }

    @Test func speechTextIsCleanedAndChunked() {
        #expect(SpeechPlayer.speakableText("## Title\n- **Bold** [link](https://x.y)\n```code```") == "Title\nBold link")
        let long = String(repeating: "Sentence number one. ", count: 50)
        let chunks = SpeechPlayer.chunks(of: long, maximumLength: 100)
        #expect(chunks.count > 5)
        #expect(chunks.allSatisfy { $0.count <= 100 })
        #expect(SpeechPlayer.chunks(of: "short", maximumLength: 100) == ["short"])
    }
}

// MARK: - Live

@MainActor
struct LiveProtocolTests {
    @Test func sessionStartDelegatesToBackend() throws {
        var settings = LiveAgentSettings()
        settings.backendModel = "gpt-6-luna"
        settings.backendReasoning = "medium"
        settings.voice = "cedar"
        let start = LiveProtocol.sessionStart(settings: settings, tools: [["type": "web_search"]])
        #expect(start["type"] as? String == "session.start")
        let session = try #require(start["session"] as? [String: Any])
        #expect(session["model"] as? String == "gpt-live-1")
        let audio = try #require(session["audio"] as? [String: Any])
        #expect((audio["output"] as? [String: Any])?["voice"] as? String == "cedar")
        #expect((audio["format"] as? [String: Any])?["type"] as? String == "audio/pcm")
        let delegation = try #require(session["delegation"] as? [String: Any])
        #expect(delegation["type"] as? String == "responses")
        let responses = try #require(delegation["responses"] as? [String: Any])
        #expect(responses["model"] as? String == "gpt-6-luna")
        #expect((responses["reasoning"] as? [String: Any])?["effort"] as? String == "medium")
        #expect((responses["tools"] as? [[String: Any]])?.count == 1)
    }

    @Test func serverEventsAreParsed() {
        #expect(LiveProtocol.parse(#"{"type":"session.started"}"#) == .started)
        #expect(LiveProtocol.parse(#"{"type":"session.output_transcript.delta","delta":"Hi"}"#) == .outputTranscriptDelta("Hi"))
        #expect(LiveProtocol.parse(#"{"type":"session.output_audio.delta","delta":"AAE="}"#) == .outputAudio(Data([0, 1])))
        #expect(LiveProtocol.parse(#"{"type":"error","error":{"message":"bad"}}"#) == .error("bad"))
        let call = #"{"type":"response.event","delegation_id":"d","event":{"type":"response.output_item.done","item":{"type":"function_call","call_id":"call_1","name":"docs__search","arguments":"{\"q\":1}"}}}"#
        #expect(LiveProtocol.parse(call) == .functionCall(callId: "call_1", name: "docs__search", arguments: #"{"q":1}"#))
        #expect(LiveProtocol.parse(#"{"type":"response.event","event":{"type":"response.output_text.delta"}}"#) == .ignored("response.event"))
        #expect(LiveProtocol.parse(#"{"type":"session.input_speech.started"}"#) == .userStartedSpeaking)
        #expect(LiveProtocol.parse("not json") == nil)
    }

    @Test func toolOutputMessages() {
        let output = LiveProtocol.functionOutput(callId: "c", output: "done", eventId: "e1")
        #expect(output["type"] as? String == "response.item.create")
        #expect((output["item"] as? [String: Any])?["call_id"] as? String == "c")
        #expect(LiveProtocol.continueResponse(eventId: "e2")["type"] as? String == "response.create")
        #expect(LiveProtocol.inputAudio(Data([0, 1]))["audio"] as? String == "AAE=")
    }

    @Test func toolRegistryNamesAndRoutes() {
        var connection = AgentConnection()
        connection.kind = .mcp
        connection.name = "Company Docs"
        connection.cachedTools = [
            MCPToolSummary(name: "search", description: "", inputSchemaJSON: #"{"type":"object","properties":{"q":{"type":"string"}}}"#),
            MCPToolSummary(name: "search", description: "dupe", inputSchemaJSON: "not json")
        ]
        var agent = AgentProfile()
        agent.name = "Deep Research"
        var settings = LiveAgentSettings()
        settings.mcpConnectionIds = [connection.id]
        settings.agentIdsAsTools = [agent.id]
        settings.webSearch = true

        let registry = LiveToolRegistry(settings: settings, connections: [connection], agents: [agent])
        let names = registry.definitions.compactMap { $0["name"] as? String }
        #expect(names == ["Company_Docs__search", "Company_Docs__search_2", "ask_Deep_Research"])
        #expect(registry.routes["Company_Docs__search"] == .mcp(connectionId: connection.id, tool: "search"))
        #expect(registry.routes["ask_Deep_Research"] == .agent(agent.id))
        #expect(registry.definitions.last?["type"] as? String == "web_search")
        let fallbackSchema = registry.definitions[1]["parameters"] as? [String: Any]
        #expect(fallbackSchema?["type"] as? String == "object")
    }

    @Test func toolNamesAreSanitized() {
        #expect(LiveToolRegistry.sanitize("Поиск по базе").allSatisfy { $0 == "_" })
        #expect(LiveToolRegistry.sanitize("a.b/c d") == "a_b_c_d")
        #expect(LiveToolRegistry.sanitize(String(repeating: "x", count: 100)).count == 64)
        #expect(LiveToolRegistry.sanitize("") == "tool")
    }
}

// MARK: - Local engine (runs only when the model files are downloaded)

import AVFoundation

private func spokenSamples(_ text: String) throws -> [Float] {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tinyai-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    process.arguments = ["-v", "Samantha", "-o", url.path, "--data-format=LEF32@16000", text]
    try process.run()
    process.waitUntilExit()
    let file = try AVAudioFile(forReading: url)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let channel = try #require(buffer.floatChannelData?[0])
    return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
}

private func transcribeLocally(_ model: LocalTranscriptionModel, samples: [Float], unload: Bool = true) async throws -> (live: String, final: String) {
    let partials = PartialBox()
    let recording = LocalTranscriptionEngine.shared.begin(model: model, language: "en") { partials.set($0) }
    // Feed in microphone-sized chunks, like the audio tap does.
    var index = 0
    while index < samples.count {
        let end = min(index + 1600, samples.count)
        recording.feed(Array(samples[index..<end]))
        index = end
    }
    let final = try await recording.finish(allSamples: samples)
    if unload { LocalTranscriptionEngine.shared.unloadNow() }
    return (partials.get(), final)
}

private final class PartialBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ""
    func set(_ text: String) { lock.lock(); value = text; lock.unlock() }
    func get() -> String { lock.lock(); defer { lock.unlock() }; return value }
}

@Suite(.serialized)
struct LocalEngineTests {
    @Test(.enabled(if: LocalModelManager.isDownloaded(.canary180MFlash)))
    func canaryTranscribesSpeech() async throws {
        let samples = try spokenSamples("Hello world. This is a test of local transcription.")
        let result = try await transcribeLocally(.canary180MFlash, samples: samples)
        #expect(result.final.lowercased().contains("hello"))
        #expect(result.final.lowercased().contains("transcription"))
    }

    @Test(.enabled(if: LocalModelManager.isDownloaded(.nemotronStreaming35)))
    func nemotronStreamsSpeech() async throws {
        let samples = try spokenSamples("The quick brown fox jumps over the lazy dog.")
        let result = try await transcribeLocally(.nemotronStreaming35, samples: samples)
        #expect(result.final.lowercased().contains("fox"))
        #expect(result.final.lowercased().contains("lazy dog"))
        // Live text arrived while audio was still being fed.
        #expect(result.live.lowercased().contains("fox"))
    }

    @Test(.enabled(if: LocalModelManager.isDownloaded(.nemotronStreaming35) && LocalModelManager.isDownloaded(.canary180MFlash)),
          arguments: [LocalTranscriptionModel.nemotronStreaming35, .canary180MFlash])
    func consecutiveRecordingsReuseTheLoadedModel(_ model: LocalTranscriptionModel) async throws {
        let samples = try spokenSamples("The quick brown fox jumps over the lazy dog.")
        for _ in 0..<3 {
            let result = try await transcribeLocally(model, samples: samples, unload: false)
            #expect(result.final.lowercased().contains("fox"))
        }
        LocalTranscriptionEngine.shared.unloadNow()
    }

    @Test(.enabled(if: LocalModelManager.isDownloaded(.canary180MFlash)))
    func downloadedFileMatchesPinnedHash() {
        #expect(LocalModelManager.sha256(of: LocalModelManager.fileURL(for: .canary180MFlash)) == LocalTranscriptionModel.canary180MFlash.sha256)
    }
}

@MainActor
struct StatusHUDTests {
    @Test func popupSitsUnderTheIconAndStaysOnScreen() throws {
        let screen = try #require(NSScreen.main).visibleFrame
        let icon = NSRect(x: screen.midX, y: screen.maxY, width: 24, height: 24)
        let origin = StatusHUDController.origin(for: NSSize(width: 340, height: 80), below: icon)
        #expect(abs(origin.x + 170 - icon.midX) < 1)
        #expect(origin.y + 80 <= screen.maxY)
        let edge = NSRect(x: screen.maxX - 10, y: screen.maxY, width: 24, height: 24)
        #expect(StatusHUDController.origin(for: NSSize(width: 340, height: 80), below: edge).x + 340 <= screen.maxX)
    }
}
