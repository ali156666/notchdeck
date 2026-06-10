import Foundation
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class AgentService {
    var config = AgentConfig.default
    var apiKey = ""
    var messages: [AgentMessage] = []
    var toolEvents: [AgentToolEvent] = []
    var permissionRequest: AgentPermissionRequest?
    var status: AgentStatus = .stopped
    var statusText = "未启动"
    var knownSkills: [AgentRuntimeSkill] = []
    var connectedMCPServers: [String] = []
    var memoryUsageText = "0 / 2200"
    var userMemoryUsageText = "0 / 1375"
    var evolutionCandidateCount = 0
    var memoryEntries: [AgentMemoryEntry] = []
    var userMemoryEntries: [AgentMemoryEntry] = []
    var evolutionCandidates: [AgentEvolutionCandidate] = []
    var pendingAttachments: [AgentAttachment] = []
    var conversations: [AgentConversation] = []
    var activeConversationId = ""
    var contextSummary = ""
    var attentionToken = 0
    var attentionText = ""

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var inputPipe: Pipe?
    @ObservationIgnored private var outputBuffer = ""

    var isConfigured: Bool {
        !config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !config.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isBusy: Bool {
        status == .running || status == .waitingForPermission
    }

    func start() {
        config = AgentConfigStore.loadConfig()
        AgentConfigStore.ensureConfigFile(config)
        apiKey = config.apiKey
        knownSkills = localKnownSkills(for: config)
        let conversationStore = AgentConfigStore.loadConversationStore()
        conversations = conversationStore.conversations
        activeConversationId = conversationStore.activeConversationId
        loadActiveConversation()
        if isConfigured {
            startRuntimeIfNeeded()
            configureRuntime()
            syncRuntimeHistory()
        } else {
            status = .stopped
            statusText = "需要配置模型"
        }
    }

    func stop() {
        process?.terminate()
        process = nil
        inputPipe = nil
        status = .stopped
        statusText = "已停止"
    }

    func saveConfiguration(_ newConfig: AgentConfig) {
        var updated = newConfig
        updated.providerId = updated.providerId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "default" : updated.providerId.trimmingCharacters(in: .whitespacesAndNewlines)
        let protocolValue = updated.apiProtocol.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        updated.apiProtocol = protocolValue == "anthropic" ? "anthropic" : "openai"
        updated.baseURL = updated.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.model = updated.model.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.compactModel = updated.compactModel.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.apiKey = updated.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.maxTokens = min(max(updated.maxTokens, 1), 1_000_000)
        updated.contextLimit = min(max(updated.contextLimit, 4_000), 1_000_000)
        updated.historyLimit = min(max(updated.historyLimit, 1), 100_000)
        updated.memoryCharLimit = min(max(updated.memoryCharLimit, 400), 1_000_000)
        updated.userCharLimit = min(max(updated.userCharLimit, 200), 1_000_000)
        updated.sessionSearchLimit = min(max(updated.sessionSearchLimit, 1), 1_000)
        updated.embeddingModel = updated.embeddingModel.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.embeddingBaseURL = updated.embeddingBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.customSkills = updated.customSkills.map { skill in
            AgentSkillConfig(
                id: skill.id,
                name: skill.name.trimmingCharacters(in: .whitespacesAndNewlines),
                title: skill.title.trimmingCharacters(in: .whitespacesAndNewlines),
                content: skill.content.trimmingCharacters(in: .whitespacesAndNewlines),
                enabled: skill.enabled
            )
        }.filter { !$0.name.isEmpty && !$0.content.isEmpty }
        updated.mcpServers = updated.mcpServers.map { server in
            AgentMCPServerConfig(
                id: server.id,
                name: server.name.trimmingCharacters(in: .whitespacesAndNewlines),
                transport: server.transport.trimmingCharacters(in: .whitespacesAndNewlines),
                command: server.command?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                args: server.args.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty },
                url: server.url?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                headers: server.headers,
                env: server.env,
                enabled: server.enabled
            )
        }.filter { !$0.name.isEmpty }
        do {
            try AgentConfigStore.saveConfig(updated)
            config = updated
            self.apiKey = updated.apiKey
            knownSkills = localKnownSkills(for: updated)
            startRuntimeIfNeeded()
            configureRuntime()
            syncRuntimeHistory()
        } catch {
            status = .error
            statusText = "配置保存失败：\(error.localizedDescription)"
        }
    }

    func addAttachmentURLs(_ urls: [URL]) {
        let attachments = makeAttachments(from: urls)
        for attachment in attachments where !pendingAttachments.contains(where: { $0.path == attachment.path }) {
            pendingAttachments.append(attachment)
        }
        if !attachments.isEmpty {
            statusText = "已添加 \(attachments.count) 个文件，输入指令后发送"
        }
    }

    func recognizeFileURLs(_ urls: [URL]) {
        let attachments = makeAttachments(from: urls)
        guard !attachments.isEmpty else { return }
        if !isConfigured {
            for attachment in attachments where !pendingAttachments.contains(where: { $0.path == attachment.path }) {
                pendingAttachments.append(attachment)
            }
            status = .error
            statusText = "先配置模型后再识别文件"
            return
        }
        send("请识别这些文件，提取你能读取到的内容，并说明文件类型、关键信息和下一步建议。", attachments: attachments)
    }

    func removeAttachment(_ attachment: AgentAttachment) {
        pendingAttachments.removeAll { $0.id == attachment.id }
    }

    func clearAttention() {
        attentionText = ""
    }

    func raiseAnswerAttentionForDebug() {
        raiseAttention("悬屿已回答")
    }

    func send(_ text: String, attachments explicitAttachments: [AgentAttachment]? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = explicitAttachments ?? pendingAttachments
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }
        guard isConfigured else {
            status = .error
            statusText = "先配置 baseURL、model 和 API key"
            return
        }
        ensureActiveConversation()
        startRuntimeIfNeeded()
        let displayText = trimmed.isEmpty ? "请识别这些文件。" : trimmed
        messages.append(AgentMessage(role: .user, text: displayText, attachments: attachments))
        saveActiveConversation()
        status = .running
        statusText = attachments.isEmpty ? "思考中" : "识别文件中"
        attentionText = ""
        if explicitAttachments == nil {
            pendingAttachments.removeAll()
        }
        writeJSON([
            "type": "user_message",
            "text": displayText,
            "attachments": attachments.map(\.dictionaryValue),
        ])
    }

    func approvePermission() {
        guard let request = permissionRequest else { return }
        writeJSON(["type": "approve_tool", "id": request.id])
        markPermission(request.id, approved: true)
        permissionRequest = nil
        status = .running
        statusText = "继续执行"
    }

    func denyPermission() {
        guard let request = permissionRequest else { return }
        writeJSON(["type": "deny_tool", "id": request.id])
        markPermission(request.id, approved: false)
        permissionRequest = nil
        status = .running
        statusText = "已拒绝工具"
    }

    func cancel() {
        writeJSON(["type": "cancel"])
        status = .ready
        statusText = "已停止生成"
        if let index = messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
            messages[index].isStreaming = false
        }
    }

    func startNewConversation() {
        if isBusy {
            writeJSON(["type": "cancel"])
        }
        saveActiveConversation()
        let conversation = AgentConversation()
        conversations.insert(conversation, at: 0)
        activeConversationId = conversation.id
        messages.removeAll()
        toolEvents.removeAll()
        contextSummary = ""
        pendingAttachments.removeAll()
        permissionRequest = nil
        persistConversationStore()
        writeJSON(["type": "reset", "sessionId": activeConversationId])
        status = isConfigured ? .ready : .stopped
        statusText = isConfigured ? "新对话" : "需要配置模型"
    }

    func clearCurrentConversation() {
        if isBusy {
            writeJSON(["type": "cancel"])
        }
        ensureActiveConversation()
        messages.removeAll()
        toolEvents.removeAll()
        contextSummary = ""
        pendingAttachments.removeAll()
        permissionRequest = nil
        saveActiveConversation()
        writeJSON(["type": "reset", "sessionId": activeConversationId])
        status = isConfigured ? .ready : .stopped
        statusText = isConfigured ? "已清空当前对话" : "需要配置模型"
    }

    func clearConversation() {
        clearCurrentConversation()
    }

    func compactConversation() {
        guard isConfigured else {
            status = .error
            statusText = "先配置模型后再压缩"
            return
        }
        guard !isBusy else {
            statusText = "生成中，先停止再压缩"
            return
        }
        ensureActiveConversation()
        startRuntimeIfNeeded()
        syncRuntimeHistory()
        status = .running
        statusText = "正在压缩上下文"
        writeJSON([
            "type": "compact",
            "sessionId": activeConversationId,
            "reason": "manual",
        ])
    }

    func selectConversation(_ conversation: AgentConversation) {
        guard conversation.id != activeConversationId else { return }
        guard !isBusy else {
            statusText = "生成中，先停止再切换"
            return
        }
        saveActiveConversation()
        activeConversationId = conversation.id
        loadActiveConversation()
        persistConversationStore()
        syncRuntimeHistory()
        status = isConfigured ? .ready : .stopped
        statusText = "已切换对话"
    }

    func deleteConversation(_ conversation: AgentConversation) {
        guard !isBusy else {
            statusText = "生成中，先停止再删除"
            return
        }
        conversations.removeAll { $0.id == conversation.id }
        if conversations.isEmpty {
            conversations = [AgentConversation()]
        }
        if activeConversationId == conversation.id || !conversations.contains(where: { $0.id == activeConversationId }) {
            activeConversationId = conversations[0].id
            loadActiveConversation()
            syncRuntimeHistory()
        }
        persistConversationStore()
        statusText = "已删除对话"
    }

    func togglePinnedConversation(_ conversation: AgentConversation) {
        guard let index = conversations.firstIndex(where: { $0.id == conversation.id }) else { return }
        conversations[index].isPinned.toggle()
        let isPinned = conversations[index].isPinned
        sortConversations()
        persistConversationStore()
        statusText = isPinned ? "已置顶对话" : "已取消置顶"
    }

    func archiveConversation(_ conversation: AgentConversation) {
        guard !isBusy else {
            statusText = "生成中，先停止再归档"
            return
        }
        guard let index = conversations.firstIndex(where: { $0.id == conversation.id }) else { return }
        conversations[index].isArchived = true
        conversations[index].isPinned = false
        if activeConversationId == conversation.id {
            if let next = conversations.first(where: { !$0.isArchived && $0.id != conversation.id }) {
                activeConversationId = next.id
            } else {
                let fresh = AgentConversation()
                conversations.insert(fresh, at: 0)
                activeConversationId = fresh.id
            }
            loadActiveConversation()
            syncRuntimeHistory()
        }
        sortConversations()
        persistConversationStore()
        statusText = "已归档对话"
    }

    func unarchiveConversation(_ conversation: AgentConversation) {
        guard let index = conversations.firstIndex(where: { $0.id == conversation.id }) else { return }
        conversations[index].isArchived = false
        sortConversations()
        persistConversationStore()
        statusText = "已恢复对话"
    }

    func refreshMemoryAudit() {
        guard isConfigured else { return }
        let needsConfigure = process == nil
        startRuntimeIfNeeded()
        if needsConfigure {
            configureRuntime()
        }
        writeJSON(["type": "list_memory_audit"])
        writeJSON(["type": "list_evolution_candidates"])
    }

    func replaceMemoryEntry(_ entry: AgentMemoryEntry, with text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        writeJSON([
            "type": "replace_memory_entry",
            "target": entry.target,
            "index": entry.index,
            "oldText": entry.text,
            "content": trimmed,
        ])
    }

    func deleteMemoryEntry(_ entry: AgentMemoryEntry) {
        writeJSON([
            "type": "delete_memory_entry",
            "target": entry.target,
            "index": entry.index,
            "oldText": entry.text,
        ])
    }

    func rejectEvolutionCandidate(_ candidate: AgentEvolutionCandidate) {
        writeJSON([
            "type": "reject_evolution_candidate",
            "id": candidate.id,
        ])
    }

    func applyEvolutionCandidate(_ candidate: AgentEvolutionCandidate) {
        writeJSON([
            "type": "apply_evolution_candidate",
            "candidateId": candidate.id,
        ])
    }

    private func startRuntimeIfNeeded() {
        guard process == nil else { return }
        guard let runtimeURL = runtimeScriptURL(),
              let nodeLaunch = nodeLaunch()
        else {
            status = .error
            statusText = "找不到 Node 或悬屿 runtime"
            return
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = nodeLaunch.executable
        process.arguments = nodeLaunch.arguments + [runtimeURL.path]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.consumeOutput(text) }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.status = .error
                self?.statusText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.process = nil
                self?.inputPipe = nil
                if self?.status != .stopped {
                    self?.status = .error
                    self?.statusText = "悬屿 runtime 已退出"
                }
            }
        }

        do {
            try process.run()
            self.process = process
            self.inputPipe = inputPipe
            status = .ready
            statusText = "runtime 已启动"
        } catch {
            status = .error
            statusText = "runtime 启动失败：\(error.localizedDescription)"
        }
    }

    private func configureRuntime() {
        guard isConfigured else { return }
        let payload: [String: Any] = [
            "type": "configure",
            "apiKey": apiKey,
            "config": config.dictionaryValue,
            "configDir": AgentConfigStore.configDirectory.path,
            "skillsRoot": skillsRootURL()?.path ?? "",
        ]
        writeJSON(payload)
    }

    private func writeJSON(_ object: [String: Any]) {
        guard let inputPipe,
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object)
        else {
            return
        }
        inputPipe.fileHandleForWriting.write(data)
        inputPipe.fileHandleForWriting.write(Data("\n".utf8))
    }

    private func consumeOutput(_ text: String) {
        outputBuffer += text
        while let range = outputBuffer.range(of: "\n") {
            let line = String(outputBuffer[..<range.lowerBound])
            outputBuffer.removeSubrange(outputBuffer.startIndex...range.lowerBound)
            handleRuntimeLine(line)
        }
    }

    private func handleRuntimeLine(_ line: String) {
        guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else {
            return
        }

        switch type {
        case "ready":
            status = .ready
            statusText = "就绪"
            knownSkills = decodeRuntimeSkills(object["skills"])
            connectedMCPServers = ((object["mcpServers"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
            if let usage = object["memoryUsage"] as? [String: Any] {
                memoryUsageText = usageText(usage["memory"])
                userMemoryUsageText = usageText(usage["user"])
            }
            evolutionCandidateCount = object["evolutionCandidateCount"] as? Int ?? evolutionCandidateCount
        case "assistant_delta":
            appendAssistantDelta(object["delta"] as? String ?? "")
        case "assistant_done":
            finishAssistantMessage()
        case "context_usage":
            if let used = object["used"] as? Int,
               let limit = object["limit"] as? Int,
               let percent = object["percent"] as? Int
            {
                statusText = "上下文 \(percent)% · \(used) / \(limit)"
            }
        case "compact_started":
            status = .running
            statusText = "正在压缩上下文"
        case "history_compacted":
            applyCompactedHistory(object)
        case "compact_error":
            status = .error
            statusText = object["message"] as? String ?? "上下文压缩失败"
        case "conversation_title":
            updateGeneratedConversationTitle(
                sessionId: object["sessionId"] as? String,
                title: object["title"] as? String
            )
        case "tool_pending":
            upsertToolEvent(
                id: object["id"] as? String ?? UUID().uuidString,
                tool: object["tool"] as? String ?? "tool",
                arguments: object["arguments"],
                isPending: true
            )
        case "permission_auto_approved":
            upsertToolEvent(
                id: UUID().uuidString,
                tool: object["tool"] as? String ?? "tool",
                summary: object["summary"] as? String ?? "懒人模式已自动允许",
                arguments: object["arguments"],
                isPending: false,
                approved: true
            )
        case "tool_result":
            finishToolEvent(
                id: object["id"] as? String ?? UUID().uuidString,
                tool: object["tool"] as? String ?? "tool",
                ok: object["ok"] as? Bool ?? false,
                content: object["content"] as? String ?? ""
            )
        case "permission_request":
            let preview = previewJSON(object["arguments"])
            let request = AgentPermissionRequest(
                id: object["id"] as? String ?? UUID().uuidString,
                tool: object["tool"] as? String ?? "tool",
                source: object["source"] as? String ?? "unknown",
                summary: object["summary"] as? String ?? "",
                argumentsPreview: preview
            )
            permissionRequest = request
            raiseAttention("悬屿等待确认")
            upsertToolEvent(
                id: request.id,
                tool: request.tool,
                summary: request.summary,
                arguments: object["arguments"],
                isPending: true
            )
            status = .waitingForPermission
            statusText = "等待权限确认"
        case "memory_updated":
            let target = object["target"] as? String ?? "memory"
            if target == "user" {
                userMemoryUsageText = usageText(object["usage"])
            } else {
                memoryUsageText = usageText(object["usage"])
            }
        case "memory_audit":
            memoryEntries = decodeArray(object["memory"], as: [AgentMemoryEntry].self)
            userMemoryEntries = decodeArray(object["user"], as: [AgentMemoryEntry].self)
            if let usage = object["memoryUsage"] as? [String: Any] {
                memoryUsageText = usageText(usage["memory"])
                userMemoryUsageText = usageText(usage["user"])
            }
        case "evolution_candidates":
            evolutionCandidates = decodeArray(object["candidates"], as: [AgentEvolutionCandidate].self)
            evolutionCandidateCount = object["count"] as? Int ?? evolutionCandidates.filter { $0.isProposed }.count
        case "evolution_candidates_updated":
            evolutionCandidateCount = object["count"] as? Int ?? evolutionCandidateCount
        case "skills_updated":
            knownSkills = decodeRuntimeSkills(object["skills"])
        case "error":
            status = .error
            statusText = object["message"] as? String ?? "悬屿错误"
            finishAssistantMessage()
        default:
            break
        }
    }

    private func appendAssistantDelta(_ delta: String) {
        guard !delta.isEmpty else { return }
        status = .running
        if let index = messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
            messages[index].text += delta
        } else {
            messages.append(AgentMessage(role: .assistant, text: delta, isStreaming: true))
        }
        saveActiveConversation()
    }

    private func finishAssistantMessage() {
        let hadStreamingAnswer = messages.contains { $0.role == .assistant && $0.isStreaming && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let index = messages.lastIndex(where: { $0.role == .assistant && $0.isStreaming }) {
            messages[index].isStreaming = false
        }
        if status != .error {
            status = .ready
            statusText = "就绪"
        }
        if hadStreamingAnswer {
            toolEvents.removeAll()
            raiseAttention("悬屿已回答")
        }
        saveActiveConversation()
    }

    private func applyCompactedHistory(_ object: [String: Any]) {
        let eventSessionId = object["sessionId"] as? String ?? activeConversationId
        let summary = object["contextSummary"] as? String ?? contextSummary
        let compactedMessages = decodeRuntimeMessages(object["messages"])

        if eventSessionId == activeConversationId {
            contextSummary = summary
            if !compactedMessages.isEmpty || object["messages"] != nil {
                messages = compactedMessages
            }
            toolEvents.removeAll()
            permissionRequest = nil
            status = .ready
            statusText = "上下文已压缩"
            saveActiveConversation()
        } else if let index = conversations.firstIndex(where: { $0.id == eventSessionId }) {
            conversations[index].contextSummary = summary
            if !compactedMessages.isEmpty || object["messages"] != nil {
                conversations[index].messages = compactedMessages
            }
            persistConversationStore()
        }
    }

    private func upsertToolEvent(id: String, tool: String, summary: String = "", arguments: Any?, isPending: Bool, approved: Bool? = nil) {
        let preview = previewJSON(arguments)
        if let index = toolEvents.firstIndex(where: { $0.id == id }) {
            toolEvents[index].tool = tool
            toolEvents[index].summary = summary
            toolEvents[index].argumentsPreview = preview
            toolEvents[index].isPending = isPending
            if let approved {
                toolEvents[index].isApproved = approved
            }
        } else {
            toolEvents.append(AgentToolEvent(id: id, tool: tool, summary: summary, argumentsPreview: preview, isPending: isPending, isApproved: approved))
        }
        toolEvents = Array(toolEvents.suffix(30))
        saveActiveConversation()
    }

    private func finishToolEvent(id: String, tool: String, ok: Bool, content: String) {
        if let index = toolEvents.firstIndex(where: { $0.id == id }) {
            toolEvents[index].isPending = false
            toolEvents[index].resultPreview = contentPreview(content)
            toolEvents[index].isApproved = ok
        } else {
            toolEvents.append(AgentToolEvent(id: id, tool: tool, resultPreview: contentPreview(content), isPending: false, isApproved: ok))
        }
        toolEvents = Array(toolEvents.suffix(30))
        saveActiveConversation()
    }

    private func markPermission(_ id: String, approved: Bool) {
        guard let index = toolEvents.firstIndex(where: { $0.id == id }) else { return }
        toolEvents[index].isApproved = approved
        saveActiveConversation()
    }

    private func previewJSON(_ value: Any?) -> String {
        guard let value else { return "" }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let text = String(data: data, encoding: .utf8)
        {
            return contentPreview(text)
        }
        return contentPreview(String(describing: value))
    }

    private func contentPreview(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 900 ? String(trimmed.prefix(900)) + "..." : trimmed
    }

    private func usageText(_ value: Any?) -> String {
        guard let usage = value as? [String: Any],
              let used = usage["used"] as? Int,
              let limit = usage["limit"] as? Int
        else {
            return "0 / 0"
        }
        return "\(used) / \(limit)"
    }

    private func decodeArray<T: Decodable>(_ value: Any?, as type: [T].Type) -> [T] {
        guard let value,
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value),
              let decoded = try? JSONDecoder().decode(type, from: data)
        else {
            return []
        }
        return decoded
    }

    private func decodeRuntimeSkills(_ value: Any?) -> [AgentRuntimeSkill] {
        ((value as? [[String: Any]]) ?? []).compactMap { object in
            guard let name = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty
            else {
                return nil
            }

            return AgentRuntimeSkill(
                name: name,
                title: (object["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? name,
                summary: (object["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                path: (object["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            )
        }
    }

    private func localKnownSkills(for config: AgentConfig) -> [AgentRuntimeSkill] {
        var skills: [AgentRuntimeSkill] = []

        skills.append(contentsOf: discoverLocalSkills(in: AgentConfigStore.configDirectory.appendingPathComponent("skills", isDirectory: true)))
        if let skillsRoot = skillsRootURL() {
            skills.append(contentsOf: discoverLocalSkills(in: skillsRoot))
        }
        skills.append(contentsOf: config.customSkills.compactMap { skill in
            guard skill.enabled,
                  !skill.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !skill.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return nil
            }

            return AgentRuntimeSkill(
                name: skill.name.trimmingCharacters(in: .whitespacesAndNewlines),
                title: skill.title.trimmingCharacters(in: .whitespacesAndNewlines),
                summary: Self.skillSummary(from: skill.content),
                path: "config:\(skill.id)"
            )
        })

        var seen = Set<String>()
        return skills.filter { skill in
            let key = skill.name.lowercased()
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    private func discoverLocalSkills(in root: URL) -> [AgentRuntimeSkill] {
        guard FileManager.default.fileExists(atPath: root.path),
              let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              )
        else {
            return []
        }

        var skills: [AgentRuntimeSkill] = []
        for case let fileURL as URL in enumerator where fileURL.lastPathComponent == "SKILL.md" {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  resourceValues.isRegularFile == true,
                  let text = try? String(contentsOf: fileURL, encoding: .utf8)
            else {
                continue
            }

            let name = fileURL.deletingLastPathComponent().lastPathComponent
            let title = Self.skillTitle(from: text, fallback: name)
            let path = fileURL.path.hasPrefix(root.path)
                ? String(fileURL.path.dropFirst(root.path.count + 1))
                : fileURL.lastPathComponent

            skills.append(
                AgentRuntimeSkill(
                    name: name,
                    title: title,
                    summary: Self.skillSummary(from: text),
                    path: path
                )
            )
        }

        return skills.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func skillTitle(from text: String, fallback: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map(String.init)
            .first { $0.hasPrefix("# ") }?
            .dropFirst(2)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? fallback
    }

    private static func skillSummary(from text: String) -> String {
        let withoutTitle = text.replacingOccurrences(
            of: #"(?m)^#.*$"#,
            with: "",
            options: .regularExpression
        )
        let paragraph = withoutTitle
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        return String(paragraph.prefix(600))
    }

    private func decodeRuntimeMessages(_ value: Any?) -> [AgentMessage] {
        guard let rawMessages = value as? [[String: Any]] else { return [] }
        return rawMessages.compactMap { raw in
            let roleValue = raw["role"] as? String ?? ""
            guard let role = AgentMessageRole(rawValue: roleValue) else { return nil }
            let text = raw["content"] as? String ?? raw["text"] as? String ?? ""
            return AgentMessage(role: role, text: text)
        }
    }

    private func ensureActiveConversation() {
        if !activeConversationId.isEmpty, conversations.contains(where: { $0.id == activeConversationId }) {
            return
        }
        let conversation = AgentConversation()
        conversations.insert(conversation, at: 0)
        activeConversationId = conversation.id
        persistConversationStore()
    }

    private func loadActiveConversation() {
        ensureActiveConversation()
        guard let conversation = conversations.first(where: { $0.id == activeConversationId }) else { return }
        messages = conversation.messages.map { message in
            var copy = message
            copy.isStreaming = false
            return copy
        }
        toolEvents = conversation.toolEvents
        contextSummary = conversation.contextSummary
        pendingAttachments.removeAll()
        permissionRequest = nil
    }

    private func saveActiveConversation() {
        guard !activeConversationId.isEmpty else { return }
        let now = Date()
        let existing = conversations.first(where: { $0.id == activeConversationId })
        let updatedAt = [messages.last?.createdAt, toolEvents.last?.createdAt, now].compactMap { $0 }.max() ?? now
        let generatedTitle = conversationTitle(messages: messages, fallback: "新对话")
        let existingTitle = existing?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = existingTitle.isEmpty || existingTitle == "新对话" ? generatedTitle : existingTitle
        let conversation = AgentConversation(
            id: activeConversationId,
            title: title,
            createdAt: existing?.createdAt ?? now,
            updatedAt: updatedAt,
            isPinned: existing?.isPinned ?? false,
            isArchived: existing?.isArchived ?? false,
            contextSummary: contextSummary,
            messages: messages,
            toolEvents: toolEvents
        )
        if let index = conversations.firstIndex(where: { $0.id == activeConversationId }) {
            conversations[index] = conversation
        } else {
            conversations.insert(conversation, at: 0)
        }
        sortConversations()
        persistConversationStore()
    }

    private func persistConversationStore() {
        sortConversations()
        AgentConfigStore.saveConversationStore(
            AgentConversationStore(activeConversationId: activeConversationId, conversations: conversations)
        )
    }

    private func syncRuntimeHistory() {
        guard isConfigured else { return }
        startRuntimeIfNeeded()
        writeJSON([
            "type": "replace_history",
            "sessionId": activeConversationId,
            "contextSummary": contextSummary,
            "messages": messages.map(\.runtimeHistoryValue),
        ])
    }

    private func conversationTitle(messages: [AgentMessage], fallback: String) -> String {
        guard let firstUserText = messages.first(where: { $0.role == .user })?.text.trimmingCharacters(in: .whitespacesAndNewlines),
              !firstUserText.isEmpty
        else {
            return fallback
        }
        let firstLine = firstUserText.split(whereSeparator: \.isNewline).first.map(String.init) ?? firstUserText
        return firstLine.count > 24 ? String(firstLine.prefix(24)) + "..." : firstLine
    }

    private func updateGeneratedConversationTitle(sessionId: String?, title: String?) {
        let conversationId = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? activeConversationId
        let cleaned = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !conversationId.isEmpty, !cleaned.isEmpty else { return }
        let limited = cleaned.count > 32 ? String(cleaned.prefix(32)) + "..." : cleaned
        if let index = conversations.firstIndex(where: { $0.id == conversationId }) {
            conversations[index].title = limited
            sortConversations()
            persistConversationStore()
        }
    }

    private func sortConversations() {
        conversations.sort { left, right in
            if left.isPinned != right.isPinned {
                return left.isPinned
            }
            return left.updatedAt > right.updatedAt
        }
    }

    private func raiseAttention(_ text: String) {
        attentionText = text
        attentionToken += 1
    }

    private func makeAttachments(from urls: [URL]) -> [AgentAttachment] {
        urls.compactMap { url in
            let standardized = url.standardizedFileURL
            let values = try? standardized.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .isDirectoryKey])
            let isDirectory = values?.isDirectory == true
            let typeIdentifier = values?.contentType?.identifier ?? (isDirectory ? UTType.folder.identifier : UTType.data.identifier)
            let sizeBytes = Int64(values?.fileSize ?? 0)
            return AgentAttachment(
                name: standardized.lastPathComponent,
                path: standardized.path,
                typeIdentifier: typeIdentifier,
                sizeBytes: sizeBytes
            )
        }
    }

    private func runtimeScriptURL() -> URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("AgentRuntime/runtime.mjs"),
            Bundle.module.resourceURL?.appendingPathComponent("AgentRuntime/runtime.mjs"),
            Bundle.module.resourceURL?.appendingPathComponent("Resources/AgentRuntime/runtime.mjs"),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func skillsRootURL() -> URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("AgentRuntime/skills"),
            Bundle.module.resourceURL?.appendingPathComponent("AgentRuntime/skills"),
            Bundle.module.resourceURL?.appendingPathComponent("Resources/AgentRuntime/skills"),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func nodeLaunch() -> (executable: URL, arguments: [String])? {
        let homebrew = URL(fileURLWithPath: "/opt/homebrew/bin/node")
        if FileManager.default.isExecutableFile(atPath: homebrew.path) {
            return (homebrew, [])
        }
        let local = URL(fileURLWithPath: "/usr/local/bin/node")
        if FileManager.default.isExecutableFile(atPath: local.path) {
            return (local, [])
        }
        let env = URL(fileURLWithPath: "/usr/bin/env")
        if FileManager.default.isExecutableFile(atPath: env.path) {
            return (env, ["node"])
        }
        return nil
    }
}

private extension AgentConfig {
    var dictionaryValue: [String: Any] {
        [
            "providerId": providerId,
            "apiProtocol": apiProtocol,
            "baseURL": baseURL,
            "model": model,
            "compactModel": compactModel,
            "headers": headers,
            "temperature": temperature,
            "maxTokens": maxTokens,
            "contextLimit": contextLimit,
            "historyLimit": historyLimit,
            "memoryEnabled": memoryEnabled,
            "userProfileEnabled": userProfileEnabled,
            "memoryCharLimit": memoryCharLimit,
            "userCharLimit": userCharLimit,
            "sessionSearchLimit": sessionSearchLimit,
            "semanticSearchEnabled": semanticSearchEnabled,
            "embeddingModel": embeddingModel,
            "embeddingBaseURL": embeddingBaseURL,
            "autoMemoryEnabled": autoMemoryEnabled,
            "autoTitleEnabled": autoTitleEnabled,
            "evolutionEnabled": evolutionEnabled,
            "lazyModeEnabled": lazyModeEnabled,
            "mcpServers": mcpServers.map(\.dictionaryValue),
            "customSkills": customSkills.map(\.dictionaryValue),
        ]
    }
}

private extension AgentSkillConfig {
    var dictionaryValue: [String: Any] {
        [
            "id": id,
            "name": name,
            "title": title,
            "content": content,
            "enabled": enabled,
        ]
    }
}

private extension AgentAttachment {
    var dictionaryValue: [String: Any] {
        [
            "id": id.uuidString,
            "name": name,
            "path": path,
            "typeIdentifier": typeIdentifier,
            "sizeBytes": sizeBytes,
        ]
    }
}

private extension AgentMessage {
    var runtimeHistoryValue: [String: Any] {
        [
            "role": role.rawValue,
            "content": text,
        ]
    }
}

private extension AgentMCPServerConfig {
    var dictionaryValue: [String: Any] {
        var value: [String: Any] = [
            "id": id,
            "name": name,
            "transport": transport,
            "args": args,
            "headers": headers,
            "env": env,
            "enabled": enabled,
        ]
        if let command { value["command"] = command }
        if let url { value["url"] = url }
        return value
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
