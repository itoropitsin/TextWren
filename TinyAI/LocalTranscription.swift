import Foundation
import Combine
import CryptoKit
import CTranscribe

// MARK: - Model files

enum LocalModelState: Equatable {
    case notDownloaded
    case downloading(Double)
    case verifying
    case ready
    case failed(String)
}

/// Downloads, verifies and deletes the local model files.
final class LocalModelManager: ObservableObject {
    @Published private(set) var states: [LocalTranscriptionModel: LocalModelState] = [:]

    private var tasks: [LocalTranscriptionModel: URLSessionDownloadTask] = [:]
    private var progressObservers: [LocalTranscriptionModel: NSKeyValueObservation] = [:]

    nonisolated static var modelsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("TinyAI/Models", isDirectory: true)
    }

    nonisolated static func fileURL(for model: LocalTranscriptionModel) -> URL {
        modelsDirectory.appendingPathComponent(model.filename)
    }

    nonisolated static func isDownloaded(_ model: LocalTranscriptionModel) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: model).path)
    }

    init() {
        refresh()
    }

    func refresh() {
        for model in LocalTranscriptionModel.allCases where tasks[model] == nil {
            states[model] = Self.isDownloaded(model) ? .ready : .notDownloaded
        }
    }

    func state(for model: LocalTranscriptionModel) -> LocalModelState {
        states[model] ?? .notDownloaded
    }

    func download(_ model: LocalTranscriptionModel) {
        guard tasks[model] == nil, !Self.isDownloaded(model) else { return }
        start(model, urls: model.downloadURLs)
    }

    func cancelDownload(_ model: LocalTranscriptionModel) {
        tasks[model]?.cancel()
        tasks[model] = nil
        progressObservers[model] = nil
        states[model] = .notDownloaded
    }

    func delete(_ model: LocalTranscriptionModel) {
        cancelDownload(model)
        LocalTranscriptionEngine.shared.unload()
        try? FileManager.default.removeItem(at: Self.fileURL(for: model))
        states[model] = .notDownloaded
    }

    private func start(_ model: LocalTranscriptionModel, urls: [URL]) {
        guard let url = urls.first else { return }
        let remaining = Array(urls.dropFirst())
        states[model] = .downloading(0)

        let staging = Self.modelsDirectory.appendingPathComponent(".\(model.filename).download")
        let task = URLSession.shared.downloadTask(with: url) { [weak self] location, response, error in
            // The temporary file disappears when this handler returns, so it
            // is moved into place synchronously here.
            var moveError: Error?
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let location, error == nil, (200..<300).contains(status) {
                do {
                    try FileManager.default.createDirectory(at: Self.modelsDirectory, withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: staging)
                    try FileManager.default.moveItem(at: location, to: staging)
                } catch {
                    moveError = error
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.tasks[model] = nil
                self.progressObservers[model] = nil
                if let error = error as NSError?, error.code == NSURLErrorCancelled { return }
                if error != nil || moveError != nil || !(200..<300).contains(status) {
                    if !remaining.isEmpty {
                        self.start(model, urls: remaining)
                    } else {
                        let message = error?.localizedDescription ?? moveError?.localizedDescription ?? "HTTP \(status)"
                        self.states[model] = .failed("Download failed: \(message)")
                    }
                    return
                }
                self.verify(model, staging: staging)
            }
        }
        progressObservers[model] = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            let fraction = progress.fractionCompleted
            DispatchQueue.main.async {
                guard let self, self.tasks[model] != nil else { return }
                self.states[model] = .downloading(fraction)
            }
        }
        tasks[model] = task
        task.resume()
    }

    private func verify(_ model: LocalTranscriptionModel, staging: URL) {
        states[model] = .verifying
        let expected = model.sha256
        let destination = Self.fileURL(for: model)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let actual = Self.sha256(of: staging)
            var failure: String?
            if actual == expected {
                do {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: staging, to: destination)
                } catch {
                    failure = error.localizedDescription
                }
            } else {
                try? FileManager.default.removeItem(at: staging)
                failure = "The downloaded file is damaged (checksum mismatch)."
            }
            DispatchQueue.main.async {
                self?.states[model] = failure.map { .failed($0) } ?? .ready
            }
        }
    }

    nonisolated static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = autoreleasepool { handle.readData(ofLength: 8 * 1024 * 1024) }
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Engine

enum LocalTranscriptionError: LocalizedError {
    case modelMissing(String)
    case unsupportedLanguage
    case engine(String)

    var errorDescription: String? {
        switch self {
        case .modelMissing(let name):
            return "\(name) is not downloaded yet. Download it in Settings → Voice."
        case .unsupportedLanguage:
            return "The local model does not support the selected language."
        case .engine(let message):
            return "Local transcription failed: \(message)"
        }
    }
}

/// Runs transcribe.cpp on one serial queue.  The model stays loaded between
/// recordings and is released after five idle minutes, as Handy does.
nonisolated final class LocalTranscriptionEngine: @unchecked Sendable {
    static let shared = LocalTranscriptionEngine()
    static let sampleRate = 16_000
    static let idleUnloadDelay: TimeInterval = 300

    private let queue = DispatchQueue(label: "IT.TinyAI.LocalTranscription", qos: .userInitiated)
    private var model: OpaquePointer?
    private var session: OpaquePointer?
    private var loadedPath: String?
    private var streamActive = false
    private var idleWorkItem: DispatchWorkItem?

    /// Load the model in the background so it is ready when recording stops.
    func preload(_ localModel: LocalTranscriptionModel) {
        let path = LocalModelManager.fileURL(for: localModel).path
        queue.async {
            guard (try? self.ensureLoaded(path: path)) != nil, !self.streamActive else { return }
            self.scheduleIdleUnload()
        }
    }

    func unload() {
        queue.async { self.freeModel() }
    }

    /// Begin a recording.  Streaming models receive audio while the user
    /// talks; `onText` reports the live committed + tentative text.
    func begin(
        model localModel: LocalTranscriptionModel,
        language: String,
        onText: @escaping @Sendable (String) -> Void
    ) -> LocalTranscriptionRecording {
        let path = LocalModelManager.fileURL(for: localModel).path
        let hint = localModel.languages.contains(language) ? language : nil
        let recording = LocalTranscriptionRecording(engine: self, streaming: localModel.supportsStreaming)
        queue.async {
            self.cancelIdleUnload()
            do {
                guard FileManager.default.fileExists(atPath: path) else {
                    throw LocalTranscriptionError.modelMissing(localModel.displayName)
                }
                try self.ensureLoaded(path: path)
                var acceptedHint = hint
                if localModel.supportsStreaming {
                    acceptedHint = try self.beginStreamAcceptingLanguage(hint)
                }
                recording.markReady(language: acceptedHint, onText: onText)
            } catch {
                recording.markFailed(error)
            }
        }
        return recording
    }

    // Called on `queue` only.

    fileprivate func feed(_ samples: [Float], onText: @Sendable (String) -> Void) throws {
        guard streamActive, let session else { return }
        var update = transcribe_stream_update()
        transcribe_stream_update_init(&update)
        let status = samples.withUnsafeBufferPointer {
            transcribe_stream_feed(session, $0.baseAddress, Int32($0.count), &update)
        }
        try check(status, "stream_feed")
        if update.committed_changed || update.tentative_changed {
            onText(streamText())
        }
    }

    fileprivate func finishStream() throws -> String {
        guard streamActive, let session else { return "" }
        var update = transcribe_stream_update()
        transcribe_stream_update_init(&update)
        let status = transcribe_stream_finalize(session, &update)
        streamActive = false
        try check(status, "stream_finalize")
        scheduleIdleUnload()
        return streamText()
    }

    fileprivate func runOffline(_ samples: [Float], language: String?) throws -> String {
        do {
            return try runOfflineOnce(samples, language: language)
        } catch LocalTranscriptionError.unsupportedLanguage where language != nil {
            // Some families only auto-detect; retry without the hint.
            return try runOfflineOnce(samples, language: nil)
        }
    }

    private func runOfflineOnce(_ samples: [Float], language: String?) throws -> String {
        guard let session else { throw LocalTranscriptionError.engine("model is not loaded") }
        defer { scheduleIdleUnload() }
        if streamActive {
            transcribe_stream_reset(session)
            streamActive = false
        }
        guard !samples.isEmpty else { return "" }
        var params = transcribe_run_params()
        transcribe_run_params_init(&params)
        let status: transcribe_status = withOptionalCString(language) { languagePointer in
            params.language = languagePointer
            return samples.withUnsafeBufferPointer {
                transcribe_run(session, $0.baseAddress, Int32($0.count), &params)
            }
        }
        try check(status, "run")
        return String(cString: transcribe_full_text(session))
    }

    fileprivate func abandonStream() {
        if streamActive, let session {
            transcribe_stream_reset(session)
        }
        streamActive = false
        scheduleIdleUnload()
    }

    fileprivate func async(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    private func ensureLoaded(path: String) throws {
        if loadedPath == path, model != nil, session != nil { return }
        freeModel()
        var loadParams = transcribe_model_load_params()
        transcribe_model_load_params_init(&loadParams)
        var loadedModel: OpaquePointer?
        try check(transcribe_model_load_file(path, &loadParams, &loadedModel), "loading model")
        guard let loadedModel else { throw LocalTranscriptionError.engine("model failed to load") }

        var sessionParams = transcribe_session_params()
        transcribe_session_params_init(&sessionParams)
        var newSession: OpaquePointer?
        let status = transcribe_session_init(loadedModel, &sessionParams, &newSession)
        guard status == TRANSCRIBE_OK, let newSession else {
            transcribe_model_free(loadedModel)
            try check(status, "creating session")
            throw LocalTranscriptionError.engine("session failed to start")
        }
        model = loadedModel
        session = newSession
        loadedPath = path
    }

    /// Begin streaming, retrying without a language hint when the model only
    /// auto-detects. Returns the hint that was accepted.
    @discardableResult
    fileprivate func beginStreamAcceptingLanguage(_ language: String?) throws -> String? {
        do {
            try beginStream(language: language)
            return language
        } catch LocalTranscriptionError.unsupportedLanguage where language != nil {
            try beginStream(language: nil)
            return nil
        }
    }

    private func beginStream(language: String?) throws {
        guard let session else { return }
        if streamActive { transcribe_stream_reset(session) }
        var runParams = transcribe_run_params()
        transcribe_run_params_init(&runParams)
        var streamParams = transcribe_stream_params()
        transcribe_stream_params_init(&streamParams)
        let status: transcribe_status = withOptionalCString(language) { languagePointer in
            runParams.language = languagePointer
            return transcribe_stream_begin(session, &runParams, &streamParams)
        }
        try check(status, "stream_begin")
        streamActive = true
    }

    private func streamText() -> String {
        guard let session else { return "" }
        var text = transcribe_stream_text()
        transcribe_stream_text_init(&text)
        _ = transcribe_stream_get_text(session, &text)
        let committed = text.committed_text.map { String(cString: $0) } ?? ""
        let tentative = text.tentative_text.map { String(cString: $0) } ?? ""
        return committed + tentative
    }

    private func freeModel() {
        cancelIdleUnload()
        if let session {
            if streamActive { transcribe_stream_reset(session) }
            transcribe_session_free(session)
        }
        if let model { transcribe_model_free(model) }
        session = nil
        model = nil
        loadedPath = nil
        streamActive = false
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

    private func check(_ status: transcribe_status, _ context: String) throws {
        guard status != TRANSCRIBE_OK else { return }
        if status == TRANSCRIBE_ERR_UNSUPPORTED_LANGUAGE {
            throw LocalTranscriptionError.unsupportedLanguage
        }
        let message = String(cString: transcribe_status_string(Int32(bitPattern: status.rawValue)))
        throw LocalTranscriptionError.engine("\(context): \(message)")
    }

    private func withOptionalCString<R>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> R) -> R {
        guard let string else { return body(nil) }
        return string.withCString { body($0) }
    }
}

/// One recording on the local engine.  Audio fed before the model finished
/// loading is kept and replayed, so nothing said early is lost.
nonisolated final class LocalTranscriptionRecording: @unchecked Sendable {
    private let engine: LocalTranscriptionEngine
    private let streaming: Bool
    private let lock = NSLock()
    private var ready = false
    private var failure: Error?
    private var language: String?
    private var onText: (@Sendable (String) -> Void)?
    private var pending: [[Float]] = []
    private var streamFailed = false

    fileprivate init(engine: LocalTranscriptionEngine, streaming: Bool) {
        self.engine = engine
        self.streaming = streaming
    }

    fileprivate func markReady(language: String?, onText: @escaping @Sendable (String) -> Void) {
        lock.lock()
        ready = true
        self.language = language
        self.onText = onText
        let backlog = pending
        pending = []
        lock.unlock()
        // Already on the engine queue: replay the backlog before anything
        // queued later (such as `finish`) can run.
        for chunk in backlog { process(chunk) }
    }

    fileprivate func markFailed(_ error: Error) {
        lock.lock()
        failure = error
        pending = []
        lock.unlock()
    }

    /// 16 kHz mono samples from the microphone.
    func feed(_ samples: [Float]) {
        guard streaming else { return }
        lock.lock()
        if !ready {
            if failure == nil { pending.append(samples) }
            lock.unlock()
            return
        }
        lock.unlock()
        feedNow(samples)
    }

    private func feedNow(_ samples: [Float]) {
        engine.async { [self] in process(samples) }
    }

    /// Runs on the engine queue.
    private func process(_ samples: [Float]) {
        lock.lock()
        let skip = streamFailed
        let callback = onText
        lock.unlock()
        guard !skip, let callback else { return }
        do {
            try engine.feed(samples, onText: callback)
        } catch {
            lock.lock(); streamFailed = true; lock.unlock()
        }
    }

    /// Finish the recording.  Streaming falls back to one offline pass over
    /// the whole recording when the stream failed or produced nothing.
    func finish(allSamples: [Float]) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            engine.async { [self] in
                lock.lock()
                let failure = self.failure
                let streamFailed = self.streamFailed
                let language = self.language
                lock.unlock()
                if let failure {
                    continuation.resume(throwing: failure)
                    return
                }
                do {
                    var text = ""
                    if streaming && !streamFailed {
                        text = (try? engine.finishStream()) ?? ""
                    }
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        text = try engine.runOffline(allSamples, language: language)
                    }
                    continuation.resume(returning: text.trimmingCharacters(in: .whitespacesAndNewlines))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func cancel() {
        engine.async { [self] in
            lock.lock(); streamFailed = true; lock.unlock()
            engine.abandonStream()
        }
    }
}

