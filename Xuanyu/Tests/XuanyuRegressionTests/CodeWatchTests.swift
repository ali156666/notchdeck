#if DEBUG
import CodeWatchCore
import Darwin
import Foundation
@testable import Xuanyu

private struct CodeWatchTestFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

private func cwExpect(_ condition: Bool, _ message: String, line: UInt = #line) throws {
    guard condition else { throw CodeWatchTestFailure(message: "line \(line): \(message)") }
}

/// 阻塞式 unix socket 客户端：连接 → 发送 → 半关闭 → 读响应，模拟 hook 脚本里的 nc。
private func sendToUnixSocket(path: String, payload: Data) -> Data? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let ok = withUnsafeMutablePointer(to: &addr.sun_path) { ptr -> Bool in
        let bytes = path.utf8CString
        guard bytes.count <= MemoryLayout.size(ofValue: ptr.pointee) else { return false }
        return ptr.withMemoryRebound(to: CChar.self, capacity: bytes.count) { dest in
            for (index, byte) in bytes.enumerated() { dest[index] = byte }
            return true
        }
    }
    guard ok else { return nil }
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connected = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            connect(fd, sa, size)
        }
    }
    guard connected == 0 else { return nil }
    _ = payload.withUnsafeBytes { raw in
        send(fd, raw.baseAddress, raw.count, 0)
    }
    shutdown(fd, SHUT_WR)
    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = recv(fd, &buffer, buffer.count, 0)
        guard n > 0 else { break }
        response.append(contentsOf: buffer[0..<n])
    }
    return response
}

@MainActor
extension XuanyuRegressionTestRunner {
    static func testCodeWatchProjectDirEncoding() throws {
        try cwExpect(
            CodeWatchDiscovery.claudeProjectDirEncoded("/Users/xingyi/project/mac应用/灵动岛")
                == "-Users-xingyi-project-mac------",
            "中文与斜杠都应编码为 -"
        )
        try cwExpect(
            CodeWatchDiscovery.claudeProjectDirEncoded("/tmp/a b") == "-tmp-a-b",
            "空格应编码为 -"
        )
    }

    static func testCodeWatchExecutableMatching() throws {
        try cwExpect(
            CodeWatchDiscovery.isClaudeExecutablePath("/Users/x/.local/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe"),
            "npm 安装的 claude.exe 应被识别"
        )
        try cwExpect(
            CodeWatchDiscovery.isClaudeExecutablePath("/Users/x/.local/share/claude/versions/2.1.91"),
            "原生安装器路径应被识别"
        )
        try cwExpect(
            !CodeWatchDiscovery.isClaudeExecutablePath("/Applications/Claude.app/Contents/MacOS/Claude"),
            "桌面版 Claude.app 不是 CLI 会话"
        )
        try cwExpect(
            CodeWatchDiscovery.isCodexExecutablePath("/Applications/ChatGPT.app/Contents/Resources/codex"),
            "ChatGPT.app 内的 codex 应被识别"
        )
        try cwExpect(
            !CodeWatchDiscovery.isCodexExecutablePath("/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"),
            "ChatGPT 主程序不是 codex"
        )
        try cwExpect(
            CodeWatchDiscovery.codexClient(
                executablePath: "/Applications/ChatGPT.app/Contents/Resources/codex"
            ) == .chatGPT,
            "ChatGPT.app 内的 app-server 必须标成 ChatGPT"
        )
        try cwExpect(
            CodeWatchDiscovery.codexClient(executablePath: "/opt/homebrew/bin/codex") == .codex,
            "终端 codex 必须继续标成 Codex"
        )
    }

    static func testCodeWatchCodexSessionIdExtraction() throws {
        try cwExpect(
            CodeWatchDiscovery.extractCodexSessionId(from: "rollout-2026-07-27T10-11-12-0196fdd4-4bcf-7ce9-8a71-cdc9a7d94355.jsonl")
                == "0196fdd4-4bcf-7ce9-8a71-cdc9a7d94355",
            "应取文件名末尾的 UUID"
        )
    }

    static func testCodeWatchCodexSessionMetadata() throws {
        let path = NSTemporaryDirectory() + "cw-codex-meta-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let firstLine = """
        {"type":"session_meta","payload":{"cwd":"/tmp/chatgpt-project","originator":"Codex Desktop"}}
        {"type":"event_msg","payload":{"type":"task_started"}}
        """
        try firstLine.write(toFile: path, atomically: true, encoding: .utf8)
        let metadata = CodeWatchDiscovery.codexSessionMetadata(path: path)
        try cwExpect(metadata?.cwd == "/tmp/chatgpt-project", "应读取 rollout cwd")
        try cwExpect(metadata?.originator == "Codex Desktop", "应读取 rollout originator")
    }

    static func testCodeWatchPetVersionCompatibility() throws {
        try cwExpect(
            CodexPetCatalog.resolvedVersion(width: 1536, height: 1872, declaredVersion: nil) == 1,
            "旧版 8×9 Codex Pet 在没有版本字段时应按 v1 读取"
        )
        try cwExpect(
            CodexPetCatalog.resolvedVersion(width: 1536, height: 2288, declaredVersion: 2) == 2,
            "8×11 Codex Pet 应按 v2 读取"
        )
        try cwExpect(
            CodexPetCatalog.resolvedVersion(width: 1536, height: 1872, declaredVersion: 2) == nil,
            "manifest 版本与 atlas 高度冲突时必须拒绝"
        )
    }

    static func testCodeWatchInstallerPreservesForeignHooks() throws {
        let dir = NSTemporaryDirectory() + "codewatch-installer-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let settingsPath = dir + "/settings.json"
        let scriptPath = dir + "/hook.sh"

        // 已有别家 hook + 无关顶层键
        let original = """
        {
          "model": "opus",
          "hooks": {
            "SessionStart": [
              { "matcher": "", "hooks": [ { "type": "command", "command": "/opt/other-tool.sh" } ] }
            ]
          }
        }
        """
        try original.write(toFile: settingsPath, atomically: true, encoding: .utf8)

        try CodeWatchHookInstaller.install(settingsPath: settingsPath, scriptPath: scriptPath)
        try cwExpect(FileManager.default.isExecutableFile(atPath: scriptPath), "hook 脚本应写出且可执行")
        try cwExpect(CodeWatchHookInstaller.isInstalled(settingsPath: settingsPath), "安装后应可检测到")

        var json = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: settingsPath))) as! [String: Any]
        try cwExpect(json["model"] as? String == "opus", "无关顶层键应保留")
        var hooks = json["hooks"] as! [String: Any]
        var sessionStart = hooks["SessionStart"] as! [[String: Any]]
        try cwExpect(sessionStart.count == 2, "别家 hook 应保留，加上我们的共两条")
        try cwExpect(
            (hooks["PreToolUse"] as? [[String: Any]])?.count == 1,
            "PreToolUse 应挂上监控 hook"
        )
        try cwExpect(hooks["PermissionRequest"] == nil, "绝不安装 PermissionRequest hook")

        try CodeWatchHookInstaller.uninstall(settingsPath: settingsPath, scriptPath: scriptPath)
        json = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: settingsPath))) as! [String: Any]
        hooks = json["hooks"] as! [String: Any]
        sessionStart = hooks["SessionStart"] as! [[String: Any]]
        try cwExpect(sessionStart.count == 1, "卸载后只剩别家 hook")
        try cwExpect(
            (sessionStart[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String == "/opt/other-tool.sh",
            "别家 hook 内容应原样保留"
        )
        try cwExpect(hooks["PreToolUse"] == nil, "卸载后我们独占的事件键应移除")
    }

    static func testCodeWatchInstallerRefusesBrokenSettings() throws {
        let dir = NSTemporaryDirectory() + "codewatch-broken-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let settingsPath = dir + "/settings.json"
        let broken = "{ this is not json"
        try broken.write(toFile: settingsPath, atomically: true, encoding: .utf8)

        var threw = false
        do {
            try CodeWatchHookInstaller.install(settingsPath: settingsPath, scriptPath: dir + "/hook.sh")
        } catch {
            threw = true
        }
        try cwExpect(threw, "坏 JSON 必须拒绝写入")
        try cwExpect(
            try String(contentsOfFile: settingsPath, encoding: .utf8) == broken,
            "原文件必须原样保留"
        )
    }

    static func testCodeWatchServiceReducesHookEvents() throws {
        let service = CodeWatchService()

        func event(_ json: [String: Any]) throws -> HookEvent {
            let data = try JSONSerialization.data(withJSONObject: json)
            guard let event = HookEvent(from: data) else {
                throw CodeWatchTestFailure(message: "HookEvent 解析失败: \(json)")
            }
            return event
        }

        try service.handleHookEvent(event([
            "hook_event_name": "SessionStart",
            "session_id": "s1",
            "cwd": "/tmp/demo",
            "model": "claude-opus",
            "_source": "claude",
        ]))
        try cwExpect(service.sessions["s1"] != nil, "SessionStart 应建会话")
        try cwExpect(service.sessions["s1"]?.cwd == "/tmp/demo", "cwd 应写入")

        try service.handleHookEvent(event([
            "hook_event_name": "PreToolUse",
            "session_id": "s1",
            "tool_name": "Bash",
            "tool_input": ["command": "ls -la"],
        ]))
        try cwExpect(service.sessions["s1"]?.status == .running, "PreToolUse 后应为 running")
        try cwExpect(service.sessions["s1"]?.currentTool == "Bash", "当前工具应为 Bash")
        try cwExpect(service.summary.activeSessionCount == 1, "汇总应有 1 个活跃会话")

        try service.handleHookEvent(event([
            "hook_event_name": "Stop",
            "session_id": "s1",
        ]))
        try cwExpect(service.sessions["s1"]?.status == .idle, "Stop 后应回 idle")
        try cwExpect(service.summary.activeSessionCount == 0, "汇总活跃数应清零")
        try cwExpect(service.lastCompletion?.client == .claudeCode, "Claude Code 完成来源应正确")
        try cwExpect(service.completionNoticeToken == 1, "Stop 应产生一次完成通知")
    }

    static func testCodeWatchChatGPTCompletion() throws {
        let service = CodeWatchService()

        func event(_ json: [String: Any]) throws -> HookEvent {
            let data = try JSONSerialization.data(withJSONObject: json)
            guard let event = HookEvent(from: data) else {
                throw CodeWatchTestFailure(message: "HookEvent 解析失败: \(json)")
            }
            return event
        }

        service.handleHookEvent(try event([
            "hook_event_name": "SessionStart",
            "session_id": "chatgpt-1",
            "cwd": "/tmp/chatgpt-project",
            "_source": "codex",
            "_term_bundle": "com.openai.codex",
        ]))
        service.handleHookEvent(try event([
            "hook_event_name": "PreToolUse",
            "session_id": "chatgpt-1",
            "tool_name": "Bash",
        ]))
        try cwExpect(service.collapsedStatusTitle == "ChatGPT 正在运行", "缩小态应显示 ChatGPT 来源")

        service.handleHookEvent(try event([
            "hook_event_name": "Stop",
            "session_id": "chatgpt-1",
            "last_assistant_message": "任务完成",
        ]))
        try cwExpect(service.lastCompletion?.client == .chatGPT, "完成通知应标成 ChatGPT")
        try cwExpect(service.lastCompletion?.message == "任务完成", "完成通知应携带最后回复")
    }

    static func testCodeWatchCodexMidTurnAttach() throws {
        let service = CodeWatchService()
        var snapshot = SessionSnapshot()
        snapshot.source = "codex"
        snapshot.cwd = "/tmp/mid-turn"
        snapshot.status = .idle
        service.sessions["mid-turn"] = snapshot

        service.debugApplyTranscriptDelta(ConversationTailDelta(
            sessionId: "mid-turn",
            lastUserPrompt: nil,
            lastAssistantMessage: nil,
            turnStatus: nil,
            hasActivity: true
        ))
        try cwExpect(
            service.sessions["mid-turn"]?.status == .processing,
            "回合中段接入时，新 Codex event_msg 应证明任务正在运行"
        )

        service.debugApplyTranscriptDelta(ConversationTailDelta(
            sessionId: "mid-turn",
            lastUserPrompt: nil,
            lastAssistantMessage: "完成",
            turnStatus: .idle,
            hasActivity: true
        ))
        try cwExpect(service.sessions["mid-turn"]?.status == .idle, "task_complete 应回到空闲")
        try cwExpect(service.completionNoticeToken == 1, "活跃转空闲应通知一次")
    }

    /// 回归：上游 reducer 的 SessionStart 分支会重建 SessionSnapshot 却不回填
    /// transcript_path，导致 tailer 无路径可 attach。服务层必须补上。
    static func testCodeWatchSessionStartKeepsTranscriptPath() throws {
        let service = CodeWatchService()
        let data = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "SessionStart",
            "session_id": "keep-tp",
            "cwd": "/tmp/keep",
            "transcript_path": "/tmp/keep/session.jsonl",
            "_source": "claude",
        ])
        guard let event = HookEvent(from: data) else {
            throw CodeWatchTestFailure(message: "HookEvent 解析失败")
        }
        service.handleHookEvent(event)
        try cwExpect(
            service.sessions["keep-tp"]?.transcriptPath == "/tmp/keep/session.jsonl",
            "SessionStart 之后 transcriptPath 必须保留，否则永远不会开始尾随"
        )
    }

    /// 直接验证 vendored JSONLTailer：attach 后追加行应推出 delta。
    static func testCodeWatchTailerDeliversAppendedLines() throws {
        let path = NSTemporaryDirectory() + "cw-tailer-\(UUID().uuidString.prefix(8)).jsonl"
        FileManager.default.createFile(atPath: path, contents: Data("{\"type\":\"user\",\"message\":{\"content\":\"first\"}}\n".utf8))
        defer { try? FileManager.default.removeItem(atPath: path) }

        nonisolated(unsafe) var deltas: [ConversationTailDelta] = []
        let tailer = JSONLTailer { delta in
            Task { @MainActor in deltas.append(delta) }
        }
        tailer.attach(sessionId: "t1", filePath: path)
        defer { tailer.detachAll() }

        // 等 attach 落到 tailer 队列上
        let attachDeadline = Date().addingTimeInterval(2)
        while tailer.activeSessionCount == 0 && Date() < attachDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        try cwExpect(tailer.activeSessionCount == 1, "应已 attach 1 个会话")

        let handle = FileHandle(forWritingAtPath: path)!
        handle.seekToEndOfFile()
        handle.write(Data("{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"tailed reply\"}]}}\n".utf8))
        try? handle.close()

        let deadline = Date().addingTimeInterval(3)
        while deltas.isEmpty && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        try cwExpect(!deltas.isEmpty, "追加内容后应收到 delta")
        try cwExpect(deltas.first?.lastAssistantMessage == "tailed reply", "delta 应带上新回复")
    }

    static func testCodeWatchSocketServerRoundTrip() throws {
        let socketPath = NSTemporaryDirectory() + "cw-test-\(UUID().uuidString.prefix(8)).sock"
        nonisolated(unsafe) var received: [HookEvent] = []
        let server = CodeWatchSocketServer(socketPath: socketPath) { event in
            Task { @MainActor in received.append(event) }
        }
        try server.start()
        defer { server.stop() }

        // 等 listener ready（socket 文件出现）
        let deadline = Date().addingTimeInterval(3)
        while !FileManager.default.fileExists(atPath: socketPath) && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        try cwExpect(FileManager.default.fileExists(atPath: socketPath), "socket 文件应已创建")

        let payload = try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "UserPromptSubmit",
            "session_id": "sock-1",
            "prompt": "帮我看看这个 bug",
        ])
        nonisolated(unsafe) var response: Data?
        let sender = Thread {
            response = sendToUnixSocket(path: socketPath, payload: payload)
        }
        sender.start()

        let waitUntil = Date().addingTimeInterval(3)
        while received.isEmpty && Date() < waitUntil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        try cwExpect(received.count == 1, "服务器应收到 1 条事件")
        try cwExpect(received.first?.eventName == "UserPromptSubmit", "事件名应正确")
        try cwExpect(received.first?.sessionId == "sock-1", "会话 id 应正确")
        try cwExpect(response.map { String(data: $0, encoding: .utf8) } == "{}", "客户端应收到 {} 响应")
    }
}
#endif
