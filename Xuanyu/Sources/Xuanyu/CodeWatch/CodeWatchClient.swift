import CodeWatchCore
import Foundation

enum CodeWatchClient: String, Codable, Equatable, Sendable {
    case claudeCode
    case chatGPT
    case codex

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .chatGPT: return "ChatGPT"
        case .codex: return "Codex"
        }
    }

    var source: String {
        switch self {
        case .claudeCode: return "claude"
        case .chatGPT, .codex: return "codex"
        }
    }

    static func fallback(for source: String) -> CodeWatchClient {
        source == "codex" ? .codex : .claudeCode
    }
}

struct CodeWatchCompletion: Equatable {
    let sessionId: String
    let client: CodeWatchClient
    let projectName: String
    let message: String?
    let interrupted: Bool

    var title: String {
        "\(client.displayName)\(interrupted ? " 已停止" : " 已完成")"
    }

    var collapsedTitle: String {
        title
    }
}

extension SessionSnapshot {
    var codeWatchProjectName: String {
        guard let cwd, !cwd.isEmpty else { return "当前任务" }
        let leaf = (cwd as NSString).lastPathComponent
        return leaf.isEmpty ? "当前任务" : leaf
    }
}
