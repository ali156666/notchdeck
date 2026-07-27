// CodeWatch：8-bit 事件音效。
// 精简自 CodeIsland (MIT) 的 SoundManager.swift；WAV 资源同样来自上游
// （Sources/Xuanyu/Resources/CodeWatchSounds/8bit_*.wav）。
// 上游按事件细分了多个开关和免打扰时段，这里收敛成一个总开关。
import AppKit

@MainActor
final class CodeWatchSoundPlayer {
    static let shared = CodeWatchSoundPlayer()
    static let enabledKey = "codewatch.soundEnabled"

    /// 事件名 → 音效文件名（同上游 SoundManager.eventSounds）
    static let eventSounds: [String: String] = [
        "SessionStart": "8bit_start",
        "TaskRoundComplete": "8bit_complete",
        "Stop": "8bit_complete",
        "PostToolUseFailure": "8bit_error",
        "PermissionRequest": "8bit_approval",
        "Notification": "8bit_approval",
        "UserPromptSubmit": "8bit_submit",
    ]

    private var soundCache: [String: NSSound] = [:]

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    private init() {}

    func handleEvent(_ eventName: String) {
        guard isEnabled, let name = Self.eventSounds[eventName] else { return }
        play(name)
    }

    func play(_ name: String) {
        if let cached = soundCache[name] {
            cached.stop()
            cached.play()
            return
        }
        guard let url = Self.soundURL(name), let sound = NSSound(contentsOf: url, byReference: true) else { return }
        soundCache[name] = sound
        sound.play()
    }

    /// 与 AgentService 的资源查找同款 fallback：app bundle → SwiftPM bundle → 源码目录。
    private static func soundURL(_ name: String) -> URL? {
        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent("CodeWatchSounds/\(name).wav"),
            Bundle.module.resourceURL?.appendingPathComponent("Resources/CodeWatchSounds/\(name).wav"),
            Bundle.module.resourceURL?.appendingPathComponent("CodeWatchSounds/\(name).wav"),
        ]
        for candidate in candidates {
            if let candidate, FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
