import Foundation

enum IslandMode: String, Codable, Equatable {
    case dashboard
    case music
    case quickApps
    case clipboard
    case agent
}

enum AgentStatus: String, Codable, Equatable {
    case stopped
    case ready
    case running
    case waitingForPermission
    case error
}

enum AgentMessageRole: String, Codable, Equatable {
    case user
    case assistant
}

struct AgentAttachment: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var path: String
    var typeIdentifier: String
    var sizeBytes: Int64
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        path: String,
        typeIdentifier: String,
        sizeBytes: Int64,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.typeIdentifier = typeIdentifier
        self.sizeBytes = sizeBytes
        self.createdAt = createdAt
    }
}

struct AgentMessage: Identifiable, Codable, Equatable {
    var id: UUID
    var role: AgentMessageRole
    var text: String
    var createdAt: Date
    var isStreaming: Bool
    var attachments: [AgentAttachment]

    init(
        id: UUID = UUID(),
        role: AgentMessageRole,
        text: String,
        createdAt: Date = Date(),
        isStreaming: Bool = false,
        attachments: [AgentAttachment] = []
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.isStreaming = isStreaming
        self.attachments = attachments
    }

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case text
        case createdAt
        case isStreaming
        case attachments
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try container.decode(AgentMessageRole.self, forKey: .role)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        isStreaming = try container.decodeIfPresent(Bool.self, forKey: .isStreaming) ?? false
        attachments = try container.decodeIfPresent([AgentAttachment].self, forKey: .attachments) ?? []
    }
}

struct AgentToolEvent: Identifiable, Codable, Equatable {
    var id: String
    var tool: String
    var summary: String
    var argumentsPreview: String
    var resultPreview: String
    var isPending: Bool
    var isApproved: Bool?
    var createdAt: Date

    init(
        id: String,
        tool: String,
        summary: String = "",
        argumentsPreview: String = "",
        resultPreview: String = "",
        isPending: Bool = true,
        isApproved: Bool? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.tool = tool
        self.summary = summary
        self.argumentsPreview = argumentsPreview
        self.resultPreview = resultPreview
        self.isPending = isPending
        self.isApproved = isApproved
        self.createdAt = createdAt
    }
}

struct AgentConversation: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var isPinned: Bool
    var isArchived: Bool
    var contextSummary: String
    var messages: [AgentMessage]
    var toolEvents: [AgentToolEvent]

    init(
        id: String = UUID().uuidString,
        title: String = "新对话",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isPinned: Bool = false,
        isArchived: Bool = false,
        contextSummary: String = "",
        messages: [AgentMessage] = [],
        toolEvents: [AgentToolEvent] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.contextSummary = contextSummary
        self.messages = messages
        self.toolEvents = toolEvents
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case createdAt
        case updatedAt
        case isPinned
        case isArchived
        case contextSummary
        case messages
        case toolEvents
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "新对话"
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isArchived = try container.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        contextSummary = try container.decodeIfPresent(String.self, forKey: .contextSummary) ?? ""
        messages = try container.decodeIfPresent([AgentMessage].self, forKey: .messages) ?? []
        toolEvents = try container.decodeIfPresent([AgentToolEvent].self, forKey: .toolEvents) ?? []
    }

    var previewText: String {
        messages.reversed().first { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "空白对话"
    }
}

struct AgentConversationStore: Codable, Equatable {
    var activeConversationId: String
    var conversations: [AgentConversation]

    init(activeConversationId: String, conversations: [AgentConversation]) {
        self.activeConversationId = activeConversationId
        self.conversations = conversations
    }
}

struct AgentPermissionRequest: Identifiable, Codable, Equatable {
    var id: String
    var tool: String
    var source: String
    var summary: String
    var argumentsPreview: String
}

struct AgentMemoryEntry: Identifiable, Codable, Equatable {
    var id: String
    var target: String
    var index: Int
    var text: String

    init(id: String, target: String, index: Int, text: String) {
        self.id = id
        self.target = target
        self.index = index
        self.text = text
    }

    enum CodingKeys: String, CodingKey {
        case id
        case target
        case index
        case text
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decodeIfPresent(String.self, forKey: .target) ?? "memory"
        index = try container.decodeIfPresent(Int.self, forKey: .index) ?? 0
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? "\(target):\(index)"
    }
}

struct AgentEvolutionCandidate: Identifiable, Codable, Equatable {
    var id: String
    var skill: String
    var title: String
    var reason: String
    var content: String
    var currentContent: String
    var currentSummary: String
    var status: String
    var createdAt: String
    var appliedAt: String?
    var rejectedAt: String?
    var rejectionReason: String?
    var evidence: [String]

    var isProposed: Bool {
        status == "proposed"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case skill
        case title
        case reason
        case content
        case currentContent
        case currentSummary
        case status
        case createdAt
        case appliedAt
        case rejectedAt
        case rejectionReason
        case evidence
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        skill = try container.decodeIfPresent(String.self, forKey: .skill) ?? "skill"
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? skill
        reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? ""
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        currentContent = try container.decodeIfPresent(String.self, forKey: .currentContent) ?? ""
        currentSummary = try container.decodeIfPresent(String.self, forKey: .currentSummary) ?? ""
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "proposed"
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        appliedAt = try container.decodeIfPresent(String.self, forKey: .appliedAt)
        rejectedAt = try container.decodeIfPresent(String.self, forKey: .rejectedAt)
        rejectionReason = try container.decodeIfPresent(String.self, forKey: .rejectionReason)
        evidence = try container.decodeIfPresent([String].self, forKey: .evidence) ?? []
    }
}

struct AgentMCPServerConfig: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var transport: String
    var command: String?
    var args: [String]
    var url: String?
    var headers: [String: String]
    var env: [String: String]
    var enabled: Bool

    init(
        id: String = UUID().uuidString,
        name: String,
        transport: String,
        command: String? = nil,
        args: [String] = [],
        url: String? = nil,
        headers: [String: String] = [:],
        env: [String: String] = [:],
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.command = command
        self.args = args
        self.url = url
        self.headers = headers
        self.env = env
        self.enabled = enabled
    }
}

struct AgentSkillConfig: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var title: String
    var content: String
    var enabled: Bool

    init(
        id: String = UUID().uuidString,
        name: String,
        title: String,
        content: String,
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.title = title
        self.content = content
        self.enabled = enabled
    }
}

struct AgentRuntimeSkill: Codable, Equatable, Identifiable {
    var id: String { name }
    var name: String
    var title: String
    var summary: String
    var path: String

    init(name: String, title: String = "", summary: String = "", path: String = "") {
        self.name = name
        self.title = title.isEmpty ? name : title
        self.summary = summary
        self.path = path
    }

    var sourceLabel: String {
        path.hasPrefix("config:") ? "配置" : "文件"
    }
}

struct AgentConfig: Codable, Equatable {
    var providerId: String
    var apiProtocol: String
    var baseURL: String
    var model: String
    var compactModel: String
    var apiKey: String
    var headers: [String: String]
    var temperature: Double
    var maxTokens: Int
    var contextLimit: Int
    var historyLimit: Int
    var memoryEnabled: Bool
    var userProfileEnabled: Bool
    var memoryCharLimit: Int
    var userCharLimit: Int
    var sessionSearchLimit: Int
    var semanticSearchEnabled: Bool
    var embeddingModel: String
    var embeddingBaseURL: String
    var autoMemoryEnabled: Bool
    var autoTitleEnabled: Bool
    var evolutionEnabled: Bool
    var lazyModeEnabled: Bool
    var mcpServers: [AgentMCPServerConfig]
    var customSkills: [AgentSkillConfig]

    init(
        providerId: String,
        apiProtocol: String = "openai",
        baseURL: String,
        model: String,
        compactModel: String = "",
        apiKey: String = "",
        headers: [String: String],
        temperature: Double,
        maxTokens: Int,
        contextLimit: Int = 1_000_000,
        historyLimit: Int,
        memoryEnabled: Bool = true,
        userProfileEnabled: Bool = true,
        memoryCharLimit: Int = 2200,
        userCharLimit: Int = 1375,
        sessionSearchLimit: Int = 8,
        semanticSearchEnabled: Bool = true,
        embeddingModel: String = "",
        embeddingBaseURL: String = "",
        autoMemoryEnabled: Bool = true,
        autoTitleEnabled: Bool = true,
        evolutionEnabled: Bool = true,
        lazyModeEnabled: Bool = false,
        mcpServers: [AgentMCPServerConfig],
        customSkills: [AgentSkillConfig] = []
    ) {
        self.providerId = providerId
        self.apiProtocol = apiProtocol
        self.baseURL = baseURL
        self.model = model
        self.compactModel = compactModel
        self.apiKey = apiKey
        self.headers = headers
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.contextLimit = contextLimit
        self.historyLimit = historyLimit
        self.memoryEnabled = memoryEnabled
        self.userProfileEnabled = userProfileEnabled
        self.memoryCharLimit = memoryCharLimit
        self.userCharLimit = userCharLimit
        self.sessionSearchLimit = sessionSearchLimit
        self.semanticSearchEnabled = semanticSearchEnabled
        self.embeddingModel = embeddingModel
        self.embeddingBaseURL = embeddingBaseURL
        self.autoMemoryEnabled = autoMemoryEnabled
        self.autoTitleEnabled = autoTitleEnabled
        self.evolutionEnabled = evolutionEnabled
        self.lazyModeEnabled = lazyModeEnabled
        self.mcpServers = mcpServers
        self.customSkills = customSkills
    }

    enum CodingKeys: String, CodingKey {
        case providerId
        case apiProtocol
        case baseURL
        case model
        case compactModel
        case apiKey
        case headers
        case temperature
        case maxTokens
        case contextLimit
        case historyLimit
        case memoryEnabled
        case userProfileEnabled
        case memoryCharLimit
        case userCharLimit
        case sessionSearchLimit
        case semanticSearchEnabled
        case embeddingModel
        case embeddingBaseURL
        case autoMemoryEnabled
        case autoTitleEnabled
        case evolutionEnabled
        case lazyModeEnabled
        case mcpServers
        case customSkills
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerId = try container.decodeIfPresent(String.self, forKey: .providerId) ?? "default"
        apiProtocol = try container.decodeIfPresent(String.self, forKey: .apiProtocol) ?? "openai"
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? "https://api.openai.com/v1"
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? "gpt-4.1-mini"
        compactModel = try container.decodeIfPresent(String.self, forKey: .compactModel) ?? ""
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature) ?? 0.2
        maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens) ?? 4096
        contextLimit = try container.decodeIfPresent(Int.self, forKey: .contextLimit) ?? 1_000_000
        historyLimit = try container.decodeIfPresent(Int.self, forKey: .historyLimit) ?? 40
        memoryEnabled = try container.decodeIfPresent(Bool.self, forKey: .memoryEnabled) ?? true
        userProfileEnabled = try container.decodeIfPresent(Bool.self, forKey: .userProfileEnabled) ?? true
        memoryCharLimit = try container.decodeIfPresent(Int.self, forKey: .memoryCharLimit) ?? 2200
        userCharLimit = try container.decodeIfPresent(Int.self, forKey: .userCharLimit) ?? 1375
        sessionSearchLimit = try container.decodeIfPresent(Int.self, forKey: .sessionSearchLimit) ?? 8
        semanticSearchEnabled = try container.decodeIfPresent(Bool.self, forKey: .semanticSearchEnabled) ?? true
        embeddingModel = try container.decodeIfPresent(String.self, forKey: .embeddingModel) ?? ""
        embeddingBaseURL = try container.decodeIfPresent(String.self, forKey: .embeddingBaseURL) ?? ""
        autoMemoryEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoMemoryEnabled) ?? true
        autoTitleEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoTitleEnabled) ?? true
        evolutionEnabled = try container.decodeIfPresent(Bool.self, forKey: .evolutionEnabled) ?? true
        lazyModeEnabled = try container.decodeIfPresent(Bool.self, forKey: .lazyModeEnabled) ?? false
        mcpServers = try container.decodeIfPresent([AgentMCPServerConfig].self, forKey: .mcpServers) ?? []
        customSkills = try container.decodeIfPresent([AgentSkillConfig].self, forKey: .customSkills) ?? []
    }

    static let `default` = AgentConfig(
        providerId: "default",
        apiProtocol: "openai",
        baseURL: "https://api.openai.com/v1",
        model: "gpt-4.1-mini",
        compactModel: "",
        apiKey: "",
        headers: [:],
        temperature: 0.2,
        maxTokens: 4096,
        contextLimit: 1_000_000,
        historyLimit: 40,
        memoryEnabled: true,
        userProfileEnabled: true,
        memoryCharLimit: 2200,
        userCharLimit: 1375,
        sessionSearchLimit: 8,
        semanticSearchEnabled: true,
        embeddingModel: "",
        embeddingBaseURL: "",
        autoMemoryEnabled: true,
        autoTitleEnabled: true,
        evolutionEnabled: true,
        lazyModeEnabled: false,
        mcpServers: [],
        customSkills: []
    )
}
