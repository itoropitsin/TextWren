import AppKit
import Combine
import Foundation
import os

/// Decides when a voice hotkey starts and stops recording.  `holdOrToggle`
/// follows Handy: holding the key past the threshold records until release,
/// a short tap records until the next press.
nonisolated struct HotkeyPressInterpreter: Sendable {
    enum Action: Equatable {
        case start
        case stop
        case none
    }

    let mode: HotkeyActivationMode
    var holdThreshold: TimeInterval = 0.3
    private(set) var isActive = false
    private var pressedAt: Date?

    init(mode: HotkeyActivationMode, holdThreshold: TimeInterval = 0.3) {
        self.mode = mode
        self.holdThreshold = holdThreshold
    }

    mutating func keyDown(at time: Date = Date()) -> Action {
        switch mode {
        case .pushToTalk:
            guard !isActive else { return .none }
            isActive = true
            return .start
        case .toggle:
            isActive.toggle()
            return isActive ? .start : .stop
        case .holdOrToggle:
            if isActive {
                isActive = false
                pressedAt = nil
                return .stop
            }
            isActive = true
            pressedAt = time
            return .start
        }
    }

    mutating func keyUp(at time: Date = Date()) -> Action {
        switch mode {
        case .pushToTalk:
            guard isActive else { return .none }
            isActive = false
            return .stop
        case .toggle:
            return .none
        case .holdOrToggle:
            guard isActive, let pressedAt else { return .none }
            self.pressedAt = nil
            if time.timeIntervalSince(pressedAt) >= holdThreshold {
                isActive = false
                return .stop
            }
            return .none
        }
    }
}

enum VoiceTrigger: Equatable {
    case dictation
    case agent(UUID)

    static let dictationHotkeyId = "dictation"
    static let liveHotkeyId = "live"

    var hotkeyId: String {
        switch self {
        case .dictation: return Self.dictationHotkeyId
        case .agent(let id): return "agent.\(id.uuidString)"
        }
    }

    init?(hotkeyId: String) {
        if hotkeyId == Self.dictationHotkeyId {
            self = .dictation
        } else if hotkeyId.hasPrefix("agent."), let id = UUID(uuidString: String(hotkeyId.dropFirst(6))) {
            self = .agent(id)
        } else {
            return nil
        }
    }
}

enum VoiceState: Equatable {
    case idle
    case recording(VoiceTrigger)
    case transcribing
    case thinking(String)
    case speaking
    case live(LiveAgentSession.Phase)
    case error(String)

    var isBusy: Bool {
        switch self {
        case .idle, .error: return false
        default: return true
        }
    }
}

/// What the response panel shows.
struct AgentResponseContent: Equatable {
    var agentId: UUID?
    var title: String
    var question: String
    var answer: String
    var isError: Bool
}

/// Runs every voice flow: dictation, asking agents, and live conversation.
final class VoiceCoordinator: ObservableObject {
    @Published private(set) var state: VoiceState = .idle
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var partialTranscript = ""
    @Published private(set) var lastTranscript = ""
    @Published private(set) var response: AgentResponseContent?
    @Published private(set) var liveTurns: [LiveAgentSession.Turn] = []
    @Published private(set) var isSpeakingResponse = false
    /// A transcript shown in the menu bar popup because no text field had
    /// focus (or pasting failed).
    @Published private(set) var unplacedTranscript: String?
    /// The five latest transcripts, newest first.
    @Published private(set) var recentTranscripts: [String] = []
    static let recentTranscriptsKey = "RecentTranscriptsV1"
    static let recentTranscriptsLimit = 5

    let store: VoiceSettingsStore
    let modelManager: LocalModelManager
    let dispatcher: AgentDispatcher
    private let speech = SpeechPlayer()

    weak var keyboardMonitor: KeyboardMonitor? {
        didSet { applyHotkeys() }
    }
    /// The OpenAI key from Settings → API.
    var openAIKeyProvider: () -> String = {
        if case .value(let key) = KeychainStore.client.readString(service: "IT.TinyAI", account: LLMProvider.openAI.keychainAccount, allowInteraction: false) {
            return key
        }
        return ""
    }
    var onShowPanel: (() -> Void)?
    var onHidePanel: (() -> Void)?

    private var interpreter: HotkeyPressInterpreter?
    private var capture: AudioCapture?
    private var localRecording: LocalTranscriptionRecording?
    private var realtime: OpenAIRealtimeTranscriber?
    private var insertionTarget: TextReplacementTarget?
    private var focusIsTextField = true
    private var workTask: Task<Void, Never>?
    private var levelTimer: Timer?
    private var errorResetWork: DispatchWorkItem?
    private var liveSession: LiveAgentSession?
    private var cancellables: Set<AnyCancellable> = []
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TinyAI", category: "Voice")

    init(store: VoiceSettingsStore, modelManager: LocalModelManager) {
        self.store = store
        self.modelManager = modelManager
        self.dispatcher = AgentDispatcher(store: store)
        store.$configuration
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyHotkeys() }
            .store(in: &cancellables)
        store.$agentsBetaEnabled
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.applyHotkeys() }
            }
            .store(in: &cancellables)
        recentTranscripts = TinyAIRuntime.userDefaults.stringArray(forKey: Self.recentTranscriptsKey) ?? []
        prewarmMicrophone()
    }

    private func remember(_ transcript: String) {
        var recent = recentTranscripts.filter { $0 != transcript }
        recent.insert(transcript, at: 0)
        recentTranscripts = Array(recent.prefix(Self.recentTranscriptsLimit))
        TinyAIRuntime.userDefaults.set(recentTranscripts, forKey: Self.recentTranscriptsKey)
    }

    func dismissUnplacedTranscript() {
        unplacedTranscript = nil
    }

    /// Reused capture per sample rate: a fresh audio engine takes close to a
    /// second to start, which would cut off the first words.
    private var captures: [Double: AudioCapture] = [:]

    private func capture(sampleRate: Double) -> AudioCapture {
        if let existing = captures[sampleRate] { return existing }
        let created = AudioCapture(sampleRate: sampleRate)
        captures[sampleRate] = created
        return created
    }

    func prewarmMicrophone() {
        guard MicrophonePermission.isGranted, !TinyAIRuntime.isTestEnvironment else { return }
        let rate: Double = store.transcription.engine == .openAI
            && OpenAITranscriptionModel.resolve(store.transcription.openAIModel).mode == .realtime
            ? Double(OpenAIRealtimeTranscriber.sampleRate) : 16_000
        capture(sampleRate: rate).prewarm()
        if store.transcription.engine == .local, LocalModelManager.isDownloaded(store.transcription.localModel) {
            LocalTranscriptionEngine.shared.preload(store.transcription.localModel)
        }
    }

    // MARK: Hotkeys

    func applyHotkeys() {
        guard let keyboardMonitor else { return }
        var registrations: [VoiceHotkeyRegistration] = []
        if let hotkey = store.transcription.dictationHotkey {
            registrations.append(VoiceHotkeyRegistration(id: VoiceTrigger.dictationHotkeyId, shortcut: hotkey.shortcut))
        }
        for agent in store.agents where store.agentsBetaEnabled {
            if let hotkey = agent.hotkey {
                registrations.append(VoiceHotkeyRegistration(id: VoiceTrigger.agent(agent.id).hotkeyId, shortcut: hotkey.shortcut))
            }
        }
        if store.agentsBetaEnabled, let hotkey = store.live.hotkey {
            registrations.append(VoiceHotkeyRegistration(id: VoiceTrigger.liveHotkeyId, shortcut: hotkey.shortcut))
        }
        logger.notice("Voice hotkeys: \(registrations.map { "\($0.id)=\($0.shortcut.displayString)" }.joined(separator: ", "), privacy: .public)")
        keyboardMonitor.setVoiceHotkeys(registrations)
    }

    func handleHotkey(id: String, edge: VoiceHotkeyEdge) {
        logger.notice("Hotkey \(id, privacy: .public) \(edge == .down ? "down" : "up", privacy: .public) in state \(String(describing: self.state), privacy: .public)")
        if id == VoiceTrigger.liveHotkeyId {
            if edge == .down { toggleLive() }
            return
        }
        guard let trigger = VoiceTrigger(hotkeyId: id) else { return }

        switch state {
        case .recording(let active) where active == trigger:
            let action = edge == .down ? interpreter?.keyDown() : interpreter?.keyUp()
            if action == .stop { stopRecording() }
        case .idle, .error, .speaking:
            guard edge == .down else { return }
            speech.stop()
            startRecording(trigger)
        default:
            if edge == .down { NSSound.beep() }
        }
    }

    /// Start or stop a recording from the menu (toggle behaviour).
    func toggleFromMenu(_ trigger: VoiceTrigger) {
        if case .recording(let active) = state, active == trigger {
            stopRecording()
        } else if !state.isBusy || state == .speaking {
            speech.stop()
            startRecording(trigger, mode: .toggle)
        }
    }

    // MARK: Recording

    private func hotkey(for trigger: VoiceTrigger) -> VoiceHotkey? {
        switch trigger {
        case .dictation: return store.transcription.dictationHotkey
        case .agent(let id): return store.agent(id: id)?.hotkey
        }
    }

    private func startRecording(_ trigger: VoiceTrigger, mode: HotkeyActivationMode? = nil) {
        guard MicrophonePermission.isGranted else {
            if MicrophonePermission.isUndetermined {
                MicrophonePermission.request { [weak self] granted in
                    guard let self else { return }
                    if granted {
                        self.prewarmMicrophone()
                        self.fail(VoiceServiceError.invalidResponse("Microphone access granted. Press the shortcut again to record."))
                    } else {
                        self.fail(AudioCaptureError.microphoneDenied)
                    }
                }
            } else {
                fail(AudioCaptureError.microphoneDenied)
            }
            return
        }
        if case .agent(let id) = trigger, store.agent(id: id) == nil { return }

        let settings = store.transcription
        var interpreter = HotkeyPressInterpreter(mode: mode ?? hotkey(for: trigger)?.mode ?? .holdOrToggle)
        _ = interpreter.keyDown()
        self.interpreter = interpreter
        partialTranscript = ""

        let sampleRate: Double
        let feed: AudioCapture.SampleHandler
        switch settings.engine {
        case .local:
            guard LocalModelManager.isDownloaded(settings.localModel) else {
                fail(LocalTranscriptionError.modelMissing(settings.localModel.displayName))
                return
            }
            sampleRate = Double(LocalTranscriptionEngine.sampleRate)
            let recording = LocalTranscriptionEngine.shared.begin(model: settings.localModel, language: settings.language) { [weak self] text in
                DispatchQueue.main.async { self?.partialTranscript = text }
            }
            localRecording = recording
            feed = { samples in recording.feed(samples) }
        case .openAI:
            let apiKey = openAIKeyProvider()
            guard !apiKey.isEmpty else {
                fail(VoiceServiceError.missingOpenAIKey)
                return
            }
            let model = OpenAITranscriptionModel.resolve(settings.openAIModel)
            if model.mode == .realtime {
                sampleRate = Double(OpenAIRealtimeTranscriber.sampleRate)
                let transcriber = OpenAIRealtimeTranscriber(
                    apiKey: apiKey, model: model.id, language: settings.language, prompt: settings.vocabulary
                ) { [weak self] text in
                    self?.partialTranscript = text
                }
                realtime = transcriber
                feed = { [weak transcriber] samples in
                    DispatchQueue.main.async { transcriber?.append(samples) }
                }
            } else {
                sampleRate = 16_000
                feed = { _ in }
            }
        }

        let capture = self.capture(sampleRate: sampleRate)
        do {
            try capture.start(onSamples: feed)
        } catch {
            cleanUpRecording()
            fail(error)
            return
        }
        self.capture = capture
        // Asked only after the microphone runs: Accessibility calls to a busy
        // app can take up to half a second and would cut off the first words.
        let focus = Self.focusedTarget()
        insertionTarget = focus.target
        focusIsTextField = focus.isTextField
        unplacedTranscript = nil
        keyboardMonitor?.setVoiceSessionActive(true)
        state = .recording(trigger)
        logger.notice("Recording started at \(Int(sampleRate)) Hz")
        playSound("Tink")
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self, let capture = self.capture else { return }
            self.inputLevel = capture.currentLevel
            if capture.recordedDuration >= AudioCapture.maximumDuration - 0.1 {
                self.stopRecording()
            }
        }
    }

    private func stopRecording() {
        guard case .recording(let trigger) = state, let capture else { return }
        let samples = capture.stop()
        let sampleRate = Int(capture.sampleRate)
        levelTimer?.invalidate()
        levelTimer = nil
        inputLevel = 0
        interpreter = nil
        playSound("Pop")

        // Very short presses are accidental; drop them quietly.
        if Double(samples.count) / Double(sampleRate) < 0.25 {
            cancel()
            return
        }

        state = .transcribing
        logger.notice("Transcribing \(samples.count) samples, level \(AudioCoding.rmsLevel(samples), privacy: .public)")
        let settings = store.transcription
        let localRecording = self.localRecording
        let realtime = self.realtime
        let apiKey = openAIKeyProvider()
        workTask = Task { [weak self] in
            guard let self else { return }
            do {
                let text: String
                if let localRecording {
                    text = try await localRecording.finish(allSamples: samples)
                } else if let realtime {
                    text = try await realtime.finish()
                } else {
                    text = try await OpenAITranscriptionClient.transcribe(
                        samples: samples, sampleRate: sampleRate,
                        model: OpenAITranscriptionModel.resolve(settings.openAIModel).id,
                        language: settings.language, prompt: settings.vocabulary, apiKey: apiKey
                    )
                }
                try Task.checkCancellation()
                let transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !transcript.isEmpty else { throw VoiceServiceError.emptyTranscript }
                self.lastTranscript = transcript
                self.remember(transcript)
                self.logger.notice("Transcript: \(transcript.count) characters")
                self.partialTranscript = ""
                self.localRecording = nil
                self.realtime = nil
                switch trigger {
                case .dictation:
                    self.insertDictation(transcript, restoreClipboard: settings.restoreClipboard)
                case .agent(let id):
                    await self.ask(agentId: id, transcript: transcript)
                }
            } catch is CancellationError {
                return
            } catch {
                self.localRecording = nil
                self.realtime = nil
                self.fail(error)
            }
        }
    }

    /// The focused control, when it belongs to the frontmost app. Some apps
    /// report an element owned by a helper process; pasting then goes to the
    /// frontmost app instead of being refused.
    static func focusedTarget() -> (target: TextReplacementTarget?, isTextField: Bool) {
        guard let element = AccessibilityElements.focusedElement() else { return (nil, true) }
        let isTextField = AccessibilityElements.isEditableText(element)
        guard let target = AccessibilityElements.replacementTarget(for: element),
              target.processIdentifier == NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return (nil, isTextField)
        }
        return (target, isTextField)
    }

    private func insertDictation(_ text: String, restoreClipboard: Bool) {
        guard focusIsTextField else {
            // Nothing to type into: show the text in the menu bar popup.
            unplacedTranscript = text
            finishSession()
            return
        }
        let payload = RichTextPayload(plain: text, html: nil, rtf: nil)
        TextInserter.insert(payload, into: insertionTarget, restoreClipboard: restoreClipboard) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.finishSession()
            case .failure:
                // The text field lost focus: show the text instead.
                self.unplacedTranscript = text
                self.finishSession()
            }
        }
    }

    // MARK: Agents

    private func ask(agentId: UUID, transcript: String) async {
        guard let profile = store.agent(id: agentId) else {
            finishSession()
            return
        }
        state = .thinking(profile.name)
        response = AgentResponseContent(agentId: profile.id, title: profile.name, question: transcript, answer: "", isError: false)
        if profile.showPanel { onShowPanel?() }
        do {
            let answer = try await dispatcher.send(profile: profile, transcript: transcript, language: store.transcription.language)
            try Task.checkCancellation()
            deliver(answer, profile: profile, question: transcript)
        } catch is CancellationError {
            return
        } catch {
            response = AgentResponseContent(agentId: profile.id, title: profile.name, question: transcript,
                                            answer: error.localizedDescription, isError: true)
            fail(error)
        }
    }

    private func deliver(_ answer: String, profile: AgentProfile, question: String) {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        response = AgentResponseContent(agentId: profile.id, title: profile.name, question: question,
                                        answer: text.isEmpty ? "(empty answer)" : text, isError: false)
        if profile.showPanel { onShowPanel?() }
        if profile.copyToClipboard { TextInserter.copy(text) }
        if profile.pasteAtCursor, !text.isEmpty {
            let payload = RichTextConverter.prepare(markdown: text).payload
            TextInserter.insert(payload, into: insertionTarget, restoreClipboard: !profile.copyToClipboard) { _ in }
        }
        if profile.speech.engine != .off, !text.isEmpty {
            speak(text, config: profile.speech)
        } else {
            finishSession()
        }
    }

    func speak(_ text: String, config: VoiceOutputConfig) {
        state = .speaking
        isSpeakingResponse = true
        speech.speak(text, config: config, apiKey: openAIKeyProvider()) { [weak self] error in
            guard let self else { return }
            self.isSpeakingResponse = false
            if let error {
                self.fail(error)
            } else if self.state == .speaking {
                self.finishSession()
            }
        }
    }

    /// Speak the current panel answer again with the agent's voice (or the
    /// default OpenAI voice when the agent has speech turned off).
    func speakCurrentResponse() {
        guard let response, !response.answer.isEmpty, !state.isBusy else { return }
        var config = response.agentId.flatMap { store.agent(id: $0)?.speech } ?? VoiceOutputConfig()
        if config.engine == .off { config.engine = .openAI }
        speak(response.answer, config: config)
    }

    func stopSpeaking() {
        speech.stop()
    }

    func insertCurrentResponse() {
        guard let response, !response.answer.isEmpty else { return }
        onHidePanel?()
        let payload = RichTextConverter.prepare(markdown: response.answer).payload
        TextInserter.insert(payload, into: insertionTarget, restoreClipboard: true) { _ in }
    }

    func dismissResponse() {
        if state == .speaking { speech.stop() }
        onHidePanel?()
    }

    // MARK: Live

    var isLiveActive: Bool { liveSession != nil }

    func toggleLive() {
        if let liveSession {
            liveSession.stop()
            return
        }
        guard !state.isBusy else {
            NSSound.beep()
            return
        }
        guard MicrophonePermission.isGranted else {
            if MicrophonePermission.isUndetermined {
                MicrophonePermission.request { [weak self] granted in
                    if granted { self?.toggleLive() } else { self?.fail(AudioCaptureError.microphoneDenied) }
                }
            } else {
                fail(AudioCaptureError.microphoneDenied)
            }
            return
        }
        let apiKey = openAIKeyProvider()
        guard !apiKey.isEmpty else {
            fail(VoiceServiceError.missingOpenAIKey)
            return
        }

        state = .live(.connecting)
        liveTurns = []
        keyboardMonitor?.setVoiceSessionActive(true)
        let settings = store.live
        if settings.showTranscriptPanel {
            response = nil
            onShowPanel?()
        }
        playSound("Tink")

        workTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshToolsForLive(settings)
            guard self.state == .live(.connecting) else { return }
            let registry = LiveToolRegistry(settings: settings, connections: self.store.connections, agents: self.store.agents)
            let session = LiveAgentSession(apiKey: apiKey, settings: settings, registry: registry) { [weak self] route, arguments in
                guard let self else { throw CancellationError() }
                return try await self.runLiveTool(route, arguments: arguments)
            }
            session.onPhaseChange = { [weak self] phase in
                guard let self, self.liveSession === session else { return }
                if phase != .ended { self.state = .live(phase) }
            }
            session.onTranscriptChange = { [weak self] turns in
                self?.liveTurns = turns
            }
            session.onEnd = { [weak self] error in
                guard let self, self.liveSession === session else { return }
                self.liveSession = nil
                self.playSound("Pop")
                if let error {
                    self.fail(error)
                } else {
                    self.finishSession()
                }
            }
            self.liveSession = session
            session.start()
        }
    }

    /// Fetch tool lists for selected MCP servers that have none cached yet.
    private func refreshToolsForLive(_ settings: LiveAgentSettings) async {
        for id in settings.mcpConnectionIds {
            guard var connection = store.connection(id: id), connection.kind == .mcp, connection.cachedTools.isEmpty else { continue }
            if let tools = try? await dispatcher.listTools(connection: connection) {
                connection.cachedTools = tools
                store.updateConnection(connection)
            }
        }
    }

    private func runLiveTool(_ route: LiveToolRegistry.Route, arguments: [String: Any]) async throws -> String {
        switch route {
        case .mcp(let connectionId, let tool):
            guard let connection = store.connection(id: connectionId) else { throw AgentError.missingConnection(tool) }
            return try await dispatcher.callTool(connection: connection, name: tool, arguments: arguments)
        case .agent(let id):
            guard let profile = store.agent(id: id) else { throw AgentError.missingConnection("agent") }
            let question = arguments["question"] as? String ?? ""
            return try await dispatcher.send(profile: profile, transcript: question, language: store.transcription.language)
        }
    }

    // MARK: State

    /// Esc, or Cancel in the menu.
    func cancel() {
        workTask?.cancel()
        workTask = nil
        capture?.stop()
        localRecording?.cancel()
        realtime?.cancel()
        liveSession?.stop()
        speech.stop()
        cleanUpRecording()
        finishSession()
    }

    private func cleanUpRecording() {
        levelTimer?.invalidate()
        levelTimer = nil
        capture = nil
        localRecording = nil
        realtime = nil
        interpreter = nil
        inputLevel = 0
        partialTranscript = ""
    }

    private func finishSession() {
        cleanUpRecording()
        workTask = nil
        isSpeakingResponse = false
        keyboardMonitor?.setVoiceSessionActive(liveSession != nil)
        if liveSession == nil { state = .idle }
    }

    private func fail(_ error: Error) {
        logger.error("Voice failed: \(error.localizedDescription, privacy: .public)")
        cleanUpRecording()
        workTask = nil
        isSpeakingResponse = false
        keyboardMonitor?.setVoiceSessionActive(liveSession != nil)
        let message = error.localizedDescription
        state = .error(message)
        NSSound.beep()
        errorResetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            if case .error = self?.state { self?.state = .idle }
        }
        errorResetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    private func playSound(_ name: String) {
        guard store.transcription.soundFeedback else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
