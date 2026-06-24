import AVFoundation
import Foundation
import SherpaOnnx
import Speech

protocol VoiceRecognizerBackend: AnyObject {
    var onPartialResult: ((String) -> Void)? { get set }
    var onAudioLevel: ((Double) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
    var usesSharedAudioCapture: Bool { get }
    func start() async throws
    func acceptAudio(samples: [Float], sampleRate: Int32)
    func finish() async -> String?
    func cancel()
}

enum VoiceRecognizerError: LocalizedError {
    case appleRecognizerUnavailable
    case localModelUnavailable
    case localRecognizerCreationFailed
    case localStreamCreationFailed
    case offlineStreamCreationFailed

    var errorDescription: String? {
        switch self {
        case .appleRecognizerUnavailable:
            return "Apple 语音识别服务不可用"
        case .localModelUnavailable:
            return "本地语音模型不完整"
        case .localRecognizerCreationFailed:
            return "本地语音识别器加载失败"
        case .localStreamCreationFailed:
            return "本地语音会话创建失败"
        case .offlineStreamCreationFailed:
            return "本地离线识别会话创建失败"
        }
    }
}

final class AppleVoiceRecognizerBackend: VoiceRecognizerBackend {
    var onPartialResult: ((String) -> Void)?
    var onAudioLevel: ((Double) -> Void)?
    var onError: ((Error) -> Void)?
    let usesSharedAudioCapture = true

    private let lock = NSLock()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var finishContinuation: CheckedContinuation<String?, Never>?
    private var finishTimeoutTask: Task<Void, Never>?
    private var latestTranscript = ""
    private var isFinishing = false

    func start() async throws {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")),
              recognizer.isAvailable
        else {
            throw VoiceRecognizerError.appleRecognizerUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = false
        request.contextualStrings = [
            "Agent", "Command", "Codex", "Claude", "ChatGPT", "Gemini",
            "OpenAI", "API", "MCP", "Swift", "SwiftUI", "Xcode",
            "GitHub", "Hugging Face", "Zipformer", "sherpa-onnx",
            "灵动岛", "悬屿", "模型配置", "语音输入",
        ]
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }

        lock.withLock {
            recognitionRequest = request
            latestTranscript = ""
            isFinishing = false
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handle(result: result, error: error)
        }
    }

    func acceptAudio(samples: [Float], sampleRate: Int32) {
        guard !samples.isEmpty,
              let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(sampleRate),
                channels: 1,
                interleaved: false
              ),
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
              ),
              let channel = buffer.floatChannelData?[0]
        else {
            return
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        channel.update(from: samples, count: samples.count)

        let request = lock.withLock { recognitionRequest }
        request?.append(buffer)
    }

    func finish() async -> String? {
        await withCheckedContinuation { continuation in
            let request = lock.withLock {
                finishContinuation = continuation
                isFinishing = true
                return recognitionRequest
            }

            finishTimeoutTask?.cancel()
            finishTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                self?.completeWithLatestTranscript()
            }
            request?.endAudio()
        }
    }

    func cancel() {
        finishTimeoutTask?.cancel()
        finishTimeoutTask = nil

        let continuation = lock.withLock {
            let continuation = finishContinuation
            finishContinuation = nil
            recognitionRequest = nil
            latestTranscript = ""
            isFinishing = false
            return continuation
        }

        recognitionTask?.cancel()
        recognitionTask = nil
        continuation?.resume(returning: nil)
    }

    private func handle(result: SFSpeechRecognitionResult?, error: Error?) {
        var transcriptToPublish: String?
        var shouldComplete = false

        lock.withLock {
            if let result {
                latestTranscript = result.bestTranscription.formattedString
                transcriptToPublish = latestTranscript
                shouldComplete = result.isFinal && isFinishing
            } else if error != nil, isFinishing {
                shouldComplete = true
            }
        }

        if let transcriptToPublish {
            onPartialResult?(transcriptToPublish)
        }
        if let error, !isFinishing {
            onError?(error)
        }
        if shouldComplete {
            completeWithLatestTranscript()
        }
    }

    private func completeWithLatestTranscript() {
        finishTimeoutTask?.cancel()
        finishTimeoutTask = nil

        let completion: (CheckedContinuation<String?, Never>, String)? = lock.withLock {
            guard let continuation = finishContinuation else { return nil }
            let result = latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            finishContinuation = nil
            recognitionRequest = nil
            isFinishing = false
            return (continuation, result)
        }
        guard let (continuation, result) = completion else { return }

        recognitionTask?.cancel()
        recognitionTask = nil
        continuation.resume(returning: result.isEmpty ? nil : result)
    }
}

final class SenseVoiceSmallRecognizerBackend: VoiceRecognizerBackend, @unchecked Sendable {
    var onPartialResult: ((String) -> Void)?
    var onAudioLevel: ((Double) -> Void)?
    var onError: ((Error) -> Void)?
    let usesSharedAudioCapture = true

    private let paths: SenseVoiceModelPaths
    private let queue = DispatchQueue(label: "com.xuanyu.voice.sensevoice", qos: .userInitiated)
    private var recognizer: OpaquePointer?
    private var samples = [Float]()
    private var isCancelled = false

    init(paths: SenseVoiceModelPaths) {
        self.paths = paths
    }

    deinit {
        if let recognizer {
            SherpaOnnxDestroyOfflineRecognizer(recognizer)
        }
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    isCancelled = false
                    samples.removeAll(keepingCapacity: true)
                    if recognizer == nil {
                        recognizer = try createRecognizer()
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func acceptAudio(samples: [Float], sampleRate: Int32) {
        guard sampleRate == 16_000, !samples.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, !self.isCancelled else { return }
            self.samples.append(contentsOf: samples)
        }
    }

    func finish() async -> String? {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self, !self.isCancelled,
                      let recognizer = self.recognizer,
                      !self.samples.isEmpty
                else {
                    continuation.resume(returning: nil)
                    return
                }

                guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else {
                    continuation.resume(returning: nil)
                    return
                }
                defer { SherpaOnnxDestroyOfflineStream(stream) }

                self.samples.withUnsafeBufferPointer { buffer in
                    guard let baseAddress = buffer.baseAddress else { return }
                    SherpaOnnxAcceptWaveformOffline(
                        stream,
                        16_000,
                        baseAddress,
                        Int32(buffer.count)
                    )
                }
                SherpaOnnxDecodeOfflineStream(recognizer, stream)

                guard let result = SherpaOnnxGetOfflineStreamResult(stream) else {
                    continuation.resume(returning: nil)
                    return
                }
                defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }

                let text = result.pointee.text.map { String(cString: $0) } ?? ""
                let normalized = Self.normalizeSenseVoiceText(text)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                self.samples.removeAll(keepingCapacity: true)
                continuation.resume(returning: normalized.isEmpty ? nil : normalized)
            }
        }
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self else { return }
            isCancelled = true
            samples.removeAll(keepingCapacity: false)
        }
    }

    private func createRecognizer() throws -> OpaquePointer {
        guard FileManager.default.fileExists(atPath: paths.model.path),
              FileManager.default.fileExists(atPath: paths.tokens.path)
        else {
            throw VoiceRecognizerError.localModelUnavailable
        }

        return try paths.model.path.withCString { model in
            try paths.tokens.path.withCString { tokens in
                try "auto".withCString { language in
                    try "cpu".withCString { provider in
                        try "greedy_search".withCString { decodingMethod in
                            var config = SherpaOnnxOfflineRecognizerConfig()
                            config.feat_config.sample_rate = 16_000
                            config.feat_config.feature_dim = 80
                            config.model_config.sense_voice.model = model
                            config.model_config.sense_voice.language = language
                            config.model_config.sense_voice.use_itn = 1
                            config.model_config.tokens = tokens
                            config.model_config.num_threads = 4
                            config.model_config.provider = provider
                            config.decoding_method = decodingMethod
                            guard let recognizer = SherpaOnnxCreateOfflineRecognizer(&config) else {
                                throw VoiceRecognizerError.localRecognizerCreationFailed
                            }
                            return recognizer
                        }
                    }
                }
            }
        }
    }

    private static func normalizeSenseVoiceText(_ text: String) -> String {
        var output = text
        let markers = [
            "<|zh|>", "<|en|>", "<|yue|>", "<|ja|>", "<|ko|>",
            "<|nospeech|>", "<|NEUTRAL|>", "<|HAPPY|>", "<|SAD|>",
            "<|ANGRY|>", "<|FEARFUL|>", "<|DISGUSTED|>", "<|SURPRISED|>",
            "<|Speech|>", "<|Applause|>", "<|BGM|>", "<|Laughter|>",
            "<|withitn|>", "<|woitn|>",
        ]
        for marker in markers {
            output = output.replacingOccurrences(of: marker, with: "")
        }
        return output
    }
}

final class LocalZipformerVoiceRecognizerBackend: VoiceRecognizerBackend, @unchecked Sendable {
    var onPartialResult: ((String) -> Void)?
    var onAudioLevel: ((Double) -> Void)?
    var onError: ((Error) -> Void)?
    let usesSharedAudioCapture = true

    private let paths: ZipformerVoiceModelPaths
    private let queue = DispatchQueue(label: "com.xuanyu.voice.zipformer", qos: .userInitiated)
    private var recognizer: OpaquePointer?
    private var stream: OpaquePointer?
    private var latestTranscript = ""
    private var isCancelled = false

    init(paths: ZipformerVoiceModelPaths) {
        self.paths = paths
    }

    deinit {
        if let stream {
            SherpaOnnxDestroyOnlineStream(stream)
        }
        if let recognizer {
            SherpaOnnxDestroyOnlineRecognizer(recognizer)
        }
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    isCancelled = false
                    latestTranscript = ""
                    if recognizer == nil {
                        recognizer = try createRecognizer()
                    }
                    if let stream {
                        SherpaOnnxDestroyOnlineStream(stream)
                    }
                    guard let recognizer,
                          let newStream = SherpaOnnxCreateOnlineStream(recognizer)
                    else {
                        throw VoiceRecognizerError.localStreamCreationFailed
                    }
                    stream = newStream
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func acceptAudio(samples: [Float], sampleRate: Int32) {
        guard !samples.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, !self.isCancelled,
                  let recognizer = self.recognizer,
                  let stream = self.stream
            else {
                return
            }
            samples.withUnsafeBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                SherpaOnnxOnlineStreamAcceptWaveform(
                    stream,
                    sampleRate,
                    baseAddress,
                    Int32(buffer.count)
                )
            }
            self.decodeAvailable(recognizer: recognizer, stream: stream)
        }
    }

    func finish() async -> String? {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self, !self.isCancelled,
                      let recognizer = self.recognizer,
                      let stream = self.stream
                else {
                    continuation.resume(returning: nil)
                    return
                }

                var tailPadding = [Float](repeating: 0, count: 6_400)
                tailPadding.withUnsafeMutableBufferPointer { buffer in
                    guard let baseAddress = buffer.baseAddress else { return }
                    SherpaOnnxOnlineStreamAcceptWaveform(stream, 16_000, baseAddress, Int32(buffer.count))
                }
                SherpaOnnxOnlineStreamInputFinished(stream)
                self.decodeAvailable(recognizer: recognizer, stream: stream)
                let text = self.currentResult(recognizer: recognizer, stream: stream)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                self.latestTranscript = text
                continuation.resume(returning: text.isEmpty ? nil : text)
            }
        }
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isCancelled = true
            self.latestTranscript = ""
            if let stream = self.stream {
                SherpaOnnxDestroyOnlineStream(stream)
                self.stream = nil
            }
        }
    }

    private func createRecognizer() throws -> OpaquePointer {
        guard FileManager.default.fileExists(atPath: paths.encoder.path),
              FileManager.default.fileExists(atPath: paths.decoder.path),
              FileManager.default.fileExists(atPath: paths.joiner.path),
              FileManager.default.fileExists(atPath: paths.tokens.path)
        else {
            throw VoiceRecognizerError.localModelUnavailable
        }

        return try paths.encoder.path.withCString { encoder in
            try paths.decoder.path.withCString { decoder in
                try paths.joiner.path.withCString { joiner in
                    try paths.tokens.path.withCString { tokens in
                        try "cpu".withCString { provider in
                            try "greedy_search".withCString { decodingMethod in
                                var config = SherpaOnnxOnlineRecognizerConfig()
                                config.feat_config.sample_rate = 16_000
                                config.feat_config.feature_dim = 80
                                config.model_config.transducer.encoder = encoder
                                config.model_config.transducer.decoder = decoder
                                config.model_config.transducer.joiner = joiner
                                config.model_config.tokens = tokens
                                config.model_config.num_threads = 2
                                config.model_config.provider = provider
                                config.decoding_method = decodingMethod
                                config.max_active_paths = 4
                                config.enable_endpoint = 0
                                guard let recognizer = SherpaOnnxCreateOnlineRecognizer(&config) else {
                                    throw VoiceRecognizerError.localRecognizerCreationFailed
                                }
                                return recognizer
                            }
                        }
                    }
                }
            }
        }
    }

    private func decodeAvailable(recognizer: OpaquePointer, stream: OpaquePointer) {
        while SherpaOnnxIsOnlineStreamReady(recognizer, stream) == 1 {
            SherpaOnnxDecodeOnlineStream(recognizer, stream)
        }
        let text = currentResult(recognizer: recognizer, stream: stream)
        guard text != latestTranscript else { return }
        latestTranscript = text
        onPartialResult?(text)
    }

    private func currentResult(recognizer: OpaquePointer, stream: OpaquePointer) -> String {
        guard let result = SherpaOnnxGetOnlineStreamResult(recognizer, stream) else {
            return latestTranscript
        }
        defer { SherpaOnnxDestroyOnlineRecognizerResult(result) }
        guard let text = result.pointee.text else { return "" }
        return String(cString: text)
    }
}

final class VoiceAudioNormalizer {
    private let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init?(inputFormat: AVAudioFormat) {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ),
        let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            return nil
        }
        self.outputFormat = outputFormat
        self.converter = converter
    }

    func normalize(_ inputBuffer: AVAudioPCMBuffer) -> [Float]? {
        let ratio = outputFormat.sampleRate / inputBuffer.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * ratio)) + 32
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: capacity
        ) else {
            return nil
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outputStatus in
            if suppliedInput {
                outputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            outputStatus.pointee = .haveData
            return inputBuffer
        }
        guard conversionError == nil,
              status != .error,
              outputBuffer.frameLength > 0,
              let channel = outputBuffer.floatChannelData?[0]
        else {
            return nil
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(outputBuffer.frameLength)))
    }
}

final class VoiceAudioNormalizerCache {
    private var cachedFormatDescription = ""
    private var cachedNormalizer: VoiceAudioNormalizer?

    func normalize(_ inputBuffer: AVAudioPCMBuffer) -> [Float]? {
        let formatDescription = Self.describe(inputBuffer.format)
        if cachedNormalizer == nil || cachedFormatDescription != formatDescription {
            cachedNormalizer = VoiceAudioNormalizer(inputFormat: inputBuffer.format)
            cachedFormatDescription = formatDescription
        }
        return cachedNormalizer?.normalize(inputBuffer)
    }

    private static func describe(_ format: AVAudioFormat) -> String {
        [
            String(format.sampleRate),
            String(format.channelCount),
            String(format.commonFormat.rawValue),
            String(format.isInterleaved),
        ].joined(separator: ":")
    }
}
