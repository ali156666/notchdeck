// CodeWatch：发现本机正在运行的 Claude Code / Codex 会话。
// 改编自 CodeIsland (https://github.com/wxtsky/CodeIsland, MIT, Copyright (c) 2026 wxtsky)
// 的 Sources/CodeIsland/AppState.swift 会话发现部分；上游按 30+ 家 CLI 泛化，
// 这里只保留 claude/codex 两条链路，并放宽了 Claude 的安装路径匹配
// （上游只认原生安装器的 ~/.local/share/claude/versions，漏掉 npm 安装的 claude.exe）。
import Darwin
import Foundation

struct DiscoveredCodeSession: Equatable {
    let sessionId: String
    let source: String
    let client: CodeWatchClient
    let cwd: String
    let pid: pid_t
    let modifiedAt: Date
    let transcriptPath: String
}

enum CodeWatchDiscovery {
    // MARK: - 进程枚举

    nonisolated static func allProcessIds() -> [pid_t] {
        var bufferSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bufferSize > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(bufferSize) / MemoryLayout<pid_t>.size + 10)
        bufferSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, bufferSize)
        let count = Int(bufferSize) / MemoryLayout<pid_t>.size
        return Array(pids.prefix(count)).filter { $0 > 0 }
    }

    nonisolated static func executablePath(for pid: pid_t) -> String? {
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let len = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard len > 0 else { return nil }
        return String(cString: pathBuffer)
    }

    nonisolated static func getCwd(for pid: pid_t) -> String? {
        var pathInfo = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        let ret = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &pathInfo, Int32(size))
        guard ret > 0 else { return nil }
        return withUnsafePointer(to: pathInfo.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
    }

    nonisolated static func getProcessStartTime(_ pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let ret = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard ret > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
    }

    nonisolated static func isProcessAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// 通过 sysctl KERN_PROCARGS2 读进程命令行（npm 安装的 codex 以 node 运行，需看参数）。
    nonisolated static func getProcessArgs(_ pid: pid_t) -> [String]? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        guard size > MemoryLayout<Int32>.size else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        guard argc > 0, argc < 256 else { return nil }
        var offset = MemoryLayout<Int32>.size
        while offset < size && buffer[offset] != 0 { offset += 1 }
        while offset < size && buffer[offset] == 0 { offset += 1 }
        var args: [String] = []
        var argStart = offset
        for _ in 0..<argc {
            while offset < size && buffer[offset] != 0 { offset += 1 }
            if offset > argStart {
                args.append(String(bytes: buffer[argStart..<offset], encoding: .utf8) ?? "")
            }
            offset += 1
            argStart = offset
        }
        return args
    }

    // MARK: - 可执行文件识别

    nonisolated static func isClaudeExecutablePath(_ path: String) -> Bool {
        let lower = path.lowercased()
        // 桌面版 Claude.app 及其 helper 不是 CLI 会话
        if lower.contains(".app/") { return false }
        if lower.contains("/claude-code/") || lower.contains("@anthropic-ai/claude-code") { return true }
        if lower.contains("/.local/share/claude/versions/") { return true }
        let base = (lower as NSString).lastPathComponent
        return base == "claude" || base == "claude.exe"
    }

    nonisolated static func isCodexExecutablePath(_ path: String) -> Bool {
        let lower = URL(fileURLWithPath: path).standardizedFileURL.path.lowercased()
        // Codex Desktop：Codex.app 或 ChatGPT.app 内的 Contents/Resources/codex
        if lower.hasSuffix("/contents/resources/codex") { return true }
        if lower.contains(".app/") { return false }
        let base = (lower as NSString).lastPathComponent
        return base == "codex" || base == "codex.exe"
    }

    nonisolated static func codexClient(executablePath: String, originator: String? = nil) -> CodeWatchClient {
        let normalizedPath = URL(fileURLWithPath: executablePath).standardizedFileURL.path.lowercased()
        if normalizedPath.contains("/chatgpt.app/") {
            return .chatGPT
        }
        if originator?.caseInsensitiveCompare("Codex Desktop") == .orderedSame,
           normalizedPath.contains(".app/") {
            return .chatGPT
        }
        return .codex
    }

    nonisolated static func findClaudePids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        (candidatePids ?? allProcessIds()).filter { pid in
            guard let path = executablePath(for: pid) else { return false }
            return isClaudeExecutablePath(path)
        }
    }

    nonisolated static func findCodexPids(candidatePids: [pid_t]? = nil) -> [pid_t] {
        (candidatePids ?? allProcessIds()).filter { pid in
            guard let path = executablePath(for: pid) else { return false }
            if isCodexExecutablePath(path) { return true }
            if path.lowercased().hasSuffix("/node") {
                if let args = getProcessArgs(pid),
                   args.contains(where: { $0.contains("@openai/codex") || $0.contains("openai-codex") }) {
                    return true
                }
            }
            return false
        }
    }

    // MARK: - Claude 会话发现

    nonisolated static func claudeProjectDirEncoded(_ cwd: String) -> String {
        var result = ""
        for c in cwd.unicodeScalars {
            if c == "/" || c == " " || c.value > 127 {
                result.append("-")
            } else {
                result.append(Character(c))
            }
        }
        return result
    }

    nonisolated static func isSubagentWorktree(_ cwd: String) -> Bool {
        cwd.contains("/.claude/worktrees/agent-") || cwd.contains("/.git/worktrees/agent-")
    }

    nonisolated static func findActiveClaudeSessions(
        projectsDir: String,
        candidatePids: [pid_t]? = nil
    ) -> [DiscoveredCodeSession] {
        let claudePids = findClaudePids(candidatePids: candidatePids)
        guard !claudePids.isEmpty else { return [] }
        let fm = FileManager.default
        var results: [DiscoveredCodeSession] = []
        var seen: Set<String> = []

        for pid in claudePids {
            guard let cwd = getCwd(for: pid), !cwd.isEmpty, !isSubagentWorktree(cwd) else { continue }
            let processStart = getProcessStartTime(pid)
            let projectPath = "\(projectsDir)/\(claudeProjectDirEncoded(cwd))"
            guard let files = try? fm.contentsOfDirectory(atPath: projectPath) else { continue }

            // 该进程 cwd 下、且晚于进程启动的最新 transcript 即当前会话
            var bestFile: String?
            var bestDate = Date.distantPast
            for file in files where file.hasSuffix(".jsonl") {
                let fullPath = "\(projectPath)/\(file)"
                guard let attrs = try? fm.attributesOfItem(atPath: fullPath),
                      let modified = attrs[.modificationDate] as? Date,
                      modified > bestDate else { continue }
                if let start = processStart, modified < start.addingTimeInterval(-10) { continue }
                bestDate = modified
                bestFile = file
            }
            guard let file = bestFile else { continue }

            // 进程启动时间未知时收紧新鲜度窗口，避免复活僵尸会话
            let freshnessLimit: TimeInterval = processStart != nil ? -300 : -30
            if bestDate.timeIntervalSinceNow < freshnessLimit { continue }

            let sessionId = String(file.dropLast(6))
            guard seen.insert(sessionId).inserted else { continue }
            results.append(DiscoveredCodeSession(
                sessionId: sessionId,
                source: "claude",
                client: .claudeCode,
                cwd: cwd,
                pid: pid,
                modifiedAt: bestDate,
                transcriptPath: "\(projectPath)/\(file)"
            ))
        }
        return results
    }

    // MARK: - Codex 会话发现

    nonisolated static func extractCodexSessionId(from filename: String) -> String {
        // rollout-YYYY-MM-DDThh-mm-ss-{uuid}.jsonl，UUID 是最后 5 段
        let name = filename.replacingOccurrences(of: ".jsonl", with: "")
        let parts = name.split(separator: "-")
        if parts.count >= 11 {
            return parts.suffix(5).joined(separator: "-")
        }
        return name
    }

    nonisolated static func readFirstLine(path: String, maxBytes: Int = 2_000_000) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes), !data.isEmpty else { return nil }
        let lineData = data.prefix(while: { $0 != UInt8(ascii: "\n") })
        return String(data: lineData, encoding: .utf8)
    }

    nonisolated static func codexSessionMetadata(path: String) -> (cwd: String, originator: String?)? {
        guard let firstLine = readFirstLine(path: path),
              let lineData = firstLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let payload = json["payload"] as? [String: Any],
              let sessionCwd = payload["cwd"] as? String else { return nil }
        return (sessionCwd, payload["originator"] as? String)
    }

    nonisolated static func codexSessionCwd(path: String) -> String? {
        codexSessionMetadata(path: path)?.cwd
    }

    nonisolated private static func recentCodexRollouts(base: String, after: Date?, fm: FileManager) -> [String] {
        let cal = Calendar.current
        let now = Date()
        var results: [String] = []
        for daysBack in 0..<2 {
            guard let date = cal.date(byAdding: .day, value: -daysBack, to: now) else { continue }
            let y = String(format: "%04d", cal.component(.year, from: date))
            let m = String(format: "%02d", cal.component(.month, from: date))
            let d = String(format: "%02d", cal.component(.day, from: date))
            let dir = "\(base)/\(y)/\(m)/\(d)"
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for file in files.filter({ $0.hasSuffix(".jsonl") }).sorted(by: >).prefix(20) {
                let fullPath = "\(dir)/\(file)"
                if let start = after,
                   let attrs = try? fm.attributesOfItem(atPath: fullPath),
                   let modified = attrs[.modificationDate] as? Date,
                   modified < start.addingTimeInterval(-10) {
                    continue
                }
                results.append(fullPath)
            }
        }
        return results
    }

    nonisolated static func findActiveCodexSessions(
        sessionsBase: String,
        candidatePids: [pid_t]? = nil
    ) -> [DiscoveredCodeSession] {
        let codexPids = findCodexPids(candidatePids: candidatePids)
        guard !codexPids.isEmpty else { return [] }
        let fm = FileManager.default
        guard fm.fileExists(atPath: sessionsBase) else { return [] }
        var results: [DiscoveredCodeSession] = []
        var seen: Set<String> = []

        for pid in codexPids {
            let executablePath = executablePath(for: pid) ?? ""
            let processCwd = getCwd(for: pid)
            let processStart = getProcessStartTime(pid)
            // Codex Desktop 的共享 app-server 以 / 为 cwd，一个进程可对应多个会话，
            // 此时改用 rollout 元数据里的 cwd；终端 CLI 则精确匹配进程 cwd。
            let usesTranscriptCwd = processCwd == nil || processCwd == "/" || processCwd!.isEmpty
            if !usesTranscriptCwd, isSubagentWorktree(processCwd!) { continue }

            let rollouts = recentCodexRollouts(base: sessionsBase, after: processStart, fm: fm)
            for file in rollouts {
                let fileName = (file as NSString).lastPathComponent
                let sessionId = extractCodexSessionId(from: fileName)
                guard !sessionId.isEmpty, !seen.contains(sessionId) else { continue }

                let metadata = codexSessionMetadata(path: file)
                let sessionCwd = metadata?.cwd ?? processCwd
                guard let sessionCwd, !sessionCwd.isEmpty, !isSubagentWorktree(sessionCwd) else { continue }
                if !usesTranscriptCwd && sessionCwd != processCwd { continue }

                let modifiedAt = (try? fm.attributesOfItem(atPath: file))?[.modificationDate] as? Date ?? Date()
                let freshnessLimit: TimeInterval = processStart != nil ? -300 : -30
                if modifiedAt.timeIntervalSinceNow < freshnessLimit { continue }

                seen.insert(sessionId)
                results.append(DiscoveredCodeSession(
                    sessionId: sessionId,
                    source: "codex",
                    client: codexClient(executablePath: executablePath, originator: metadata?.originator),
                    cwd: sessionCwd,
                    pid: pid,
                    modifiedAt: modifiedAt,
                    transcriptPath: file
                ))
                if !usesTranscriptCwd { break }
            }
        }
        return results
    }
}
