// CodeWatch：把监控 hooks 装进 Claude Code 的 settings.json。
// 安装思路来自 CodeIsland (MIT) 的 ConfigInstaller.swift，做了三点收窄：
//   - 只接 Claude Code（Codex 走零配置的 transcript 发现，不动 ~/.codex/config.toml）
//   - 不装 PermissionRequest hook —— 审批流完全留给 CLI 自己，悬屿只旁观
//   - hook 命令用 nc 直发 socket，不需要额外的 bridge 二进制
import CodeWatchCore
import Foundation

enum CodeWatchHookInstaller {
    static let hookId = "xuanyu-codewatch"
    private static let scriptVersion = 2

    // 全部非阻塞事件；悬屿即刻回 {}，5 秒超时只是兜底
    static let claudeEvents = [
        "SessionStart", "SessionEnd", "UserPromptSubmit",
        "PreToolUse", "PostToolUse", "Stop",
        "SubagentStart", "SubagentStop", "Notification", "PreCompact",
    ]

    static func hookScriptPath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".xuanyu/codewatch-hook.sh").path
    }

    static func hookScriptContent(socketPath: String) -> String {
        """
        #!/bin/bash
        # xuanyu-codewatch hook v\(scriptVersion) — 悬屿会话监控，纯旁观不拦截
        SOCK="\(socketPath)"
        [ -S "$SOCK" ] || exit 0
        cat | /usr/bin/nc -U -w 2 "$SOCK" > /dev/null 2>&1 || true
        exit 0
        """
    }

    /// settings.json 里挂到每个事件下的条目
    static func hookEntry() -> [String: Any] {
        [
            "matcher": "",
            "hooks": [[
                "type": "command",
                "command": hookScriptPath(),
                "timeout": 5,
            ] as [String: Any]],
        ]
    }

    static func isManagedEntry(_ entry: [String: Any]) -> Bool {
        guard let hooks = entry["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains { item in
            guard let command = item["command"] as? String else { return false }
            return command.contains("codewatch-hook") || command.contains(hookId)
        }
    }

    static func isInstalled(settingsPath: String = ClaudeConfigPaths.settingsPath()) -> Bool {
        guard let data = FileManager.default.contents(atPath: settingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else { return false }
        guard let entries = hooks["SessionStart"] as? [[String: Any]] else { return false }
        return entries.contains(where: isManagedEntry)
    }

    /// 纯函数：在现有 hooks 字典上装/卸本应用的条目，别人的 hooks 原样保留。
    static func updatedHooksDictionary(
        existing: [String: Any],
        installing: Bool
    ) -> [String: Any] {
        var hooks = existing
        for event in claudeEvents {
            var entries = (hooks[event] as? [[String: Any]]) ?? []
            entries.removeAll { isManagedEntry($0) }
            if installing {
                entries.append(hookEntry())
            }
            if entries.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = entries
            }
        }
        return hooks
    }

    static func install(
        settingsPath: String = ClaudeConfigPaths.settingsPath(),
        scriptPath: String = CodeWatchHookInstaller.hookScriptPath()
    ) throws {
        try writeHookScript(to: scriptPath)
        try mutateSettings(at: settingsPath, installing: true)
    }

    static func uninstall(
        settingsPath: String = ClaudeConfigPaths.settingsPath(),
        scriptPath: String = CodeWatchHookInstaller.hookScriptPath()
    ) throws {
        try mutateSettings(at: settingsPath, installing: false)
        try? FileManager.default.removeItem(atPath: scriptPath)
    }

    private static func writeHookScript(to path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let content = hookScriptContent(socketPath: CodeWatchSocketServer.defaultSocketPath())
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    private static func mutateSettings(at settingsPath: String, installing: Bool) throws {
        let fm = FileManager.default
        var source = "{}"
        if let data = fm.contents(atPath: settingsPath) {
            guard let text = String(data: data, encoding: .utf8) else {
                throw CodeWatchInstallError.unreadableSettings
            }
            // 现有文件必须是合法 JSON 才动它——解析失败宁可报错也不覆盖用户配置
            guard (try? JSONSerialization.jsonObject(with: data)) != nil else {
                throw CodeWatchInstallError.invalidSettingsJSON
            }
            source = text
        }

        let parsed = (try? JSONSerialization.jsonObject(
            with: Data(source.utf8))) as? [String: Any] ?? [:]
        let existingHooks = (parsed["hooks"] as? [String: Any]) ?? [:]
        let updated = updatedHooksDictionary(existing: existingHooks, installing: installing)

        let newSource: String?
        if updated.isEmpty {
            newSource = JSONMinimalEditor.deleteTopLevelKey(in: source, key: "hooks") ?? source
        } else {
            newSource = JSONMinimalEditor.setTopLevelValue(in: source, key: "hooks", value: updated)
        }
        guard let newSource else { throw CodeWatchInstallError.editFailed }

        let dir = (settingsPath as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try newSource.write(toFile: settingsPath, atomically: true, encoding: .utf8)
    }
}

enum CodeWatchInstallError: LocalizedError {
    case unreadableSettings
    case invalidSettingsJSON
    case editFailed

    var errorDescription: String? {
        switch self {
        case .unreadableSettings: return "settings.json 无法按 UTF-8 读取"
        case .invalidSettingsJSON: return "settings.json 不是合法 JSON，已放弃写入以保护现有配置"
        case .editFailed: return "settings.json 最小化编辑失败"
        }
    }
}
