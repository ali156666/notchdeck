import Foundation

enum VoiceRecognitionBackend: String, Codable, CaseIterable, Identifiable {
    case apple
    case senseVoiceSmall
    case localZipformer

    static var allCases: [VoiceRecognitionBackend] {
        [.apple, .senseVoiceSmall]
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: "Apple"
        case .senseVoiceSmall: "本地 SenseVoice"
        case .localZipformer: "本地 Zipformer"
        }
    }

    var subtitle: String {
        switch self {
        case .apple: "准确率优先，中英混合，依赖系统语音识别权限"
        case .senseVoiceSmall: "离线高准确率，普通话/粤语/英语"
        case .localZipformer: "离线兜底，旧普通话小模型"
        }
    }
}

struct VoiceInputConfig: Codable, Equatable {
    var backend: VoiceRecognitionBackend
    var soundsEnabled: Bool
    var localModelRevision: String

    static let `default` = VoiceInputConfig(
        backend: .apple,
        soundsEnabled: true,
        localModelRevision: VoiceModelManager.modelRevision
    )
}

enum VoiceInputConfigStore {
    static var configURL: URL {
        AppSupportDirectory.voice.appendingPathComponent("config.json")
    }

    static func load() -> VoiceInputConfig {
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(VoiceInputConfig.self, from: data)
        else {
            return .default
        }
        return config
    }

    static func save(_ config: VoiceInputConfig) throws {
        try FileManager.default.createDirectory(
            at: AppSupportDirectory.voice,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: configURL, options: .atomic)
    }
}
