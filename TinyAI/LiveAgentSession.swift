import AVFoundation
import Foundation

/// Microphone in and speaker out on one engine, so Apple's voice processing
/// can cancel the model's own voice from what the microphone hears.
nonisolated final class LiveAudioIO: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(LiveProtocol.sampleRate),
                                       channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var scheduledBuffers = 0
    private var generation = 0

    var isPlaying: Bool {
        lock.lock(); defer { lock.unlock() }
        return scheduledBuffers > 0
    }

    func start(onInput: @escaping @Sendable ([Float]) -> Void) throws {
        let input = engine.inputNode
        try? input.setVoiceProcessingEnabled(true)
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, let converter = AVAudioConverter(from: inputFormat, to: format) else {
            throw AudioCaptureError.noInputDevice
        }
        converter.downmix = true
        let ratio = format.sampleRate / inputFormat.sampleRate
        let outputFormat = format
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
            guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
            var consumed = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let channel = converted.floatChannelData?[0], converted.frameLength > 0 else { return }
            onInput(Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength))))
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioCaptureError.engineFailed(error.localizedDescription)
        }
        player.play()
    }

    /// Queue 24 kHz mono samples for playback.
    func play(_ samples: [Float]) {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        lock.lock()
        scheduledBuffers += 1
        let scheduledGeneration = generation
        lock.unlock()
        player.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.generation == scheduledGeneration {
                self.scheduledBuffers = max(0, self.scheduledBuffers - 1)
            }
            self.lock.unlock()
        }
        if !player.isPlaying { player.play() }
    }

    /// Drop queued speech, for example when the user interrupts.
    func flushPlayback() {
        lock.lock()
        generation += 1
        scheduledBuffers = 0
        lock.unlock()
        player.stop()
        player.play()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        lock.lock(); scheduledBuffers = 0; lock.unlock()
    }
}

/// A full-duplex GPT-Live conversation.  The model talks while listening and
/// delegates tool work to its backend model; function calls are run here and
/// their results returned to the session.
final class LiveAgentSession {
    enum Phase: Equatable {
        case connecting
        case listening
        case speaking
        case usingTool(String)
        case ended
    }

    struct Turn: Identifiable, Equatable {
        enum Role { case user, assistant, tool }
        let id = UUID()
        let role: Role
        var text: String
    }

    typealias ToolExecutor = (LiveToolRegistry.Route, [String: Any]) async throws -> String

    var onPhaseChange: ((Phase) -> Void)?
    var onTranscriptChange: (([Turn]) -> Void)?
    var onEnd: ((Error?) -> Void)?

    private let apiKey: String
    private let settings: LiveAgentSettings
    private let registry: LiveToolRegistry
    private let executeTool: ToolExecutor
    private var task: URLSessionWebSocketTask?
    private let audio = LiveAudioIO()
    private var turns: [Turn] = []
    private var phase: Phase = .connecting
    private var activeTools = 0
    private var ended = false
    private var stopRequested = false
    private var eventCounter = 0
    private var phaseTimer: Timer?

    init(apiKey: String, settings: LiveAgentSettings, registry: LiveToolRegistry, executeTool: @escaping ToolExecutor) {
        self.apiKey = apiKey
        self.settings = settings
        self.registry = registry
        self.executeTool = executeTool
    }

    func start() {
        var request = URLRequest(url: LiveProtocol.url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let task = URLSession.shared.webSocketTask(with: request)
        task.maximumMessageSize = 16 * 1024 * 1024
        self.task = task
        task.resume()
        setPhase(.connecting)
        send(LiveProtocol.sessionStart(settings: settings, tools: registry.definitions))
        receive()
    }

    func stop() {
        guard !ended else { return }
        stopRequested = true
        send(LiveProtocol.close())
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.finish(nil)
        }
    }

    private func startAudio() {
        do {
            try audio.start { [weak self] samples in
                let data = AudioCoding.pcm16Data(from: samples)
                DispatchQueue.main.async {
                    self?.send(LiveProtocol.inputAudio(data))
                }
            }
        } catch {
            finish(error)
            return
        }
        phaseTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.refreshPhase()
        }
        refreshPhase()
    }

    private func refreshPhase() {
        guard !ended else { return }
        if activeTools > 0, case .usingTool = phase { return }
        setPhase(audio.isPlaying ? .speaking : .listening)
    }

    private func setPhase(_ newPhase: Phase) {
        guard newPhase != phase || newPhase == .connecting else { return }
        phase = newPhase
        onPhaseChange?(newPhase)
    }

    private func send(_ object: [String: Any]) {
        guard let task, !ended,
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async { self?.finish(error) }
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !self.ended else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.handle(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) { self.handle(text) }
                    @unknown default:
                        break
                    }
                    self.receive()
                case .failure(let error):
                    self.finish(error)
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let event = LiveProtocol.parse(text) else { return }
        switch event {
        case .started:
            startAudio()
        case .closed:
            finish(nil)
        case .inputTranscriptDelta(let delta):
            append(delta, role: .user)
        case .outputTranscriptDelta(let delta):
            append(delta, role: .assistant)
        case .outputAudio(let data):
            audio.play(AudioCoding.floatSamples(fromPCM16: data))
        case .userStartedSpeaking:
            audio.flushPlayback()
        case .functionCall(let callId, let name, let arguments):
            runTool(callId: callId, name: name, arguments: arguments)
        case .error(let message):
            // Errors before the session starts are fatal; later ones are
            // shown in the transcript and the conversation continues.
            if phase == .connecting {
                finish(VoiceServiceError.invalidResponse(message))
            } else {
                appendTurn(Turn(role: .tool, text: "⚠️ \(message)"))
            }
        case .ignored:
            break
        }
    }

    private func append(_ delta: String, role: Turn.Role) {
        guard !delta.isEmpty else { return }
        if var last = turns.last, last.role == role {
            last.text += delta
            turns[turns.count - 1] = last
        } else {
            turns.append(Turn(role: role, text: delta))
        }
        onTranscriptChange?(turns)
    }

    private func appendTurn(_ turn: Turn) {
        turns.append(turn)
        onTranscriptChange?(turns)
    }

    private func runTool(callId: String, name: String, arguments: String) {
        guard let route = registry.routes[name] else {
            returnToolResult(callId: callId, output: #"{"error":"Unknown tool"}"#)
            return
        }
        let parsed = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
        activeTools += 1
        setPhase(.usingTool(name))
        appendTurn(Turn(role: .tool, text: "🔧 \(name)"))
        Task { [weak self] in
            guard let self else { return }
            let output: String
            do {
                output = try await self.executeTool(route, parsed)
            } catch {
                output = "Error: \(error.localizedDescription)"
            }
            self.activeTools = max(0, self.activeTools - 1)
            self.returnToolResult(callId: callId, output: output)
            self.refreshPhase()
        }
    }

    private func returnToolResult(callId: String, output: String) {
        eventCounter += 1
        // Keep tool output within a size the model can take in.
        let trimmed = output.count > 60_000 ? String(output.prefix(60_000)) + "…" : output
        send(LiveProtocol.functionOutput(callId: callId, output: trimmed, eventId: "tinyai_tool_\(eventCounter)"))
        send(LiveProtocol.continueResponse(eventId: "tinyai_continue_\(eventCounter)"))
    }

    private func finish(_ error: Error?) {
        guard !ended else { return }
        ended = true
        phaseTimer?.invalidate()
        phaseTimer = nil
        audio.stop()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        phase = .ended
        onPhaseChange?(.ended)
        onEnd?(stopRequested ? nil : error)
    }
}
