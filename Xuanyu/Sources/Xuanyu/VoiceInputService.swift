import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import Observation
import Speech

enum VoiceInputState: Equatable {
    case idle
    case arming
    case preparing
    case permission
    case recording
    case transcribing
    case reviewing
    case submitted
    case error
}

@MainActor
@Observable
final class VoiceInputService {
    var state: VoiceInputState = .idle
    var transcript = ""
    var statusMessage = ""
    var errorMessage = ""
    var armingProgress: Double = 0
    var inputMonitoringAuthorized = true
    var activeBackend: VoiceRecognitionBackend = .apple
    var waveformLevels = [Double](repeating: 0.08, count: 26)
    var config: VoiceInputConfig
    let modelManager: VoiceModelManager

    @ObservationIgnored private let audioEngine = AVAudioEngine()
    @ObservationIgnored private var recognizerBackend: VoiceRecognizerBackend?
    @ObservationIgnored private var pendingStartID: UUID?
    @ObservationIgnored private var isCapturingAudio = false
    @ObservationIgnored private var hasInstalledAudioTap = false
    @ObservationIgnored private var stateResetTask: Task<Void, Never>?
    @ObservationIgnored private var startSound: NSSound?
    @ObservationIgnored private var endSound: NSSound?
    @ObservationIgnored private var inputMonitoringPermissionRequester: (() -> Void)?
    private var permissionRevision = 0

    init() {
        config = VoiceInputConfigStore.load()
        modelManager = VoiceModelManager()
        loadSounds()
    }

    var isActive: Bool {
        switch state {
        case .preparing, .permission, .recording, .transcribing, .reviewing:
            return true
        default:
            return false
        }
    }

    var shouldDisplay: Bool {
        state != .idle
    }

    var prefersLargeHUD: Bool {
        switch state {
        case .preparing, .permission, .recording, .transcribing, .reviewing, .submitted, .error:
            return true
        case .idle, .arming:
            return false
        }
    }

    var displayText: String {
        switch state {
        case .idle:
            return ""
        case .arming:
            return "继续按住 Command"
        case .preparing:
            return statusMessage.isEmpty ? "正在准备麦克风…" : statusMessage
        case .permission:
            return statusMessage.isEmpty ? "需要系统权限" : statusMessage
        case .recording:
            let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "正在听，松开 Command 发送" : text
        case .transcribing:
            return "正在识别…"
        case .reviewing:
            let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "请审核识别内容" : text
        case .submitted:
            return "已发送给 Agent"
        case .error:
            return errorMessage.isEmpty ? "语音输入失败" : errorMessage
        }
    }

    var selectedBackend: VoiceRecognitionBackend {
        config.backend
    }

    var effectiveBackend: VoiceRecognitionBackend {
        switch config.backend {
        case .apple:
            return .apple
        case .senseVoiceSmall where modelManager.isReady:
            return .senseVoiceSmall
        case .senseVoiceSmall:
            return .apple
        case .localZipformer where LegacyZipformerModel.paths != nil:
            return .localZipformer
        case .localZipformer:
            return .apple
        }
    }

    var backendStatusText: String {
        if config.backend == .senseVoiceSmall, !modelManager.isReady {
            return "SenseVoice 未就绪，录音时使用 Apple"
        }
        if config.backend == .localZipformer, LegacyZipformerModel.paths == nil {
            return "旧 Zipformer 未就绪，录音时使用 Apple"
        }
        return effectiveBackend.subtitle
    }

    var microphonePermissionText: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: "麦克风：已允许"
        case .notDetermined: "麦克风：首次录音时询问"
        case .denied: "麦克风：已拒绝"
        case .restricted: "麦克风：受系统限制"
        @unknown default: "麦克风：未知"
        }
    }

    var speechPermissionText: String {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: "Apple 语音识别：已允许"
        case .notDetermined: "Apple 语音识别：首次使用时询问"
        case .denied: "Apple 语音识别：已拒绝"
        case .restricted: "Apple 语音识别：受系统限制"
        @unknown default: "Apple 语音识别：未知"
        }
    }

    var inputMonitoringPermissionText: String {
        inputMonitoringAuthorized ? "输入监控：已允许" : "输入监控：需要授权"
    }

    func setBackend(_ backend: VoiceRecognitionBackend) {
        config.backend = backend
        saveConfig()
    }

    func setSoundsEnabled(_ enabled: Bool) {
        config.soundsEnabled = enabled
        saveConfig()
    }

    func setInputMonitoringPermissionRequester(_ requester: @escaping () -> Void) {
        inputMonitoringPermissionRequester = requester
    }

    func downloadLocalModel() async {
        if await modelManager.download() {
            config.backend = .senseVoiceSmall
            config.localModelRevision = VoiceModelManager.modelRevision
            saveConfig()
        }
    }

    func deleteLocalModel() {
        modelManager.deleteModel()
    }

    func beginArming() {
        guard state != .reviewing else { return }
        guard inputMonitoringAuthorized else {
            showPermission("需要开启输入监控才能监听 Command")
            return
        }
        stateResetTask?.cancel()
        errorMessage = ""
        statusMessage = ""
        transcript = ""
        armingProgress = 0
        state = .arming
    }

    func updateArmingProgress(_ progress: Double) {
        guard state == .arming else { return }
        armingProgress = min(max(progress, 0), 1)
    }

    func cancelArming() {
        guard state == .arming else { return }
        armingProgress = 0
        state = .idle
    }

    func setInputMonitoringAuthorized(_ authorized: Bool) {
        inputMonitoringAuthorized = authorized
        permissionRevision &+= 1
        if !authorized {
            showPermission("需要开启输入监控才能监听 Command")
        } else if state == .permission,
                  statusMessage.contains("输入监控")
        {
            state = .idle
            statusMessage = ""
        }
    }

    func startRecording() async -> Bool {
        guard state == .arming || !isActive else { return false }
        stateResetTask?.cancel()
        state = .preparing
        statusMessage = "正在准备麦克风…"
        transcript = ""
        waveformLevels = [Double](repeating: 0.08, count: 26)

        let startID = UUID()
        pendingStartID = startID

        let microphoneAuthorized = await requestMicrophoneAuthorization()
        guard pendingStartID == startID else { return false }
        guard microphoneAuthorized else {
            pendingStartID = nil
            showPermission("请在系统设置中允许悬屿使用麦克风")
            return false
        }

        activeBackend = effectiveBackend
        if activeBackend == .apple {
            state = .permission
            statusMessage = "正在确认 Apple 语音识别权限…"
            let speechAuthorized = await requestSpeechAuthorization()
            guard pendingStartID == startID else { return false }
            guard speechAuthorized else {
                pendingStartID = nil
                showPermission("请允许 Apple 语音识别，或下载本地模型")
                return false
            }
        } else {
            state = .preparing
            statusMessage = activeBackend == .senseVoiceSmall
                ? "正在加载本地 SenseVoice…"
                : "正在加载本地 Zipformer…"
        }

        let backend: VoiceRecognizerBackend
        switch activeBackend {
        case .apple:
            backend = AppleVoiceRecognizerBackend()
        case .senseVoiceSmall:
            guard let paths = modelManager.paths else {
                pendingStartID = nil
                showError("SenseVoice 模型不完整")
                return false
            }
            backend = SenseVoiceSmallRecognizerBackend(paths: paths)
        case .localZipformer:
            guard let paths = LegacyZipformerModel.paths else {
                pendingStartID = nil
                showError("本地语音模型不完整")
                return false
            }
            backend = LocalZipformerVoiceRecognizerBackend(paths: paths)
        }
        backend.onPartialResult = { [weak self] text in
            Task { @MainActor in
                guard let self,
                      self.state == .recording || self.state == .transcribing
                else {
                    return
                }
                self.transcript = text
            }
        }
        backend.onAudioLevel = { [weak self] level in
            Task { @MainActor in
                self?.appendWaveformLevel(level)
            }
        }
        backend.onError = { [weak self] error in
            Task { @MainActor in
                guard let self,
                      self.state == .recording || self.state == .preparing
                else {
                    return
                }
                self.showError(error.localizedDescription)
            }
        }

        do {
            try await backend.start()
            guard pendingStartID == startID else {
                backend.cancel()
                return false
            }
            if backend.usesSharedAudioCapture {
                try startAudioCapture(using: backend)
            }
            recognizerBackend = backend
            pendingStartID = nil
            isCapturingAudio = true
            state = .recording
            statusMessage = ""
            playStartSound()
            return true
        } catch {
            pendingStartID = nil
            backend.cancel()
            stopAudioCapture()
            showError(error.localizedDescription)
            return false
        }
    }

    func finishRecording() async -> String? {
        pendingStartID = nil
        guard isCapturingAudio, let recognizerBackend else {
            if state == .preparing || state == .permission {
                state = .idle
            }
            return nil
        }

        stopAudioCapture()
        playEndSound()
        state = .transcribing
        let text = await recognizerBackend.finish()?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.recognizerBackend = nil

        guard let text, !text.isEmpty else {
            showError("没有识别到语音")
            return nil
        }

        transcript = text
        statusMessage = "请审核识别内容"
        state = .reviewing
        return text
    }

    func confirmReviewedTranscript() -> String? {
        stateResetTask?.cancel()
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard state == .reviewing, !text.isEmpty else { return nil }
        transcript = text
        statusMessage = ""
        state = .submitted
        scheduleIdleReset(after: .seconds(1.2))
        return text
    }

    func cancelReview() {
        guard state == .reviewing else { return }
        stateResetTask?.cancel()
        transcript = ""
        statusMessage = ""
        errorMessage = ""
        state = inputMonitoringAuthorized ? .idle : .permission
        if !inputMonitoringAuthorized {
            statusMessage = "需要开启输入监控才能监听 Command"
        }
    }

    func cancelPendingStart() {
        pendingStartID = nil
        if state == .preparing || state == .permission {
            recognizerBackend?.cancel()
            recognizerBackend = nil
            stopAudioCapture()
            state = inputMonitoringAuthorized ? .idle : .permission
            statusMessage = inputMonitoringAuthorized ? "" : "需要开启输入监控才能监听 Command"
        }
    }

    func cancelRecording() {
        pendingStartID = nil
        stateResetTask?.cancel()
        stopAudioCapture()
        recognizerBackend?.cancel()
        recognizerBackend = nil
        transcript = ""
        armingProgress = 0
        state = inputMonitoringAuthorized ? .idle : .permission
        statusMessage = inputMonitoringAuthorized ? "" : "需要开启输入监控才能监听 Command"
    }

    func openInputMonitoringSettings() {
        openPrivacySettings("Privacy_ListenEvent")
    }

    func requestInputMonitoringPermission() {
        inputMonitoringPermissionRequester?()
        permissionRevision &+= 1
        if !inputMonitoringAuthorized {
            showPermission("请在系统设置中允许悬屿进行输入监控")
        }
    }

    @discardableResult
    func requestMicrophonePermission() async -> Bool {
        stateResetTask?.cancel()
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            showPermission("正在申请麦克风权限…")
        }
        let authorized = await requestMicrophoneAuthorization()
        permissionRevision &+= 1
        if authorized {
            if state == .permission, statusMessage.contains("麦克风") {
                state = inputMonitoringAuthorized ? .idle : .permission
                statusMessage = inputMonitoringAuthorized ? "" : "需要开启输入监控才能监听 Command"
            }
        } else {
            showPermission("请在系统设置中允许悬屿使用麦克风")
        }
        return authorized
    }

    @discardableResult
    func requestAppleSpeechPermission() async -> Bool {
        stateResetTask?.cancel()
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            showPermission("正在申请 Apple 语音识别权限…")
        }
        let authorized = await requestSpeechAuthorization()
        permissionRevision &+= 1
        if authorized {
            if state == .permission, statusMessage.contains("语音识别") {
                state = inputMonitoringAuthorized ? .idle : .permission
                statusMessage = inputMonitoringAuthorized ? "" : "需要开启输入监控才能监听 Command"
            }
        } else {
            showPermission("请允许 Apple 语音识别，或使用本地模型")
        }
        return authorized
    }

    func openMicrophoneSettings() {
        openPrivacySettings("Privacy_Microphone")
    }

    func openSpeechRecognitionSettings() {
        openPrivacySettings("Privacy_SpeechRecognition")
    }

    func debugShowArming() {
        inputMonitoringAuthorized = true
        beginArming()
        updateArmingProgress(0.72)
    }

    func debugShowRecording() {
        inputMonitoringAuthorized = true
        activeBackend = .senseVoiceSmall
        transcript = "帮我整理今天需要完成的任务"
        waveformLevels = [
            0.12, 0.28, 0.48, 0.76, 0.36, 0.62, 0.92, 0.54, 0.34,
            0.72, 0.46, 0.84, 0.58, 0.31, 0.68, 0.95, 0.44, 0.75,
            0.38, 0.63, 0.88, 0.52, 0.27, 0.59, 0.79, 0.42,
        ]
        state = .recording
    }

    func debugShowReviewing() {
        inputMonitoringAuthorized = true
        activeBackend = .senseVoiceSmall
        transcript = "帮我整理今天需要完成的任务，并列出优先级"
        statusMessage = "请审核识别内容"
        state = .reviewing
    }

    func debugDismiss() {
        cancelRecording()
    }

    private func startAudioCapture(using backend: VoiceRecognizerBackend) throws {
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              inputFormat.channelCount > 0,
              let normalizer = VoiceAudioNormalizer(inputFormat: inputFormat)
        else {
            throw VoiceInputError.noMicrophoneInput
        }

        if hasInstalledAudioTap {
            inputNode.removeTap(onBus: 0)
            hasInstalledAudioTap = false
        }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let samples = normalizer.normalize(buffer), !samples.isEmpty else { return }
            backend.acceptAudio(samples: samples, sampleRate: 16_000)
            let level = Self.audioLevel(samples)
            Task { @MainActor in
                self?.appendWaveformLevel(level)
            }
        }
        hasInstalledAudioTap = true
        audioEngine.prepare()
        try audioEngine.start()
    }

    private func stopAudioCapture() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        if hasInstalledAudioTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInstalledAudioTap = false
        }
        isCapturingAudio = false
    }

    private func appendWaveformLevel(_ level: Double) {
        guard state == .recording else { return }
        waveformLevels.append(level)
        if waveformLevels.count > 26 {
            waveformLevels.removeFirst(waveformLevels.count - 26)
        }
    }

    nonisolated private static func audioLevel(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0.05 }
        let sum = samples.reduce(0.0) { partial, sample in
            partial + Double(sample * sample)
        }
        let rms = sqrt(sum / Double(samples.count))
        return min(1, max(0.06, rms * 9))
    }

    private func showPermission(_ message: String) {
        stateResetTask?.cancel()
        statusMessage = message
        errorMessage = ""
        state = .permission
    }

    private func showError(_ message: String) {
        stateResetTask?.cancel()
        errorMessage = message
        statusMessage = ""
        state = .error
        scheduleIdleReset(after: .seconds(4))
    }

    private func scheduleIdleReset(after duration: Duration) {
        stateResetTask?.cancel()
        stateResetTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
            if self.inputMonitoringAuthorized {
                self.state = .idle
                self.statusMessage = ""
                self.errorMessage = ""
                self.transcript = ""
                self.armingProgress = 0
            }
        }
    }

    private func saveConfig() {
        try? VoiceInputConfigStore.save(config)
    }

    private func requestSpeechAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func requestMicrophoneAuthorization() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func openPrivacySettings(_ anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func loadSounds() {
        if let url = Bundle.module.url(forResource: "voice-start", withExtension: "wav") {
            startSound = NSSound(contentsOf: url, byReference: true)
        }
        if let url = Bundle.module.url(forResource: "voice-end", withExtension: "wav") {
            endSound = NSSound(contentsOf: url, byReference: true)
        }
    }

    private func playStartSound() {
        guard config.soundsEnabled else { return }
        startSound?.stop()
        startSound?.play()
    }

    private func playEndSound() {
        guard config.soundsEnabled else { return }
        endSound?.stop()
        endSound?.play()
    }
}

private enum VoiceInputError: LocalizedError {
    case noMicrophoneInput

    var errorDescription: String? {
        switch self {
        case .noMicrophoneInput:
            return "没有可用的麦克风输入"
        }
    }
}
