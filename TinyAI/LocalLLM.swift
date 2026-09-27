import Foundation
import llama

// MARK: - Model file

/// On-device text models, run by llama.cpp.  The GGUF revision and hash are
/// pinned so a download is verified before it is used.
nonisolated enum LocalLanguageModel: String, Codable, CaseIterable, Identifiable, Sendable {
    case qwen35_4B

    var id: String { rawValue }

    /// The model name used in `ModelCatalog` (`local:<name>`).
    var catalogName: String {
        switch self {
        case .qwen35_4B: return "qwen3.5-4b"
        }
    }

    var displayName: String {
        switch self {
        case .qwen35_4B: return "Qwen3.5 4B"
        }
    }

    /// Memory the loaded model takes, measured on Apple Silicon.
    var memoryFootprint: String {
        switch self {
        case .qwen35_4B: return "≈3 GB RAM"
        }
    }

    var useCase: String {
        switch self {
        case .qwen35_4B:
            return "Runs on this Mac, text never leaves the device. Close to GPT-6 Luna for grammar; noticeably weaker for translation. Takes \(memoryFootprint) while loaded."
        }
    }

    var repository: String {
        switch self {
        case .qwen35_4B: return "unsloth/Qwen3.5-4B-GGUF"
        }
    }

    var revision: String {
        switch self {
        case .qwen35_4B: return "e87f176479d0855a907a41277aca2f8ee7a09523"
        }
    }

    var filename: String {
        switch self {
        case .qwen35_4B: return "Qwen3.5-4B-Q4_K_M.gguf"
        }
    }

    var sha256: String {
        switch self {
        case .qwen35_4B: return "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4"
        }
    }

    var sizeBytes: Int64 {
        switch self {
        case .qwen35_4B: return 2_740_937_888
        }
    }

    var downloadURLs: [URL] {
        [URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(filename)")!]
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    static func forCatalogName(_ name: String) -> LocalLanguageModel? {
        allCases.first { $0.catalogName == name }
    }
}

// MARK: - Requests

enum LocalLLMError: LocalizedError {
    case modelMissing(String)
    case unknownModel(String)
    case inputTooLong
    case engine(String)

    var errorDescription: String? {
        switch self {
        case .modelMissing(let name):
            return "\(name) is not downloaded yet. Download it in Settings → API."
        case .unknownModel(let name):
            return "Unknown on-device model: \(name)"
        case .inputTooLong:
            return "The text is too long for the on-device model."
        case .engine(let message):
            return "On-device model failed: \(message)"
        }
    }
}

/// A running on-device request.  It stands in for `URLSessionDataTask` in
/// the translation calls, so views cancel both the same way.
protocol CancellableRequest: AnyObject {
    func cancel()
}

extension URLSessionDataTask: CancellableRequest {}

nonisolated final class LocalLLMTask: CancellableRequest, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
}

nonisolated struct LocalLLMRequest: Sendable {
    var systemPrompt: String
    var userText: String
    var reasoningEffort: ReasoningEffort

    /// Thinking tokens allowed before the answer is forced; nil turns
    /// thinking off.  Qwen only switches thinking on or off, so the levels
    /// are budgets.
    var thinkingBudget: Int? {
        switch reasoningEffort {
        case .none, .minimal: return nil
        case .low: return 1024
        case .medium: return 4096
        case .high, .xhigh, .max: return 12288
        }
    }
}

// MARK: - Engine

/// Runs llama.cpp on one serial queue.  The model stays loaded between
/// requests and is released after five idle minutes, like the speech engine.
nonisolated final class LocalLLMEngine: @unchecked Sendable {
    static let shared = LocalLLMEngine()
    static let idleUnloadDelay: TimeInterval = 300
    static let maximumContext = 32_768

    private let queue = DispatchQueue(label: "IT.TinyAI.LocalLLM", qos: .userInitiated)
    private var model: OpaquePointer?
    private var loadedPath: String?
    private var idleWorkItem: DispatchWorkItem?

    private init() {
        // See LocalTranscriptionEngine: Metal residency sets abort on quit.
        setenv("GGML_METAL_NO_RESIDENCY", "1", 1)
        llama_log_set({ _, _, _ in }, nil)
        llama_backend_init()
    }

    /// Generate a reply.  `completion` runs on the main queue; a cancelled
    /// request finishes with `URLError(.cancelled)`, as network calls do.
    @discardableResult
    func generate(
        _ request: LocalLLMRequest,
        model localModel: LocalLanguageModel,
        completion: @escaping @MainActor (Result<String, Error>) -> Void
    ) -> LocalLLMTask {
        let task = LocalLLMTask()
        let path = LocalModelManager.fileURL(for: localModel).path
        queue.async {
            self.cancelIdleUnload()
            let result: Result<String, Error>
            do {
                guard FileManager.default.fileExists(atPath: path) else {
                    throw LocalLLMError.modelMissing(localModel.displayName)
                }
                try self.ensureLoaded(path: path)
                result = .success(try self.run(request, task: task))
            } catch {
                result = .failure(error)
            }
            self.scheduleIdleUnload()
            DispatchQueue.main.async { completion(result) }
        }
        return task
    }

    func unload() {
        queue.async { self.freeModel() }
    }

    /// Free the model before the process exits (see LocalTranscriptionEngine).
    func unloadNow() {
        queue.sync { self.freeModel() }
    }

    // Called on `queue` only.

    private func ensureLoaded(path: String) throws {
        if loadedPath == path, model != nil { return }
        freeModel()
        var params = llama_model_default_params()
        params.n_gpu_layers = 999
        guard let loaded = llama_model_load_from_file(path, params) else {
            throw LocalLLMError.engine("the model failed to load")
        }
        model = loaded
        loadedPath = path
    }

    private func run(_ request: LocalLLMRequest, task: LocalLLMTask) throws -> String {
        guard let model else { throw LocalLLMError.engine("the model is not loaded") }
        guard let vocab = llama_model_get_vocab(model) else { throw LocalLLMError.engine("the model has no vocabulary") }

        // Template markers are parsed as special tokens; the prompt and the
        // user's text are not, so text such as "<|im_end|>" stays plain text.
        let thinking = request.thinkingBudget != nil
        var prompt: [llama_token] = []
        prompt += try tokenize("<|im_start|>system\n", vocab: vocab, special: true)
        prompt += try tokenize(request.systemPrompt, vocab: vocab, special: false)
        prompt += try tokenize("<|im_end|>\n<|im_start|>user\n", vocab: vocab, special: true)
        let userTokens = try tokenize(request.userText, vocab: vocab, special: false)
        prompt += userTokens
        prompt += try tokenize(
            "<|im_end|>\n<|im_start|>assistant\n" + (thinking ? "<think>\n" : "<think>\n\n</think>\n\n"),
            vocab: vocab, special: true
        )

        let answerBudget = min(userTokens.count * 2 + 1024, 8192)
        let thinkingBudget = request.thinkingBudget ?? 0
        let contextSize = prompt.count + thinkingBudget + answerBudget + 64
        guard contextSize <= Self.maximumContext else { throw LocalLLMError.inputTooLong }

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(contextSize)
        contextParams.n_batch = UInt32(max(prompt.count, 512))
        contextParams.no_perf = true
        guard let context = llama_init_from_model(model, contextParams) else {
            throw LocalLLMError.engine("could not create a context")
        }
        defer { llama_free(context) }

        let sampler = makeSampler(thinking: thinking)
        defer { llama_sampler_free(sampler) }

        try decode(&prompt, context: context)

        let endThinking = try tokenize("\n</think>\n\n", vocab: vocab, special: true)
        var output: [UInt8] = []
        var inAnswer = !thinking
        var thinkingTokens = 0
        var answerTokens = 0

        while true {
            if task.isCancelled { throw URLError(.cancelled) }
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            output += piece(token, vocab: vocab)

            if inAnswer {
                answerTokens += 1
                if answerTokens >= answerBudget { break }
            } else if String(decoding: output.suffix(32), as: UTF8.self).contains("</think>") {
                inAnswer = true
            } else {
                thinkingTokens += 1
                if thinkingTokens >= thinkingBudget {
                    // Out of thinking budget: close the block and answer.
                    var forced = endThinking
                    output += Array("\n</think>\n\n".utf8)
                    try decode(&forced, context: context)
                    inAnswer = true
                    continue
                }
            }
            try decode(&token, context: context)
        }
        // Stopping inside the thinking block would return the thinking as
        // the answer.
        guard inAnswer else { throw LocalLLMError.engine("the model stopped before answering") }
        return Self.answer(from: String(decoding: output, as: UTF8.self))
    }

    /// The reply after any thinking block.
    static func answer(from output: String) -> String {
        var text = output
        if let end = text.range(of: "</think>") {
            text = String(text[end.upperBound...])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeSampler(thinking: Bool) -> UnsafeMutablePointer<llama_sampler> {
        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())!
        // Qwen's recommended settings for thinking; low temperature for
        // direct answers, which scored best on grammar and translation.
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(20))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(thinking ? 0.95 : 0.8, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(thinking ? 0.6 : 0.2))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max)))
        return chain
    }

    private func decode(_ tokens: inout [llama_token], context: OpaquePointer) throws {
        let status = tokens.withUnsafeMutableBufferPointer { buffer in
            llama_decode(context, llama_batch_get_one(buffer.baseAddress, Int32(buffer.count)))
        }
        guard status == 0 else { throw LocalLLMError.engine("decoding failed (\(status))") }
    }

    private func decode(_ token: inout llama_token, context: OpaquePointer) throws {
        var tokens = [token]
        try decode(&tokens, context: context)
    }

    private func tokenize(_ text: String, vocab: OpaquePointer, special: Bool) throws -> [llama_token] {
        let utf8Count = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(utf8Count) + 8)
        var count = llama_tokenize(vocab, text, utf8Count, &tokens, Int32(tokens.count), false, special)
        if count < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = llama_tokenize(vocab, text, utf8Count, &tokens, Int32(tokens.count), false, special)
        }
        guard count >= 0 else { throw LocalLLMError.engine("tokenization failed") }
        return Array(tokens.prefix(Int(count)))
    }

    private func piece(_ token: llama_token, vocab: OpaquePointer) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 64)
        var length = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, true)
        if length < 0 {
            buffer = [CChar](repeating: 0, count: Int(-length))
            length = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, true)
        }
        return buffer.prefix(Int(max(length, 0))).map { UInt8(bitPattern: $0) }
    }

    private func freeModel() {
        cancelIdleUnload()
        if let model { llama_model_free(model) }
        model = nil
        loadedPath = nil
    }

    private func scheduleIdleUnload() {
        cancelIdleUnload()
        let item = DispatchWorkItem { [weak self] in self?.freeModel() }
        idleWorkItem = item
        queue.asyncAfter(deadline: .now() + Self.idleUnloadDelay, execute: item)
    }

    private func cancelIdleUnload() {
        idleWorkItem?.cancel()
        idleWorkItem = nil
    }
}
