import Foundation

// MARK: - Hotkeys

/// How a voice hotkey drives recording.  `holdOrToggle` follows Handy: a
/// press held longer than the threshold is push-to-talk, a short tap keeps
/// recording until the next press.
nonisolated enum HotkeyActivationMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case holdOrToggle
    case toggle
    case pushToTalk

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .holdOrToggle: return "Hold or tap"
        case .toggle: return "Tap to start/stop"
        case .pushToTalk: return "Hold to talk"
        }
    }
}

nonisolated struct VoiceHotkey: Codable, Equatable, Sendable {
    var keyCode: Int64
    var modifiers: Int
    var mode: HotkeyActivationMode

    init(keyCode: Int64, modifiers: ShortcutModifiers, mode: HotkeyActivationMode = .holdOrToggle) {
        self.keyCode = keyCode
        self.modifiers = modifiers.rawValue
        self.mode = mode
    }

    init(shortcut: KeyboardShortcut, mode: HotkeyActivationMode) {
        self.init(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers, mode: mode)
    }

    var shortcut: KeyboardShortcut {
        KeyboardShortcut(keyCode: keyCode, modifiers: ShortcutModifiers(rawValue: modifiers))
    }

    var displayString: String { shortcut.displayString }
}

// MARK: - Transcription

nonisolated enum TranscriptionEngineKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case local
    case openAI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local: return "Local model"
        case .openAI: return "OpenAI"
        }
    }
}

/// The three local models TinyAI ships, all run by transcribe.cpp from the
/// same GGUF files Handy uses.  Revisions and hashes are pinned to Handy's
/// catalog so a download is verified before it is used.
nonisolated enum LocalTranscriptionModel: String, Codable, CaseIterable, Identifiable, Sendable {
    case voxtralMini4BRealtime
    case nemotronStreaming35
    case canary180MFlash

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .voxtralMini4BRealtime: return "Voxtral Mini 4B Realtime"
        case .nemotronStreaming35: return "Nemotron Streaming 3.5"
        case .canary180MFlash: return "Canary 180M Flash"
        }
    }

    var useCase: String {
        switch self {
        case .voxtralMini4BRealtime:
            return "High-quality live transcription in 13 languages."
        case .nemotronStreaming35:
            return "Fast live dictation in 28 languages."
        case .canary180MFlash:
            return "Small offline model; transcribes when you stop recording."
        }
    }

    /// Widely spoken examples from the languages available in TinyAI. Canary
    /// supports only four languages, so its complete list is shown instead.
    var featuredLanguages: String {
        switch self {
        case .voxtralMini4BRealtime, .nemotronStreaming35:
            return "English, Mandarin, Hindi, Spanish, Arabic"
        case .canary180MFlash:
            return "English, Spanish, French, German (all 4)"
        }
    }

    /// The GGUF file holds the model weights. Runtime buffers and the app use
    /// additional memory, so this is a rough baseline, not peak RAM.
    var memoryDescription: String {
        "RAM estimate: ~\(formattedSize) for weights + extra runtime memory."
    }

    var modelCardURL: URL {
        URL(string: "https://huggingface.co/\(repository)")!
    }

    var repository: String {
        switch self {
        case .voxtralMini4BRealtime: return "handy-computer/Voxtral-Mini-4B-Realtime-2602-gguf"
        case .nemotronStreaming35: return "handy-computer/nemotron-3.5-asr-streaming-0.6b-gguf"
        case .canary180MFlash: return "handy-computer/canary-180m-flash-gguf"
        }
    }

    var revision: String {
        switch self {
        case .voxtralMini4BRealtime: return "b3e1c979e3775cbd0a49a65878a0ec7f06789ed7"
        case .nemotronStreaming35: return "6d44e540bc31b0de1dbe174a3cea87f53a7f22fb"
        case .canary180MFlash: return "b147f9dc52b59f0998e410540a84727bd86457fd"
        }
    }

    var filename: String {
        switch self {
        case .voxtralMini4BRealtime: return "Voxtral-Mini-4B-Realtime-2602-Q4_K_M.gguf"
        case .nemotronStreaming35: return "nemotron-3.5-asr-streaming-0.6b-Q8_0.gguf"
        case .canary180MFlash: return "canary-180m-flash-Q8_0.gguf"
        }
    }

    var sha256: String {
        switch self {
        case .voxtralMini4BRealtime: return "39dc1f65539373a406edea7490505822d77c12edff521744678717eef4da4723"
        case .nemotronStreaming35: return "b94545b313b3223fda7b2857a52681da813935c2127643d1e9ff0c23d988089c"
        case .canary180MFlash: return "e13c7f5d0952b056a027cfffec13e3a3a134d1608babed24f983568f141e297c"
        }
    }

    var sizeBytes: Int64 {
        switch self {
        case .voxtralMini4BRealtime: return 2_830_493_984
        case .nemotronStreaming35: return 751_094_240
        case .canary180MFlash: return 218_447_552
        }
    }

    var languages: [String] {
        switch self {
        case .voxtralMini4BRealtime:
            return ["en", "fr", "es", "de", "ru", "zh", "ja", "it", "pt", "nl", "ar", "hi", "ko"]
        case .nemotronStreaming35:
            return ["en", "es", "fr", "it", "pt", "nl", "de", "tr", "ru", "ar", "hi", "ja", "ko", "vi",
                    "uk", "pl", "sv", "cs", "nb", "da", "bg", "fi", "hr", "sk", "zh", "hu", "ro", "et"]
        case .canary180MFlash:
            return ["en", "de", "es", "fr"]
        }
    }

    var supportsStreaming: Bool {
        self != .canary180MFlash
    }

    var downloadURLs: [URL] {
        let path = "\(repository)/resolve/\(revision)/\(filename)"
        let mirror = "\(repository)/\(revision)/\(filename)"
        return [
            URL(string: "https://huggingface.co/\(path)")!,
            URL(string: "https://blob.handy.computer/\(mirror)")!
        ]
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

nonisolated enum OpenAITranscriptionMode: String, Codable, Sendable {
    /// Upload the finished recording.
    case file
    /// Stream audio over a realtime transcription session for live text.
    case realtime
}

nonisolated struct OpenAITranscriptionModel: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let mode: OpenAITranscriptionMode
    let summary: String

    static let all: [OpenAITranscriptionModel] = [
        OpenAITranscriptionModel(id: "gpt-live-transcribe", displayName: "GPT Live Transcribe", mode: .realtime,
                                 summary: "Live text while you speak · OpenAI list price $0.017/min (~$1.02/hour of audio)."),
        OpenAITranscriptionModel(id: "gpt-transcribe", displayName: "GPT Transcribe", mode: .file,
                                 summary: "Transcribes after you stop · OpenAI list price $0.0045/min (~$0.27/hour of audio).")
    ]

    static let defaultModel = all[0]

    static func resolve(_ id: String) -> OpenAITranscriptionModel {
        all.first { $0.id == id } ?? defaultModel
    }
}

nonisolated enum VoiceOnboarding {
    static let nemotronPromptedKey = "VoiceNemotronOnboardingPromptedV1"

    static func shouldOfferNemotron(hasOpenAIKey: Bool, hasDownloadedModel: Bool, alreadyPrompted: Bool) -> Bool {
        !hasOpenAIKey && !hasDownloadedModel && !alreadyPrompted
    }
}

nonisolated struct TranscriptionLanguage: Identifiable, Hashable, Sendable {
    let code: String
    let name: String
    var id: String { code }

    static let all: [TranscriptionLanguage] = [
        TranscriptionLanguage(code: "", name: "Auto-detect"),
        TranscriptionLanguage(code: "en", name: "English"),
        TranscriptionLanguage(code: "ru", name: "Russian"),
        TranscriptionLanguage(code: "uk", name: "Ukrainian"),
        TranscriptionLanguage(code: "de", name: "German"),
        TranscriptionLanguage(code: "es", name: "Spanish"),
        TranscriptionLanguage(code: "fr", name: "French"),
        TranscriptionLanguage(code: "it", name: "Italian"),
        TranscriptionLanguage(code: "pt", name: "Portuguese"),
        TranscriptionLanguage(code: "pl", name: "Polish"),
        TranscriptionLanguage(code: "nl", name: "Dutch"),
        TranscriptionLanguage(code: "tr", name: "Turkish"),
        TranscriptionLanguage(code: "zh", name: "Chinese"),
        TranscriptionLanguage(code: "ja", name: "Japanese"),
        TranscriptionLanguage(code: "ko", name: "Korean")
    ]
}

nonisolated struct TranscriptionSettings: Codable, Equatable, Sendable {
    var engine: TranscriptionEngineKind = .openAI
    var localModel: LocalTranscriptionModel = .nemotronStreaming35
    var openAIModel: String = OpenAITranscriptionModel.defaultModel.id
    /// Language code, empty for auto-detect.
    var language: String = ""
    /// Names and terms that help the recogniser (OpenAI prompt).
    var vocabulary: String = ""
    var dictationHotkey: VoiceHotkey? = VoiceHotkey(shortcut: .modifierOnly([.function, .control]), mode: .holdOrToggle) // fn⌃
    var restoreClipboard: Bool = true
    var soundFeedback: Bool = true

    init() {}

    init(from decoder: Decoder) throws {
        let defaults = TranscriptionSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        engine = (try? c.decode(TranscriptionEngineKind.self, forKey: .engine)) ?? defaults.engine
        localModel = (try? c.decode(LocalTranscriptionModel.self, forKey: .localModel)) ?? defaults.localModel
        openAIModel = (try? c.decode(String.self, forKey: .openAIModel)) ?? defaults.openAIModel
        language = (try? c.decode(String.self, forKey: .language)) ?? defaults.language
        vocabulary = (try? c.decode(String.self, forKey: .vocabulary)) ?? defaults.vocabulary
        dictationHotkey = c.contains(.dictationHotkey)
            ? (try? c.decodeIfPresent(VoiceHotkey.self, forKey: .dictationHotkey)) ?? nil
            : defaults.dictationHotkey
        restoreClipboard = (try? c.decode(Bool.self, forKey: .restoreClipboard)) ?? defaults.restoreClipboard
        soundFeedback = (try? c.decode(Bool.self, forKey: .soundFeedback)) ?? defaults.soundFeedback
    }

    /// A cleared shortcut is written as `null` so decoding keeps it cleared
    /// instead of restoring the default for a missing key.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(engine, forKey: .engine)
        try c.encode(localModel, forKey: .localModel)
        try c.encode(openAIModel, forKey: .openAIModel)
        try c.encode(language, forKey: .language)
        try c.encode(vocabulary, forKey: .vocabulary)
        try c.encode(dictationHotkey, forKey: .dictationHotkey)
        try c.encode(restoreClipboard, forKey: .restoreClipboard)
        try c.encode(soundFeedback, forKey: .soundFeedback)
    }

    enum CodingKeys: String, CodingKey {
        case engine, localModel, openAIModel, language, vocabulary, dictationHotkey, restoreClipboard, soundFeedback
    }
}

// MARK: - Connections

nonisolated enum AgentConnectionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case http
    case mcp

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .http: return "HTTP API"
        case .mcp: return "MCP server"
        }
    }
}

nonisolated enum ConnectionAuthKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    /// A secret header value stored in the Keychain, e.g. `Authorization: Bearer …`.
    case header
    /// OAuth 2.1 sign-in in the default browser (MCP authorization spec).
    case oauth

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .header: return "Header"
        case .oauth: return "Browser sign-in (OAuth)"
        }
    }
}

nonisolated struct HTTPHeaderField: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String = ""
    var value: String = ""
}

nonisolated struct MCPToolSummary: Codable, Equatable, Identifiable, Sendable {
    var name: String
    var description: String
    /// The tool's JSON Schema for its arguments, kept as JSON text.
    var inputSchemaJSON: String

    var id: String { name }
}

/// A remote endpoint that agent profiles and the live session talk to.
nonisolated struct AgentConnection: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String = "New connection"
    var kind: AgentConnectionKind = .http
    var url: String = ""
    var auth: ConnectionAuthKind = .none
    var authHeaderName: String = "Authorization"

    // HTTP
    var method: String = "POST"
    var headers: [HTTPHeaderField] = []
    var bodyTemplate: String = HTTPAgentTemplate.defaultBody
    /// Dot path to the answer in a JSON response, e.g. `output.0.text`.
    var responseTextPath: String = "text"
    var timeoutSeconds: Double = 300

    // MCP
    var cachedTools: [MCPToolSummary] = []

    init() {}

    init(from decoder: Decoder) throws {
        let d = AgentConnection()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? d.id
        name = (try? c.decode(String.self, forKey: .name)) ?? d.name
        kind = (try? c.decode(AgentConnectionKind.self, forKey: .kind)) ?? d.kind
        url = (try? c.decode(String.self, forKey: .url)) ?? d.url
        auth = (try? c.decode(ConnectionAuthKind.self, forKey: .auth)) ?? d.auth
        authHeaderName = (try? c.decode(String.self, forKey: .authHeaderName)) ?? d.authHeaderName
        method = (try? c.decode(String.self, forKey: .method)) ?? d.method
        headers = (try? c.decode([HTTPHeaderField].self, forKey: .headers)) ?? d.headers
        bodyTemplate = (try? c.decode(String.self, forKey: .bodyTemplate)) ?? d.bodyTemplate
        responseTextPath = (try? c.decode(String.self, forKey: .responseTextPath)) ?? d.responseTextPath
        timeoutSeconds = (try? c.decode(Double.self, forKey: .timeoutSeconds)) ?? d.timeoutSeconds
        cachedTools = (try? c.decode([MCPToolSummary].self, forKey: .cachedTools)) ?? d.cachedTools
    }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, url, auth, authHeaderName, method, headers, bodyTemplate, responseTextPath,
             timeoutSeconds, cachedTools
    }

    var headerSecretAccount: String { "AuthHeader.\(id.uuidString)" }
    var oauthAccount: String { "OAuth.\(id.uuidString)" }
}

// MARK: - Speech output

nonisolated enum SpeechEngineKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    case openAI
    case system

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .openAI: return "OpenAI voice"
        case .system: return "macOS voice"
        }
    }
}

nonisolated struct VoiceOutputConfig: Codable, Equatable, Sendable {
    var engine: SpeechEngineKind = .off
    var openAIModel: String = "gpt-4o-mini-tts"
    var openAIVoice: String = "marin"
    /// Tone and style for `gpt-4o-mini-tts`.
    var instructions: String = ""
    var speed: Double = 1.0
    var systemVoiceIdentifier: String = ""

    static let openAIVoices = ["marin", "cedar", "alloy", "ash", "ballad", "coral", "echo", "fable",
                               "nova", "onyx", "sage", "shimmer", "verse"]
    static let openAIModels = ["gpt-4o-mini-tts", "tts-1-hd", "tts-1"]

    init() {}

    init(from decoder: Decoder) throws {
        let d = VoiceOutputConfig()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        engine = (try? c.decode(SpeechEngineKind.self, forKey: .engine)) ?? d.engine
        openAIModel = (try? c.decode(String.self, forKey: .openAIModel)) ?? d.openAIModel
        openAIVoice = (try? c.decode(String.self, forKey: .openAIVoice)) ?? d.openAIVoice
        instructions = (try? c.decode(String.self, forKey: .instructions)) ?? d.instructions
        speed = (try? c.decode(Double.self, forKey: .speed)) ?? d.speed
        systemVoiceIdentifier = (try? c.decode(String.self, forKey: .systemVoiceIdentifier)) ?? d.systemVoiceIdentifier
    }

    enum CodingKeys: String, CodingKey {
        case engine, openAIModel, openAIVoice, instructions, speed, systemVoiceIdentifier
    }
}

// MARK: - Agent profiles

/// One voice shortcut: speak, send the transcript to a connection, then show
/// and/or speak the answer.
nonisolated struct AgentProfile: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String = "New agent"
    /// Shown to the live model when the agent is exposed as a tool.
    var summary: String = ""
    var hotkey: VoiceHotkey?
    var connectionId: UUID?
    /// MCP connections only: the tool to call.
    var mcpToolName: String = ""
    /// MCP connections only: JSON arguments with `{{transcript}}` placeholders.
    var argumentsTemplate: String = #"{"query": "{{transcript}}"}"#
    var showPanel: Bool = true
    var pasteAtCursor: Bool = false
    var copyToClipboard: Bool = false
    var speech = VoiceOutputConfig()
    /// Replies within this many minutes reuse the same `{{sessionId}}`.
    var sessionIdleMinutes: Int = 15

    init() {}

    init(from decoder: Decoder) throws {
        let d = AgentProfile()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? d.id
        name = (try? c.decode(String.self, forKey: .name)) ?? d.name
        summary = (try? c.decode(String.self, forKey: .summary)) ?? d.summary
        hotkey = (try? c.decodeIfPresent(VoiceHotkey.self, forKey: .hotkey)) ?? nil
        connectionId = (try? c.decodeIfPresent(UUID.self, forKey: .connectionId)) ?? nil
        mcpToolName = (try? c.decode(String.self, forKey: .mcpToolName)) ?? d.mcpToolName
        argumentsTemplate = (try? c.decode(String.self, forKey: .argumentsTemplate)) ?? d.argumentsTemplate
        showPanel = (try? c.decode(Bool.self, forKey: .showPanel)) ?? d.showPanel
        pasteAtCursor = (try? c.decode(Bool.self, forKey: .pasteAtCursor)) ?? d.pasteAtCursor
        copyToClipboard = (try? c.decode(Bool.self, forKey: .copyToClipboard)) ?? d.copyToClipboard
        speech = (try? c.decode(VoiceOutputConfig.self, forKey: .speech)) ?? d.speech
        sessionIdleMinutes = (try? c.decode(Int.self, forKey: .sessionIdleMinutes)) ?? d.sessionIdleMinutes
    }

    enum CodingKeys: String, CodingKey {
        case id, name, summary, hotkey, connectionId, mcpToolName, argumentsTemplate, showPanel, pasteAtCursor,
             copyToClipboard, speech, sessionIdleMinutes
    }
}

// MARK: - Live conversation

nonisolated struct LiveAgentSettings: Codable, Equatable, Sendable {
    var hotkey: VoiceHotkey?
    var model: String = "gpt-live-1"
    var voice: String = "marin"
    var instructions: String = LiveAgentSettings.defaultInstructions
    /// OpenAI model from `ModelCatalog` that reasons and calls tools.
    var backendModel: String = "gpt-6-luna"
    var backendReasoning: String = "low"
    var backendInstructions: String = ""
    var mcpConnectionIds: [UUID] = []
    var agentIdsAsTools: [UUID] = []
    var webSearch: Bool = true
    var showTranscriptPanel: Bool = true

    static let voices = ["marin", "cedar", "quartz", "ripple", "vesper", "willow", "stone", "gleam",
                         "meridian", "bossa", "tempo", "beacon", "delta", "cinder"]

    static let defaultInstructions = """
    You are a concise voice assistant. Keep spoken answers short. Delegate anything that needs \
    current information, tools, or careful reasoning to the backend.
    """

    init() {}

    init(from decoder: Decoder) throws {
        let d = LiveAgentSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hotkey = (try? c.decodeIfPresent(VoiceHotkey.self, forKey: .hotkey)) ?? nil
        model = (try? c.decode(String.self, forKey: .model)) ?? d.model
        voice = (try? c.decode(String.self, forKey: .voice)) ?? d.voice
        instructions = (try? c.decode(String.self, forKey: .instructions)) ?? d.instructions
        backendModel = (try? c.decode(String.self, forKey: .backendModel)) ?? d.backendModel
        backendReasoning = (try? c.decode(String.self, forKey: .backendReasoning)) ?? d.backendReasoning
        backendInstructions = (try? c.decode(String.self, forKey: .backendInstructions)) ?? d.backendInstructions
        mcpConnectionIds = (try? c.decode([UUID].self, forKey: .mcpConnectionIds)) ?? d.mcpConnectionIds
        agentIdsAsTools = (try? c.decode([UUID].self, forKey: .agentIdsAsTools)) ?? d.agentIdsAsTools
        webSearch = (try? c.decode(Bool.self, forKey: .webSearch)) ?? d.webSearch
        showTranscriptPanel = (try? c.decode(Bool.self, forKey: .showTranscriptPanel)) ?? d.showTranscriptPanel
    }

    enum CodingKeys: String, CodingKey {
        case hotkey, model, voice, instructions, backendModel, backendReasoning, backendInstructions,
             mcpConnectionIds, agentIdsAsTools, webSearch, showTranscriptPanel
    }
}

/// Everything the voice features persist, as one value for the Settings draft.
nonisolated struct VoiceConfiguration: Equatable, Sendable {
    var transcription = TranscriptionSettings()
    var connections: [AgentConnection] = []
    var agents: [AgentProfile] = []
    var live = LiveAgentSettings()
}
