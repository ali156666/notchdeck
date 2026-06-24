import CryptoKit
import Foundation
import Observation

enum VoiceModelDownloadState: Equatable {
    case notDownloaded
    case downloading
    case ready
    case error
}

struct ZipformerVoiceModelPaths: Equatable {
    let encoder: URL
    let decoder: URL
    let joiner: URL
    let tokens: URL
}

struct SenseVoiceModelPaths: Equatable {
    let model: URL
    let tokens: URL
}

private struct VoiceModelFile: Sendable {
    let name: String
    let size: Int64
    let sha256: String
}

@MainActor
@Observable
final class VoiceModelManager {
    nonisolated static let modelRevision = "2365baeacb507f821a0c8120fcee3d484dba7a07"
    nonisolated static let modelRepository = "csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"
    nonisolated static let totalDownloadSize: Int64 = 239_549_735

    var state: VoiceModelDownloadState = .notDownloaded
    var progress: Double = 0
    var downloadedBytes: Int64 = 0
    var errorMessage = ""

    @ObservationIgnored private var downloadTask: Task<Void, Never>?

    private static let files = [
        VoiceModelFile(
            name: "model.int8.onnx",
            size: 239_233_841,
            sha256: "c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51"
        ),
        VoiceModelFile(
            name: "tokens.txt",
            size: 315_894,
            sha256: "f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc"
        ),
    ]

    static var modelDirectory: URL {
        AppSupportDirectory.voice
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("sensevoice-small-zh-en-yue-int8", isDirectory: true)
    }

    init() {
        refresh()
    }

    var isReady: Bool {
        state == .ready
    }

    var statusText: String {
        switch state {
        case .notDownloaded:
            return "SenseVoice 模型未下载（239.5 MB）"
        case .downloading:
            return "正在下载 \(formattedBytes(downloadedBytes)) / \(formattedBytes(Self.totalDownloadSize))"
        case .ready:
            return "SenseVoice 模型已就绪（239.5 MB）"
        case .error:
            return errorMessage.isEmpty ? "模型下载失败" : errorMessage
        }
    }

    var paths: SenseVoiceModelPaths? {
        guard isReady else { return nil }
        return SenseVoiceModelPaths(
            model: Self.modelDirectory.appendingPathComponent(Self.files[0].name),
            tokens: Self.modelDirectory.appendingPathComponent(Self.files[1].name)
        )
    }

    func refresh() {
        guard downloadTask == nil else { return }
        if Self.validateInstalledModel() {
            state = .ready
            progress = 1
            downloadedBytes = Self.totalDownloadSize
            errorMessage = ""
        } else {
            state = .notDownloaded
            progress = 0
            downloadedBytes = 0
        }
    }

    func download() async -> Bool {
        if isReady { return true }
        if let downloadTask {
            await downloadTask.value
            return isReady
        }

        state = .downloading
        progress = 0
        downloadedBytes = 0
        errorMessage = ""

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                try await performDownload()
                state = .ready
                progress = 1
                downloadedBytes = Self.totalDownloadSize
            } catch {
                Self.removeIncompleteDownloads()
                if Task.isCancelled || error is CancellationError ||
                    (error as? URLError)?.code == .cancelled
                {
                    state = .notDownloaded
                    progress = 0
                    downloadedBytes = 0
                } else {
                    state = .error
                    errorMessage = "模型下载失败：\(error.localizedDescription)"
                }
            }
            downloadTask = nil
        }
        downloadTask = task
        await task.value
        return isReady
    }

    func cancelDownload() {
        downloadTask?.cancel()
    }

    func deleteModel() {
        cancelDownload()
        try? FileManager.default.removeItem(at: Self.modelDirectory)
        Self.removeIncompleteDownloads()
        state = .notDownloaded
        progress = 0
        downloadedBytes = 0
        errorMessage = ""
    }

    private func performDownload() async throws {
        let fileManager = FileManager.default
        let modelsRoot = Self.modelDirectory.deletingLastPathComponent()
        try fileManager.createDirectory(at: modelsRoot, withIntermediateDirectories: true)

        let temporaryDirectory = modelsRoot.appendingPathComponent(
            ".sensevoice-small.download-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        var completedBytes: Int64 = 0
        for file in Self.files {
            try Task.checkCancellation()
            let sourceURL = Self.downloadURL(for: file)
            let destinationURL = temporaryDirectory.appendingPathComponent(file.name)
            let downloader = VoiceFileDownloader()
            try await downloader.download(
                from: sourceURL,
                to: destinationURL,
                expectedSize: file.size
            ) { [weak self] fileBytes in
                Task { @MainActor in
                    guard let self else { return }
                    self.downloadedBytes = completedBytes + fileBytes
                    self.progress = min(1, Double(self.downloadedBytes) / Double(Self.totalDownloadSize))
                }
            }

            try Task.checkCancellation()
            guard try Self.sha256(of: destinationURL) == file.sha256 else {
                throw VoiceModelError.checksumMismatch(file.name)
            }
            completedBytes += file.size
            downloadedBytes = completedBytes
            progress = min(1, Double(completedBytes) / Double(Self.totalDownloadSize))
        }

        guard Self.validateModel(in: temporaryDirectory) else {
            throw VoiceModelError.incompleteModel
        }

        if fileManager.fileExists(atPath: Self.modelDirectory.path) {
            try fileManager.removeItem(at: Self.modelDirectory)
        }
        try fileManager.moveItem(at: temporaryDirectory, to: Self.modelDirectory)
    }

    private static func downloadURL(for file: VoiceModelFile) -> URL {
        URL(string:
            "https://huggingface.co/\(modelRepository)/resolve/\(modelRevision)/\(file.name)?download=true"
        )!
    }

    private static func validateInstalledModel() -> Bool {
        validateModel(in: modelDirectory)
    }

    private static func validateModel(in directory: URL) -> Bool {
        files.allSatisfy { file in
            let url = directory.appendingPathComponent(file.name)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber,
                  size.int64Value == file.size,
                  let digest = try? sha256(of: url)
            else {
                return false
            }
            return digest == file.sha256
        }
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func removeIncompleteDownloads() {
        let modelsRoot = modelDirectory.deletingLastPathComponent()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: modelsRoot,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for entry in entries where entry.lastPathComponent.hasPrefix(".sensevoice-small.download-") {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    private func formattedBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

enum LegacyZipformerModel {
    private static let directory = AppSupportDirectory.voice
        .appendingPathComponent("models", isDirectory: true)
        .appendingPathComponent("zipformer-small-zh", isDirectory: true)

    private static let encoderName = "encoder-epoch-30-avg-9-chunk-16-left-64.int8.onnx"
    private static let decoderName = "decoder-epoch-30-avg-9-chunk-16-left-64.int8.onnx"
    private static let joinerName = "joiner-epoch-30-avg-9-chunk-16-left-64.int8.onnx"
    private static let tokensName = "tokens.txt"

    static var paths: ZipformerVoiceModelPaths? {
        let paths = ZipformerVoiceModelPaths(
            encoder: directory.appendingPathComponent(encoderName),
            decoder: directory.appendingPathComponent(decoderName),
            joiner: directory.appendingPathComponent(joinerName),
            tokens: directory.appendingPathComponent(tokensName)
        )
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: paths.encoder.path),
              fileManager.fileExists(atPath: paths.decoder.path),
              fileManager.fileExists(atPath: paths.joiner.path),
              fileManager.fileExists(atPath: paths.tokens.path)
        else {
            return nil
        }
        return paths
    }
}

private enum VoiceModelError: LocalizedError {
    case invalidResponse
    case unexpectedSize(String)
    case checksumMismatch(String)
    case incompleteModel

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "服务器返回无效响应"
        case let .unexpectedSize(name):
            return "\(name) 文件大小不匹配"
        case let .checksumMismatch(name):
            return "\(name) 校验失败"
        case .incompleteModel:
            return "模型文件不完整"
        }
    }
}

private final class VoiceFileDownloader: NSObject, URLSessionDataDelegate {
    private var session: URLSession?
    private var fileHandle: FileHandle?
    private var continuation: CheckedContinuation<Void, Error>?
    private var destinationURL: URL?
    private var expectedSize: Int64 = 0
    private var receivedSize: Int64 = 0
    private var progressHandler: ((Int64) -> Void)?
    private var responseAccepted = false

    func download(
        from sourceURL: URL,
        to destinationURL: URL,
        expectedSize: Int64,
        onProgress: @escaping (Int64) -> Void
    ) async throws {
        self.destinationURL = destinationURL
        self.expectedSize = expectedSize
        progressHandler = onProgress
        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        fileHandle = try FileHandle(forWritingTo: destinationURL)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 600
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                session.dataTask(with: sourceURL).resume()
            }
        } onCancel: {
            self.session?.invalidateAndCancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode)
        else {
            completionHandler(.cancel)
            finish(.failure(VoiceModelError.invalidResponse))
            return
        }
        responseAccepted = true
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard responseAccepted else { return }
        do {
            try fileHandle?.write(contentsOf: data)
            receivedSize += Int64(data.count)
            progressHandler?(receivedSize)
        } catch {
            session.invalidateAndCancel()
            finish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(.failure(error))
            return
        }
        guard receivedSize == expectedSize else {
            finish(.failure(VoiceModelError.unexpectedSize(destinationURL?.lastPathComponent ?? "模型")))
            return
        }
        finish(.success(()))
    }

    private func finish(_ result: Result<Void, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        try? fileHandle?.close()
        fileHandle = nil
        session?.finishTasksAndInvalidate()
        session = nil
        continuation.resume(with: result)
    }
}
