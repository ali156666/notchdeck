import Foundation

enum AgentConfigStore {
    struct ArchivedSessionRecord: Decodable, Equatable {
        var id: String
        var sessionId: String
        var createdAt: String
        var role: String
        var content: String
    }

    static var configDirectory: URL {
        AppSupportDirectory.agent
    }

    static var configURL: URL {
        configDirectory.appendingPathComponent("config.json")
    }

    static var uiHistoryURL: URL {
        configDirectory.appendingPathComponent("ui-history.json")
    }

    static var conversationStoreURL: URL {
        configDirectory.appendingPathComponent("ui-conversations.json")
    }

    static var leakedRegressionBackupURL: URL {
        configDirectory.appendingPathComponent("ui-conversations.pre-regression-fix.json")
    }

    static var archiveRecoveryBackupURL: URL {
        configDirectory.appendingPathComponent("ui-conversations.pre-archive-recovery.json")
    }

    static var deletedConversationIdsURL: URL {
        configDirectory.appendingPathComponent("deleted-conversation-ids.json")
    }

    static var sessionsArchiveURL: URL {
        configDirectory.appendingPathComponent("sessions.jsonl")
    }

    static func loadConfig() -> AgentConfig {
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(AgentConfig.self, from: data)
        else {
            return .default
        }
        return config
    }

    static func saveConfig(_ config: AgentConfig) throws {
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: configURL, options: .atomic)
    }

    static func ensureConfigFile(_ config: AgentConfig) {
        guard !FileManager.default.fileExists(atPath: configURL.path) else { return }
        try? saveConfig(config)
    }

    static func loadMessages() -> [AgentMessage] {
        guard let data = try? Data(contentsOf: uiHistoryURL),
              let messages = try? JSONDecoder().decode([AgentMessage].self, from: data)
        else {
            return []
        }
        return messages
    }

    static func saveMessages(_ messages: [AgentMessage]) {
        do {
            try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(messages.suffix(80)).write(to: uiHistoryURL, options: .atomic)
        } catch {
            NSLog("悬屿 history save failed: \(error)")
        }
    }

    static func loadConversationStore() -> AgentConversationStore {
        if let data = try? Data(contentsOf: conversationStoreURL),
           let store = try? JSONDecoder().decode(AgentConversationStore.self, from: data),
           !store.conversations.isEmpty
        {
            var cleanStore = sanitized(store)
            if let repairedStore = repairingLeakedRegressionFixtures(in: cleanStore) {
                backupLeakedRegressionStore(data)
                cleanStore = repairedStore
            }
            let recoveredStore = recoveringArchivedConversations(
                in: cleanStore,
                records: loadArchivedSessionRecords(),
                deletedIds: loadDeletedConversationIds()
            )
            if recoveredStore != sanitized(store) {
                backupArchiveRecoveryStore(data)
                saveConversationStore(recoveredStore)
            }
            return recoveredStore
        }

        let migratedMessages = loadMessages()
        let conversation = AgentConversation(
            title: title(for: migratedMessages),
            createdAt: migratedMessages.first?.createdAt ?? Date(),
            updatedAt: migratedMessages.last?.createdAt ?? Date(),
            messages: migratedMessages
        )
        let migratedStore = AgentConversationStore(activeConversationId: conversation.id, conversations: [conversation])
        let recoveredStore = recoveringArchivedConversations(
            in: migratedStore,
            records: loadArchivedSessionRecords(),
            deletedIds: loadDeletedConversationIds()
        )
        if recoveredStore != migratedStore {
            saveConversationStore(recoveredStore)
        }
        return recoveredStore
    }

    static func saveConversationStore(_ store: AgentConversationStore) {
        do {
            try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(sanitized(store)).write(to: conversationStoreURL, options: .atomic)
        } catch {
            NSLog("悬屿 conversation save failed: \(error)")
        }
    }

    static func repairingLeakedRegressionFixtures(in store: AgentConversationStore) -> AgentConversationStore? {
        guard store.conversations.contains(where: isLeakedOldSessionFixture) else {
            return nil
        }

        var replacementIdByFixtureId: [String: String] = [:]
        var conversations: [AgentConversation] = []

        for conversation in store.conversations {
            if isLeakedOldSessionFixture(conversation) {
                continue
            }
            if conversation.id == "conversation-b" {
                guard !isDiscardableLeakedActiveSession(conversation) else {
                    continue
                }
                let replacementId = UUID().uuidString
                replacementIdByFixtureId[conversation.id] = replacementId
                conversations.append(
                    AgentConversation(
                        id: replacementId,
                        title: conversation.title,
                        createdAt: conversation.createdAt,
                        updatedAt: conversation.updatedAt,
                        isPinned: conversation.isPinned,
                        isArchived: conversation.isArchived,
                        contextSummary: conversation.contextSummary,
                        messages: conversation.messages,
                        toolEvents: conversation.toolEvents
                    )
                )
                continue
            }
            conversations.append(conversation)
        }

        if conversations.isEmpty {
            conversations = [AgentConversation()]
        }
        let repairedActiveId = replacementIdByFixtureId[store.activeConversationId]
            ?? (conversations.contains { $0.id == store.activeConversationId } ? store.activeConversationId : conversations[0].id)
        return sanitized(AgentConversationStore(activeConversationId: repairedActiveId, conversations: conversations))
    }

    static func recoveringArchivedConversations(
        in store: AgentConversationStore,
        records: [ArchivedSessionRecord],
        deletedIds: Set<String>
    ) -> AgentConversationStore {
        let existingIds = Set(store.conversations.map(\.id))
        let groupedRecords = Dictionary(grouping: records) { $0.sessionId }
        var recoveredConversations: [AgentConversation] = []

        for (sessionId, sessionRecords) in groupedRecords {
            guard !sessionId.isEmpty,
                  !existingIds.contains(sessionId),
                  !deletedIds.contains(sessionId)
            else {
                continue
            }

            let sortedRecords = sessionRecords.sorted { left, right in
                if left.createdAt == right.createdAt {
                    return left.id < right.id
                }
                return left.createdAt < right.createdAt
            }
            var seenRecordIds: Set<String> = []
            let messages = sortedRecords.compactMap { record -> AgentMessage? in
                guard seenRecordIds.insert(record.id).inserted,
                      let role = AgentMessageRole(rawValue: record.role)
                else {
                    return nil
                }
                let text = record.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return AgentMessage(
                    id: UUID(uuidString: record.id) ?? UUID(),
                    role: role,
                    text: text,
                    createdAt: archiveDate(record.createdAt) ?? Date(),
                    isStreaming: false
                )
            }
            guard !messages.isEmpty else { continue }
            recoveredConversations.append(
                AgentConversation(
                    id: sessionId,
                    title: title(for: messages),
                    createdAt: messages.first?.createdAt ?? Date(),
                    updatedAt: messages.last?.createdAt ?? Date(),
                    messages: messages
                )
            )
        }

        guard !recoveredConversations.isEmpty else {
            return sanitized(store)
        }
        return sanitized(
            AgentConversationStore(
                activeConversationId: store.activeConversationId,
                conversations: store.conversations + recoveredConversations
            )
        )
    }

    static func markConversationDeleted(_ conversationId: String) {
        let trimmedId = conversationId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else { return }
        var ids = loadDeletedConversationIds()
        guard ids.insert(trimmedId).inserted else { return }
        do {
            try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(ids.sorted())
            try data.write(to: deletedConversationIdsURL, options: .atomic)
        } catch {
            NSLog("悬屿 deleted conversation marker save failed: \(error)")
        }
    }

    private static func isLeakedOldSessionFixture(_ conversation: AgentConversation) -> Bool {
        guard conversation.id == "conversation-a",
              conversation.title == "A",
              !conversation.isPinned,
              !conversation.isArchived,
              conversation.contextSummary.isEmpty,
              conversation.toolEvents.isEmpty,
              conversation.messages.count == 1,
              let message = conversation.messages.first
        else {
            return false
        }
        return message.role == .assistant
            && message.text == "旧会话结果"
            && !message.isStreaming
            && message.attachments.isEmpty
    }

    private static func isDiscardableLeakedActiveSession(_ conversation: AgentConversation) -> Bool {
        guard conversation.id == "conversation-b",
              !conversation.isPinned,
              !conversation.isArchived,
              conversation.contextSummary.isEmpty,
              conversation.toolEvents.isEmpty
        else {
            return false
        }
        return conversation.messages.allSatisfy { message in
            message.role == .user
                && message.text.trimmingCharacters(in: .whitespacesAndNewlines) == "你好"
                && !message.isStreaming
                && message.attachments.isEmpty
        }
    }

    private static func backupLeakedRegressionStore(_ data: Data) {
        guard !FileManager.default.fileExists(atPath: leakedRegressionBackupURL.path) else {
            return
        }
        do {
            try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
            try data.write(to: leakedRegressionBackupURL, options: .atomic)
        } catch {
            NSLog("悬屿 leaked regression conversation backup failed: \(error)")
        }
    }

    private static func backupArchiveRecoveryStore(_ data: Data) {
        guard !FileManager.default.fileExists(atPath: archiveRecoveryBackupURL.path) else {
            return
        }
        do {
            try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
            try data.write(to: archiveRecoveryBackupURL, options: .atomic)
        } catch {
            NSLog("悬屿 archive recovery conversation backup failed: \(error)")
        }
    }

    private static func loadArchivedSessionRecords() -> [ArchivedSessionRecord] {
        guard let text = try? String(contentsOf: sessionsArchiveURL, encoding: .utf8) else {
            return []
        }
        let decoder = JSONDecoder()
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            try? decoder.decode(ArchivedSessionRecord.self, from: Data(line.utf8))
        }
    }

    private static func loadDeletedConversationIds() -> Set<String> {
        guard let data = try? Data(contentsOf: deletedConversationIdsURL),
              let ids = try? JSONDecoder().decode([String].self, from: data)
        else {
            return []
        }
        return Set(ids)
    }

    private static func archiveDate(_ value: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func sanitized(_ store: AgentConversationStore) -> AgentConversationStore {
        var conversations = store.conversations
            .map { conversation in
                AgentConversation(
                    id: conversation.id,
                    title: conversation.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? title(for: conversation.messages) : conversation.title,
                    createdAt: conversation.createdAt,
                    updatedAt: conversation.updatedAt,
                    isPinned: conversation.isPinned,
                    isArchived: conversation.isArchived,
                    contextSummary: conversation.contextSummary,
                    messages: Array(conversation.messages.suffix(400)),
                    toolEvents: Array(conversation.toolEvents.suffix(80))
                )
            }
            .sorted { left, right in
                if left.isPinned != right.isPinned {
                    return left.isPinned
                }
                return left.updatedAt > right.updatedAt
            }

        if conversations.isEmpty {
            conversations = [AgentConversation()]
        }

        let activeId = conversations.contains { $0.id == store.activeConversationId } ? store.activeConversationId : conversations[0].id
        return AgentConversationStore(activeConversationId: activeId, conversations: Array(conversations.prefix(200)))
    }

    private static func title(for messages: [AgentMessage]) -> String {
        guard let firstUserMessage = messages.first(where: { $0.role == .user })?.text.trimmingCharacters(in: .whitespacesAndNewlines),
              !firstUserMessage.isEmpty
        else {
            return "新对话"
        }
        let firstLine = firstUserMessage.split(whereSeparator: \.isNewline).first.map(String.init) ?? firstUserMessage
        return firstLine.count > 24 ? String(firstLine.prefix(24)) + "..." : firstLine
    }
}
