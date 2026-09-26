import AVFoundation
import Foundation

/// Speaks agent answers with an OpenAI voice or a macOS system voice.
final class SpeechPlayer: NSObject, AVAudioPlayerDelegate, AVSpeechSynthesizerDelegate {
    static let speechURL = URL(string: "https://api.openai.com/v1/audio/speech")!
    /// OpenAI accepts up to 4096 characters per request.
    static let maximumChunkLength = 3800

    private var player: AVAudioPlayer?
    private let synthesizer = AVSpeechSynthesizer()
    private var queue: [String] = []
    private var config = VoiceOutputConfig()
    private var apiKey = ""
    private var generation = 0
    private var fetchTask: Task<Void, Never>?
    private var completion: ((Error?) -> Void)?
    private var nextAudio: [Int: Data] = [:]

    private(set) var isSpeaking = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    static var systemVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().sorted {
            ($0.language, $0.name) < ($1.language, $1.name)
        }
    }

    /// Speak `text`; `completion` runs when playback ends, fails or stops.
    func speak(_ text: String, config: VoiceOutputConfig, apiKey: String, completion: ((Error?) -> Void)? = nil) {
        stop()
        let spoken = Self.speakableText(text)
        guard config.engine != .off, !spoken.isEmpty else {
            completion?(nil)
            return
        }
        generation += 1
        self.config = config
        self.apiKey = apiKey
        self.completion = completion
        isSpeaking = true

        switch config.engine {
        case .system:
            let utterance = AVSpeechUtterance(string: spoken)
            if !config.systemVoiceIdentifier.isEmpty,
               let voice = AVSpeechSynthesisVoice(identifier: config.systemVoiceIdentifier) {
                utterance.voice = voice
            }
            utterance.rate = Float(max(0.5, min(2, config.speed))) * AVSpeechUtteranceDefaultSpeechRate
            synthesizer.speak(utterance)
        case .openAI:
            guard !apiKey.isEmpty else {
                finish(VoiceServiceError.missingOpenAIKey)
                return
            }
            queue = Self.chunks(of: spoken, maximumLength: Self.maximumChunkLength)
            playNextChunk(index: 0, generation: generation)
        case .off:
            finish(nil)
        }
    }

    func stop() {
        generation += 1
        fetchTask?.cancel()
        fetchTask = nil
        player?.stop()
        player = nil
        queue = []
        nextAudio = [:]
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        if isSpeaking {
            isSpeaking = false
            let callback = completion
            completion = nil
            callback?(nil)
        }
    }

    // MARK: OpenAI

    static func speechRequest(text: String, config: VoiceOutputConfig, apiKey: String) -> URLRequest {
        var request = URLRequest(url: speechURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": config.openAIModel,
            "voice": config.openAIVoice,
            "input": text,
            "response_format": "mp3",
            "speed": max(0.25, min(4, config.speed))
        ]
        let instructions = config.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instructions.isEmpty && config.openAIModel.hasPrefix("gpt-") {
            body["instructions"] = instructions
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func fetchAudio(_ text: String) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: Self.speechRequest(text: text, config: config, apiKey: apiKey))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw VoiceServiceError.http(status: status, message: VoiceServiceError.message(from: data))
        }
        return data
    }

    private func playNextChunk(index: Int, generation: Int) {
        guard generation == self.generation else { return }
        guard index < queue.count else {
            finish(nil)
            return
        }
        let text = queue[index]
        let prefetched = nextAudio.removeValue(forKey: index)
        fetchTask = Task { [weak self] in
            do {
                let data: Data
                if let prefetched {
                    data = prefetched
                } else {
                    data = try await self?.fetchAudio(text) ?? Data()
                }
                guard let self, generation == self.generation else { return }
                try self.play(data, index: index, generation: generation)
                // Fetch the following chunk while this one plays.
                if index + 1 < self.queue.count {
                    let nextText = self.queue[index + 1]
                    if let nextData = try? await self.fetchAudio(nextText), generation == self.generation {
                        self.nextAudio[index + 1] = nextData
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, generation == self.generation else { return }
                self.finish(error)
            }
        }
    }

    private var playingIndex = 0

    private func play(_ data: Data, index: Int, generation: Int) throws {
        let player = try AVAudioPlayer(data: data)
        player.delegate = self
        self.player = player
        playingIndex = index
        player.play()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, player === self.player else { return }
            self.playNextChunk(index: self.playingIndex + 1, generation: self.generation)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in self?.finish(nil) }
    }

    private func finish(_ error: Error?) {
        guard isSpeaking else { return }
        isSpeaking = false
        player = nil
        queue = []
        let callback = completion
        completion = nil
        callback?(error)
    }

    // MARK: Text

    /// Markdown markers read aloud badly; keep only the words.
    static func speakableText(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: #"```[\s\S]*?```"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?m)^\s{0,3}(#{1,6}|[-*+]|\d+\.)\s+"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"[*_`~]{1,3}"#, with: "", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Split text at sentence ends so every piece fits one request.
    static func chunks(of text: String, maximumLength: Int) -> [String] {
        guard text.count > maximumLength else { return [text] }
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .localized]) { substring, _, _, _ in
            if let substring { sentences.append(substring) }
        }
        if sentences.isEmpty { sentences = [text] }

        var chunks: [String] = []
        var current = ""
        for sentence in sentences {
            var piece = sentence
            while piece.count > maximumLength {
                let cut = piece.index(piece.startIndex, offsetBy: maximumLength)
                if !current.isEmpty { chunks.append(current); current = "" }
                chunks.append(String(piece[..<cut]))
                piece = String(piece[cut...])
            }
            if current.count + piece.count > maximumLength {
                chunks.append(current)
                current = piece
            } else {
                current += piece
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { chunks.append(current) }
        return chunks.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
