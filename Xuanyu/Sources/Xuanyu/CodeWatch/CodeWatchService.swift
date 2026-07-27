// CodeWatch：Claude Code / Codex 会话监控服务。
// 状态机与 transcript 尾随来自 CodeIslandCore（见 Sources/CodeWatchCore，MIT）；
// 本文件是悬屿自己的编排层：两条数据通道汇进同一份 sessions 字典 ——
//   1) hook 事件（实时、带工具名，需要安装 hooks）
//   2) 进程扫描 + transcript 尾随（零配置兜底，装没装 hooks 都能看到会话）
import CodeWatchCore
import Foundation
import Observation

@MainActor
@Observable
final class CodeWatchService {
    static let automaticMascotID = "automatic"
    static let selectedMascotPreferenceKey = "codewatch.selectedMascot"
    static let completionNotificationsPreferenceKey = "codewatch.completionNotifications"

    var sessions: [String: SessionSnapshot] = [:]
    var summary = SessionSummary(status: .idle, primarySource: "claude", activeSessionCount: 0, totalSessionCount: 0)
    var isRunning = false
    var hooksInstalled = false
    var lastError = ""
    var availablePets: [CodexPet] = []
    var selectedMascotID: String {
        didSet {
            UserDefaults.standard.set(selectedMascotID, forKey: Self.selectedMascotPreferenceKey)
        }
    }
    var completionNotificationsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                completionNotificationsEnabled,
                forKey: Self.completionNotificationsPreferenceKey
            )
            if completionNotificationsEnabled {
                refreshNotificationAuthorization()
            }
        }
    }
    var notificationAuthorization: CodeWatchNotificationAuthorization = .unknown
    var lastCompletion: CodeWatchCompletion?
    var completionNoticeToken = 0

    @ObservationIgnored private var socketServer: CodeWatchSocketServer?
    @ObservationIgnored private var tailer: JSONLTailer?
    @ObservationIgnored private var discoveryTimer: Timer?
    @ObservationIgnored private var attachedTranscripts: [String: String] = [:]
    @ObservationIgnored private var sessionPids: [String: pid_t] = [:]
    @ObservationIgnored private var sessionClients: [String: CodeWatchClient] = [:]
    @ObservationIgnored private var lastCompletionDates: [String: Date] = [:]
    @ObservationIgnored private var discoveryInFlight = false

    private static let maxToolHistory = 30
    private static let discoveryInterval: TimeInterval = 4
    private static let idleSessionTTL: TimeInterval = 300

    init() {
        selectedMascotID = UserDefaults.standard.string(forKey: Self.selectedMascotPreferenceKey)
            ?? Self.automaticMascotID
        completionNotificationsEnabled = UserDefaults.standard.object(
            forKey: Self.completionNotificationsPreferenceKey
        ) as? Bool ?? true
        reloadPets()
    }

    var selectedPet: CodexPet? {
        guard selectedMascotID != Self.automaticMascotID else { return nil }
        return availablePets.first { $0.id == selectedMascotID }
    }

    var selectedMascotName: String {
        selectedPet?.displayName ?? "按来源"
    }

    var orderedSessions: [(id: String, snapshot: SessionSnapshot, client: CodeWatchClient)] {
        sessions
            .map {
                (
                    id: $0.key,
                    snapshot: $0.value,
                    client: sessionClients[$0.key] ?? CodeWatchClient.fallback(for: $0.value.source)
                )
            }
            .sorted { left, right in
                if left.snapshot.status.isActive != right.snapshot.status.isActive {
                    return left.snapshot.status.isActive
                }
                return left.snapshot.lastActivity > right.snapshot.lastActivity
            }
    }

    var hasActiveSessions: Bool {
        summary.activeSessionCount > 0
    }

    var primaryActiveSession: (id: String, snapshot: SessionSnapshot, client: CodeWatchClient)? {
        orderedSessions.first { $0.snapshot.status.isActive }
    }

    var collapsedStatusTitle: String {
        let active = orderedSessions.filter { $0.snapshot.status.isActive }
        guard !active.isEmpty else { return lastCompletion?.collapsedTitle ?? "编码会话" }
        var clients: [CodeWatchClient] = []
        for item in active where !clients.contains(item.client) {
            clients.append(item.client)
        }
        let names = clients.map(\.displayName).joined(separator: " + ")
        switch summary.status {
        case .waitingApproval, .waitingQuestion:
            return "\(names) 等待确认"
        case .processing, .running:
            return "\(names) 正在运行"
        case .idle:
            return names
        }
    }

    func client(for sessionId: String, source: String) -> CodeWatchClient {
        sessionClients[sessionId] ?? CodeWatchClient.fallback(for: source)
    }

    func reloadPets() {
        availablePets = CodexPetCatalog.load()
        if selectedMascotID != Self.automaticMascotID,
           !availablePets.contains(where: { $0.id == selectedMascotID }) {
            selectedMascotID = Self.automaticMascotID
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        reloadPets()
        if completionNotificationsEnabled {
            refreshNotificationAuthorization()
        }
        MascotAnimationGate.shared.start()

        let tailer = JSONLTailer { [weak self] delta in
            Task { @MainActor [weak self] in
                self?.applyTranscriptDelta(delta)
            }
        }
        self.tailer = tailer

        let server = CodeWatchSocketServer { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleHookEvent(event)
            }
        }
        do {
            try server.start()
            socketServer = server
        } catch {
            lastError = "hook socket 启动失败：\(error.localizedDescription)"
        }

        hooksInstalled = CodeWatchHookInstaller.isInstalled()

        let timer = Timer(timeInterval: Self.discoveryInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.runDiscovery()
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        discoveryTimer = timer
        runDiscovery()
    }

    func handleNotificationButton() {
        if completionNotificationsEnabled, notificationAuthorization == .denied {
            CodeWatchNotificationService.shared.openSystemSettings()
            return
        }
        completionNotificationsEnabled.toggle()
    }

    func refreshNotificationAuthorization() {
        CodeWatchNotificationService.shared.start { [weak self] status in
            Task { @MainActor [weak self] in
                self?.notificationAuthorization = status
                self?.writeStatusSnapshot()
            }
        }
    }

    func stop() {
        discoveryTimer?.invalidate()
        discoveryTimer = nil
        socketServer?.stop()
        socketServer = nil
        tailer?.detachAll()
        tailer = nil
        attachedTranscripts = [:]
        isRunning = false
    }

    func installHooks() {
        do {
            try CodeWatchHookInstaller.install()
            hooksInstalled = true
            lastError = ""
        } catch {
            lastError = "安装 hooks 失败：\(error.localizedDescription)"
        }
    }

    func uninstallHooks() {
        do {
            try CodeWatchHookInstaller.uninstall()
            hooksInstalled = false
            lastError = ""
        } catch {
            lastError = "移除 hooks 失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 通道 1：hook 事件

    func handleHookEvent(_ event: HookEvent) {
        let sessionId = event.sessionId ?? "default"
        let eventName = EventNormalizer.normalize(event.eventName)
        // Codex Desktop 会发不带会话数据的占位 hook，跳过以免覆盖发现的会话
        if let source = event.rawJSON["_source"] as? String,
           source.lowercased() == "codex",
           event.rawJSON["transcript_path"] == nil {
            let cwd = (event.rawJSON["cwd"] as? String)?.trimmingCharacters(in: .whitespaces)
            if cwd == nil || cwd == "/" { return }
        }
        if eventName == "UserPromptSubmit" || eventName == "SessionStart" {
            lastCompletionDates.removeValue(forKey: sessionId)
        }
        let effects = reduceEvent(sessions: &sessions, event: event, maxHistory: Self.maxToolHistory)
        if let snapshot = sessions[sessionId] {
            if eventClientBundleId(event) == "com.openai.codex" {
                sessionClients[sessionId] = .chatGPT
            } else if sessionClients[sessionId] == nil {
                sessionClients[sessionId] = CodeWatchClient.fallback(for: snapshot.source)
            }
        }
        // reduceEvent 的 SessionStart 分支会整体替换 SessionSnapshot，然后逐字段回填
        // cwd/model/终端信息，唯独漏了 transcript_path —— 不补上的话 tailer 没有路径可
        // attach，会话会一直没有内容更新。
        if let sessionId = event.sessionId,
           sessions[sessionId]?.transcriptPath == nil,
           let path = event.rawJSON["transcript_path"] as? String,
           !path.isEmpty {
            sessions[sessionId]?.transcriptPath = path
        }
        for effect in effects {
            switch effect {
            case .tryMonitorSession(let sessionId):
                attachTailerIfNeeded(sessionId: sessionId)
            case .removeSession(let sessionId):
                if sessions[sessionId]?.status.isActive == true {
                    publishCompletion(sessionId: sessionId)
                }
                removeSession(sessionId)
            case .playSound(let eventName):
                CodeWatchSoundPlayer.shared.handleEvent(eventName)
            case .enqueueCompletion(let sessionId):
                publishCompletion(sessionId: sessionId)
            case .stopMonitor, .setActiveSession:
                break
            }
        }
        attachTailerIfNeeded(sessionId: sessionId)
        refreshSummary()
    }

    // MARK: - 通道 2：发现 + 尾随

    private func runDiscovery() {
        guard !discoveryInFlight else { return }
        discoveryInFlight = true
        let projectsDir = ClaudeConfigPaths.projectsDir()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        Task.detached(priority: .utility) { [weak self] in
            let pids = CodeWatchDiscovery.allProcessIds()
            let claude = CodeWatchDiscovery.findActiveClaudeSessions(projectsDir: projectsDir, candidatePids: pids)
            let codex = CodeWatchDiscovery.findActiveCodexSessions(sessionsBase: "\(home)/.codex/sessions", candidatePids: pids)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.discoveryInFlight = false
                self.integrateDiscovered(claude + codex)
                self.cleanupDeadSessions()
                self.refreshSummary()
            }
        }
    }

    private func integrateDiscovered(_ discovered: [DiscoveredCodeSession]) {
        for item in discovered {
            sessionPids[item.sessionId] = item.pid
            sessionClients[item.sessionId] = item.client
            if var existing = sessions[item.sessionId] {
                // hook 通道已建的会话只补缺失的字段，不覆盖实时状态
                if existing.transcriptPath == nil { existing.transcriptPath = item.transcriptPath }
                if existing.cwd == nil { existing.cwd = item.cwd }
                // transcript 里约四分之三是 tailer 故意跳过的工具行，只靠 delta 会让
                // 正在干活的会话显示成"很久没动"。用文件 mtime 兜底。
                if item.modifiedAt > existing.lastActivity { existing.lastActivity = item.modifiedAt }
                sessions[item.sessionId] = existing
            } else {
                var snapshot = SessionSnapshot(startTime: item.modifiedAt)
                snapshot.source = item.source
                snapshot.cwd = item.cwd
                snapshot.transcriptPath = item.transcriptPath
                snapshot.lastActivity = item.modifiedAt
                sessions[item.sessionId] = snapshot
                backfillRecent(sessionId: item.sessionId, transcriptPath: item.transcriptPath)
            }
            attachTailerIfNeeded(sessionId: item.sessionId)
        }
    }

    /// 尾随器从 EOF 开始，新发现的会话读一次末尾补齐最近消息。
    private func backfillRecent(sessionId: String, transcriptPath: String) {
        guard let handle = FileHandle(forReadingAtPath: transcriptPath) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let readFrom = size > 131_072 ? size - 131_072 : 0
        try? handle.seek(toOffset: readFrom)
        guard var data = try? handle.readToEnd(), !data.isEmpty else { return }
        // 起点可能落在半行中间，丢掉第一段残行
        if readFrom > 0, let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
            data = Data(data.suffix(from: newline + 1))
        }
        let delta = JSONLTailer.scanLines(data).delta
        guard var snapshot = sessions[sessionId] else { return }
        if let prompt = delta.lastUserPrompt { snapshot.lastUserPrompt = prompt }
        if let reply = delta.lastAssistantMessage { snapshot.lastAssistantMessage = reply }
        // 只回填"进行中"；idle 维持默认，避免把等待输入的会话误判
        if snapshot.status == .idle,
           delta.turnStatus == .processing
                || (snapshot.source == "codex" && delta.hasActivity && delta.turnStatus == nil) {
            snapshot.status = .processing
        }
        sessions[sessionId] = snapshot
    }

    private func attachTailerIfNeeded(sessionId: String) {
        guard let tailer,
              let path = sessions[sessionId]?.transcriptPath,
              !path.isEmpty,
              attachedTranscripts[sessionId] != path,
              FileManager.default.fileExists(atPath: path) else { return }
        if attachedTranscripts[sessionId] != nil {
            tailer.detach(sessionId: sessionId)
        }
        attachedTranscripts[sessionId] = path
        tailer.attach(sessionId: sessionId, filePath: path)
    }

    private func applyTranscriptDelta(_ delta: ConversationTailDelta) {
        guard var snapshot = sessions[delta.sessionId] else { return }
        let previousStatus = snapshot.status
        if delta.hasActivity || delta.lastUserPrompt != nil || delta.lastAssistantMessage != nil {
            snapshot.lastActivity = Date()
        }
        if let prompt = delta.lastUserPrompt {
            lastCompletionDates.removeValue(forKey: delta.sessionId)
            snapshot.lastUserPrompt = prompt
            snapshot.recentMessages.append(ChatMessage(isUser: true, text: prompt))
            // 无 hooks 时，用户消息意味着新一轮开始
            if !snapshot.status.isWaiting { snapshot.status = .processing }
        }
        if let reply = delta.lastAssistantMessage {
            snapshot.lastAssistantMessage = reply
            snapshot.recentMessages.append(ChatMessage(isUser: false, text: reply))
        }
        if snapshot.recentMessages.count > 3 {
            snapshot.recentMessages.removeFirst(snapshot.recentMessages.count - 3)
        }
        if let turnStatus = delta.turnStatus, !snapshot.status.isWaiting {
            switch turnStatus {
            case .processing:
                snapshot.status = .processing
            case .idle:
                snapshot.status = .idle
                snapshot.currentTool = nil
                snapshot.toolDescription = nil
            }
        } else if snapshot.source == "codex",
                  delta.hasActivity,
                  snapshot.status == .idle {
            // App 可能在 ChatGPT/Codex 回合中段启动，tailer 从 EOF 接入后看不到
            // 更早的 task_started。此时持续追加的 event_msg 本身就是正在执行的证据；
            // 后续 task_complete / turn_aborted 会明确把状态降回 idle。
            snapshot.status = .processing
        }
        sessions[delta.sessionId] = snapshot
        if previousStatus.isActive, snapshot.status == .idle {
            publishCompletion(sessionId: delta.sessionId)
        }
        refreshSummary()
    }

    private func eventClientBundleId(_ event: HookEvent) -> String? {
        (
            event.rawJSON["_term_bundle"] as? String
                ?? event.rawJSON["term_bundle"] as? String
                ?? event.rawJSON["bundle_id"] as? String
        )?.lowercased()
    }

    private func publishCompletion(sessionId: String) {
        guard let snapshot = sessions[sessionId] else { return }
        let now = Date()
        if let lastDate = lastCompletionDates[sessionId],
           now.timeIntervalSince(lastDate) < 4 {
            return
        }
        lastCompletionDates[sessionId] = now

        let completion = CodeWatchCompletion(
            sessionId: sessionId,
            client: client(for: sessionId, source: snapshot.source),
            projectName: snapshot.codeWatchProjectName,
            message: snapshot.lastAssistantMessage,
            interrupted: snapshot.interrupted
        )
        lastCompletion = completion
        completionNoticeToken &+= 1
        if completionNotificationsEnabled {
            CodeWatchNotificationService.shared.send(completion)
        }
    }

    // MARK: - 清理

    private func cleanupDeadSessions() {
        let now = Date()
        for (id, snapshot) in sessions {
            let pidAlive = sessionPids[id].map(CodeWatchDiscovery.isProcessAlive) ?? true
            let stale = now.timeIntervalSince(snapshot.lastActivity) > Self.idleSessionTTL
            // 进程死了会话就结束了；进程还在但长时间无活动且不在等待，也回收
            if !pidAlive || (stale && !snapshot.status.isWaiting) {
                if snapshot.status.isActive {
                    publishCompletion(sessionId: id)
                }
                removeSession(id)
            }
        }
    }

    private func removeSession(_ sessionId: String) {
        sessions.removeValue(forKey: sessionId)
        sessionPids.removeValue(forKey: sessionId)
        sessionClients.removeValue(forKey: sessionId)
        if attachedTranscripts.removeValue(forKey: sessionId) != nil {
            tailer?.detach(sessionId: sessionId)
        }
    }

    private func refreshSummary() {
        let derived = deriveSessionSummary(from: sessions)
        if derived.status != summary.status
            || derived.activeSessionCount != summary.activeSessionCount
            || derived.totalSessionCount != summary.totalSessionCount
            || derived.primarySource != summary.primarySource {
            summary = derived
        }
        writeStatusSnapshot()
    }

    // MARK: - 调试快照

    @ObservationIgnored private var lastSnapshotWrite = Date.distantPast

    static func statusSnapshotPath() -> String {
        "/tmp/xuanyu-codewatch-status-\(getuid()).json"
    }

    /// 把当前会话表落到 /tmp，方便命令行核对监控是否在工作（2 秒节流）。
    private func writeStatusSnapshot() {
        let now = Date()
        guard now.timeIntervalSince(lastSnapshotWrite) > 2 else { return }
        lastSnapshotWrite = now
        let formatter = ISO8601DateFormatter()
        let payload: [String: Any] = [
            "updatedAt": formatter.string(from: now),
            "activeCount": summary.activeSessionCount,
            "totalCount": summary.totalSessionCount,
            "hooksInstalled": hooksInstalled,
            "selectedMascot": selectedMascotID,
            "availablePets": availablePets.map(\.displayName),
            "completionNotifications": completionNotificationsEnabled,
            "notificationAuthorization": notificationAuthorization.rawValue,
            "sessions": sessions.map { id, snapshot in
                [
                    "sessionId": id,
                    "source": snapshot.source,
                    "client": client(for: id, source: snapshot.source).displayName,
                    "cwd": snapshot.cwd ?? "",
                    "status": snapshot.status.displayLabel,
                    "currentTool": snapshot.currentTool ?? "",
                    "model": snapshot.model ?? "",
                    "toolCalls": snapshot.totalToolCallCount,
                    "lastActivity": formatter.string(from: snapshot.lastActivity),
                ] as [String: Any]
            },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: Self.statusSnapshotPath()), options: .atomic)
    }

    #if DEBUG
    func debugApplyTranscriptDelta(_ delta: ConversationTailDelta) {
        applyTranscriptDelta(delta)
    }
    #endif
}

extension CodeWatchCore.AgentStatus {
    var isActive: Bool { self != .idle }
    var isWaiting: Bool { self == .waitingApproval || self == .waitingQuestion }

    var displayLabel: String {
        switch self {
        case .idle: return "空闲"
        case .processing: return "思考中"
        case .running: return "执行工具"
        case .waitingApproval: return "等待批准"
        case .waitingQuestion: return "等待回答"
        }
    }
}
