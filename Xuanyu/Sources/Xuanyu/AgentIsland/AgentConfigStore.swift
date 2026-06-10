import Foundation

enum AgentConfigStore {
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
            return sanitized(store)
        }

        let migratedMessages = loadMessages()
        let conversation = AgentConversation(
            title: title(for: migratedMessages),
            createdAt: migratedMessages.first?.createdAt ?? Date(),
            updatedAt: migratedMessages.last?.createdAt ?? Date(),
            messages: migratedMessages
        )
        return AgentConversationStore(activeConversationId: conversation.id, conversations: [conversation])
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
