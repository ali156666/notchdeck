// CodeWatch：像素吉祥物路由与动画环境。
// 精简自 CodeIsland (MIT) 的 MascotView.swift —— 上游按 20+ 家 CLI 路由，
// 这里只保留 Claude(Clawd) 与 Codex(Dex) 两只；速度从设置读取的逻辑
// 简化为 UserDefaults 常量键。
import CodeWatchCore
import SwiftUI

/// 吉祥物动画只认这五个状态；直接复用监控状态机的枚举。
typealias MascotAgentStatus = CodeWatchCore.AgentStatus

// MARK: - 动画速度环境（Clawd/Dex 的 MascotTimeline 读取）

private struct MascotSpeedKey: EnvironmentKey {
    static let defaultValue: Double = 1.0
}

extension EnvironmentValues {
    var mascotSpeed: Double {
        get { self[MascotSpeedKey.self] }
        set { self[MascotSpeedKey.self] = newValue }
    }
}

/// 按会话来源渲染对应的像素吉祥物。
struct CodeWatchMascotView: View {
    let source: String
    let status: MascotAgentStatus
    var size: CGFloat = 27
    var pet: CodexPet?
    @ObservedObject private var animationGate = MascotAnimationGate.shared

    var body: some View {
        Group {
            if let pet {
                CodexPetSpriteView(pet: pet, status: status, size: size)
            } else {
                switch source {
                case "codex":
                    DexView(status: status, size: size)
                default:
                    ClawdView(status: status, size: size)
                }
            }
        }
        .environment(\.mascotSpeed, 1.0)
        .environment(\.mascotAnimationsActive, animationGate.animationsActive)
        .environment(\.mascotAnimationEpoch, animationGate.epoch)
    }
}
