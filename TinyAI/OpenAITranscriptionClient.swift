import Foundation

enum VoiceServiceError: LocalizedError {
    case missingOpenAIKey
    case http(status: Int, message: String)
    case invalidResponse(String)
    case emptyTranscript
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .missingOpenAIKey:
            return "Add an OpenAI API key in Settings → API."
        case .http(let status, let message):
            return "Request failed (\(status)): \(message)"
        case .invalidResponse(let message):
            return "Unexpected response: \(message)"
        case .emptyTranscript:
            return "Nothing was recognised."
        case .timedOut(let what):
            return "\(what) timed out."
        }
    }

    /// Pull a readable message out of an OpenAI-style error body.
    static func message(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
                return message
            }
            if let message = object["message"] as? String { return message }
            if let error = object["error"] as? String { return error }
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.isEmpty ? "No details." : String(text.prefix(300))
    }
}

/// A `multipart/form-data` body builder.
nonisolated struct MultipartFormData {
    let boundary: String
    private(set) var body = Data()

    init(boundary: String = "TinyAI-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addField(_ name: String, _ value: String) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        body.append(Data("\(value)\r\n".utf8))
    }

    mutating func addFile(_ name: String, filename: String, mimeType: String, data: Data) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    func finalized() -> Data {
        var result = body
        result.append(Data("--\(boundary)--\r\n".utf8))
        return result
    }
}

/// OpenAI speech-to-text: whole-file transcription and live realtime sessions.
enum OpenAITranscriptionClient {
    static let transcriptionsURL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!

    static func transcriptionRequest(
        wav: Data,
        model: String,
        language: String,
        prompt: String,
        apiKey: String
    ) -> URLRequest {
        var form = MultipartFormData()
        form.addField("model", model)
        if !language.isEmpty { form.addField("language", language) }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPrompt.isEmpty { form.addField("prompt", trimmedPrompt) }
        form.addField("response_format", "json")
        form.addFile("file", filename: "speech.wav", mimeType: "audio/wav", data: wav)

        var request = URLRequest(url: transcriptionsURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finalized()
        return request
    }

    static func transcribe(
        samples: [Float],
        sampleRate: Int,
        model: String,
        language: String,
        prompt: String,
        apiKey: String
    ) async throws -> String {
        guard !apiKey.isEmpty else { throw VoiceServiceError.missingOpenAIKey }
        let request = transcriptionRequest(
            wav: AudioCoding.wavData(samples: samples, sampleRate: sampleRate),
            model: model, language: language, prompt: prompt, apiKey: apiKey
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw VoiceServiceError.http(status: status, message: VoiceServiceError.message(from: data))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String else {
            throw VoiceServiceError.invalidResponse(String(data: data, encoding: .utf8) ?? "")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A realtime transcription session: audio streams in while the user talks
/// and text deltas stream back.  `finish()` commits the audio and waits for
/// the completed transcript.
final class OpenAIRealtimeTranscriber {
    static let url = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!
    static let sampleRate = 24_000

    private let task: URLSessionWebSocketTask
    private let onPartial: (String) -> Void
    private var completedItems: [String] = []
    private var partialByItem: [String: String] = [:]
    private var itemOrder: [String] = []
    private var finishContinuation: CheckedContinuation<String, Error>?
    private var pendingCompletions = 0
    private var failure: Error?
    private var closed = false

    init(apiKey: String, model: String, language: String, prompt: String, onPartial: @escaping (String) -> Void) {
        var request = URLRequest(url: Self.url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        task = URLSession.shared.webSocketTask(with: request)
        self.onPartial = onPartial
        task.resume()
        send(Self.sessionUpdate(model: model, language: language, prompt: prompt))
        receive()
    }

    static func sessionUpdate(model: String, language: String, prompt: String) -> [String: Any] {
        var transcription: [String: Any] = ["model": model]
        if !language.isEmpty { transcription["languages"] = [language] }
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPrompt.isEmpty { transcription["prompt"] = trimmedPrompt }
        return [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": sampleRate],
                        "transcription": transcription,
                        "turn_detection": NSNull()
                    ]
                ]
            ]
        ]
    }

    /// Append 24 kHz mono samples.
    func append(_ samples: [Float]) {
        guard !closed, !samples.isEmpty else { return }
        send([
            "type": "input_audio_buffer.append",
            "audio": AudioCoding.pcm16Data(from: samples).base64EncodedString()
        ])
    }

    /// Commit the buffered audio and wait for the final transcript.
    func finish(timeout: TimeInterval = 15) async throws -> String {
        if let failure { throw failure }
        pendingCompletions += 1
        send(["type": "input_audio_buffer.commit"])
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            self?.resolveFinish()
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            finishContinuation = continuation
        }
    }

    func cancel() {
        closed = true
        task.cancel(with: .normalClosure, reason: nil)
        finishContinuation?.resume(throwing: CancellationError())
        finishContinuation = nil
    }

    private var currentText: String {
        let pendingPartials = itemOrder.compactMap { partialByItem[$0] }
        return (completedItems + pendingPartials)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func resolveFinish() {
        guard let continuation = finishContinuation else { return }
        finishContinuation = nil
        let text = currentText
        closed = true
        task.cancel(with: .normalClosure, reason: nil)
        if text.isEmpty, let failure {
            continuation.resume(throwing: failure)
        } else {
            continuation.resume(returning: text)
        }
    }

    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else { return }
        task.send(.string(string)) { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async { self?.handleFailure(error) }
        }
    }

    private func receive() {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !self.closed else { return }
                switch result {
                case .success(let message):
                    if case .string(let text) = message { self.handle(text) }
                    self.receive()
                case .failure(let error):
                    self.handleFailure(error)
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return }
        let itemId = event["item_id"] as? String ?? "item"
        switch type {
        case "conversation.item.input_audio_transcription.delta":
            if !itemOrder.contains(itemId) { itemOrder.append(itemId) }
            partialByItem[itemId, default: ""] += event["delta"] as? String ?? ""
            onPartial(currentText)
        case "conversation.item.input_audio_transcription.completed":
            partialByItem[itemId] = nil
            itemOrder.removeAll { $0 == itemId }
            completedItems.append(event["transcript"] as? String ?? "")
            onPartial(currentText)
            pendingCompletions = max(0, pendingCompletions - 1)
            if pendingCompletions == 0 { resolveFinish() }
        case "conversation.item.input_audio_transcription.failed", "error":
            let error = (event["error"] as? [String: Any])?["message"] as? String ?? "Transcription failed."
            handleFailure(VoiceServiceError.invalidResponse(error))
        default:
            break
        }
    }

    private func handleFailure(_ error: Error) {
        guard !closed else { return }
        failure = error
        if finishContinuation != nil { resolveFinish() }
    }
}
