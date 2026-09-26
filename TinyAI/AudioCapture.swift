import AVFoundation
import Foundation

/// Sample-format helpers shared by transcription, speech and the live session.
nonisolated enum AudioCoding {
    /// Little-endian signed 16-bit PCM from float samples in [-1, 1].
    static func pcm16Data(from samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            var value = Int16(clamped < 0 ? clamped * 32768 : clamped * 32767).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Float samples from little-endian signed 16-bit PCM.
    static func floatSamples(fromPCM16 data: Data) -> [Float] {
        let count = data.count / 2
        var samples = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            for index in 0..<count {
                let low = UInt16(raw[index * 2])
                let high = UInt16(raw[index * 2 + 1])
                let value = Int16(bitPattern: low | (high << 8))
                samples[index] = Float(value) / 32768
            }
        }
        return samples
    }

    /// A mono 16-bit PCM WAV file.
    static func wavData(samples: [Float], sampleRate: Int) -> Data {
        let pcm = pcm16Data(from: samples)
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + pcm.count))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))            // PCM chunk size
        append(UInt16(1))             // PCM format
        append(UInt16(1))             // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2)) // byte rate
        append(UInt16(2))             // block align
        append(UInt16(16))            // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(pcm.count))
        data.append(pcm)
        return data
    }

    static func rmsLevel(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }
}

enum AudioCaptureError: LocalizedError {
    case microphoneDenied
    case noInputDevice
    case converterUnavailable
    case engineFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "TinyAI has no access to the microphone. Allow it in System Settings → Privacy & Security → Microphone."
        case .noInputDevice:
            return "No microphone is available."
        case .converterUnavailable:
            return "The microphone format can't be converted for transcription."
        case .engineFailed(let message):
            return "The microphone could not start: \(message)"
        }
    }
}

enum MicrophonePermission {
    static var isGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static var isUndetermined: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
    }

    static func request(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }
}

/// Captures the default input device and delivers mono float samples at the
/// requested rate.  Every recorded sample is also kept so a file-based
/// transcriber can use the whole utterance when recording stops.
nonisolated final class AudioCapture: @unchecked Sendable {
    typealias SampleHandler = @Sendable ([Float]) -> Void

    /// Ten minutes is the longest single recording TinyAI keeps.
    static let maximumDuration: TimeInterval = 600

    let sampleRate: Double
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var recorded: [Float] = []
    private var running = false
    private var level: Float = 0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    /// The latest input level (RMS, 0…1).
    var currentLevel: Float {
        lock.lock(); defer { lock.unlock() }
        return level
    }

    /// All samples captured since `start`.
    var recordedSamples: [Float] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    var recordedDuration: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Double(recorded.count) / sampleRate
    }

    /// Start capture.  `voiceProcessing` enables Apple's echo cancellation,
    /// which keeps the live session from hearing its own voice.
    func start(voiceProcessing: Bool = false, onSamples: @escaping SampleHandler) throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        if voiceProcessing {
            try? input.setVoiceProcessingEnabled(true)
        }
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioCaptureError.noInputDevice
        }
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                               channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioCaptureError.converterUnavailable
        }
        converter.downmix = true

        lock.lock()
        recorded = []
        recorded.reserveCapacity(Int(sampleRate * 30))
        level = 0
        lock.unlock()

        let ratio = sampleRate / inputFormat.sampleRate
        let maximumSamples = Int(sampleRate * Self.maximumDuration)
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
            guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
            var consumed = false
            var error: NSError?
            converter.convert(to: converted, error: &error) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let channel = converted.floatChannelData?[0], converted.frameLength > 0 else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
            let rms = AudioCoding.rmsLevel(samples)

            self.lock.lock()
            let accepted = self.recorded.count < maximumSamples
            if accepted { self.recorded.append(contentsOf: samples) }
            self.level = rms
            self.lock.unlock()

            if accepted { onSamples(samples) }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioCaptureError.engineFailed(error.localizedDescription)
        }
        lock.lock(); running = true; lock.unlock()
    }

    /// Stop capture and return every recorded sample.
    @discardableResult
    func stop() -> [Float] {
        lock.lock()
        let wasRunning = running
        running = false
        lock.unlock()
        if wasRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        return recordedSamples
    }
}
