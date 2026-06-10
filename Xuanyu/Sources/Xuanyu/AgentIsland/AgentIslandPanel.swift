import SwiftUI
import UniformTypeIdentifiers

struct AgentIslandPanel: View {
    var service: AgentService
    @Binding var showsConfiguration: Bool
    @Binding var settingsTab: AgentSettingsTab
    @State private var draft = ""
    @State private var draftConfig = AgentConfig.default
    @State private var showsFilePicker = false
    @State private var isFileDropTargeted = false
    @State private var showsLazyModeAlert = false
    @State private var conversationSearchText = ""
    @State private var showsArchivedConversations = false

    var body: some View {
        VStack(spacing: 12) {
            statusBar
            if !service.isConfigured || showsConfiguration {
                settingsView
            } else {
                agentWorkspace
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .onAppear(perform: syncConfigFields)
        .alert("开启懒人模式？", isPresented: $showsLazyModeAlert) {
            Button("取消", role: .cancel) {
                draftConfig.lazyModeEnabled = false
            }
            Button("开启", role: .destructive) {
                draftConfig.lazyModeEnabled = true
            }
        } message: {
            Text("开启后 shell、写文件、Skill 脚本、未知风险 MCP 工具会自动执行，不再逐条弹出权限确认。")
        }
        .overlay(fileDropOverlay)
        .onDrop(of: AgentFileDrop.typeIdentifiers, isTargeted: $isFileDropTargeted, perform: handleFileDrop)
        .fileImporter(isPresented: $showsFilePicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result {
                service.addAttachmentURLs(urls)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(service.statusText)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(1)

            Label("\(service.knownSkills.count)", systemImage: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))

            Label("\(service.connectedMCPServers.count)", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))

            Label("\(service.evolutionCandidateCount)", systemImage: "arrow.triangle.branch")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))

            Spacer(minLength: 8)

            newConversationToolbarButton

            Button {
                syncConfigFields()
                showsConfiguration.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(AgentIconButtonStyle(selected: showsConfiguration || !service.isConfigured))
            .help("悬屿设置")

            Button {
                service.cancel()
            } label: {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(AgentIconButtonStyle(selected: service.isBusy))
            .disabled(!service.isBusy)
            .help("停止")
        }
    }

    private var newConversationToolbarButton: some View {
        Button {
            startNewConversation()
        } label: {
            Label("新对话", systemImage: "square.and.pencil")
        }
        .buttonStyle(AgentCapsuleButtonStyle())
        .help("新建空白对话")
    }

    private var agentWorkspace: some View {
        HStack(alignment: .top, spacing: 12) {
            conversationSidebar
            VStack(spacing: 10) {
                content
                    .layoutPriority(0)
                composer
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var conversationSidebar: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Label("对话", systemImage: "text.bubble")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.82))
                Spacer(minLength: 4)
                Button {
                    showsArchivedConversations.toggle()
                } label: {
                    Image(systemName: showsArchivedConversations ? "archivebox.fill" : "archivebox")
                }
                .buttonStyle(AgentIconButtonStyle(selected: showsArchivedConversations))
                .help(showsArchivedConversations ? "隐藏归档" : "显示归档")
                Button {
                    startNewConversation()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(AgentIconButtonStyle())
                .help("新对话")
            }

            TextField("搜索对话", text: $conversationSearchText)
                .textFieldStyle(.plain)
                .agentField()
                .font(.system(size: 11, weight: .semibold))

            ScrollView {
                LazyVStack(spacing: 6) {
                    if filteredConversations.isEmpty {
                        Text(showsArchivedConversations ? "没有归档对话" : "没有匹配对话")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.36))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 12)
                    }
                    ForEach(filteredConversations) { conversation in
                        AgentConversationRow(
                            conversation: conversation,
                            selected: conversation.id == service.activeConversationId,
                            onSelect: {
                                service.selectConversation(conversation)
                            },
                            onTogglePin: {
                                service.togglePinnedConversation(conversation)
                            },
                            onToggleArchive: {
                                if conversation.isArchived {
                                    service.unarchiveConversation(conversation)
                                } else {
                                    service.archiveConversation(conversation)
                                }
                            },
                            onDelete: {
                                service.deleteConversation(conversation)
                            }
                        )
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(10)
        .frame(width: 176)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var settingsView: some View {
        VStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(AgentSettingsTab.allCases) { tab in
                    AgentSettingsTabButton(tab: tab, selected: settingsTab == tab) {
                        settingsTab = tab
                    }
                }
                Spacer(minLength: 8)
                Button {
                    syncConfigFields()
                    showsConfiguration = false
                } label: {
                    Label("返回", systemImage: "chevron.left")
                }
                .buttonStyle(AgentCapsuleButtonStyle())
                .help("返回对话，不保存当前草稿配置")
                Button("保存并启动") {
                    service.saveConfiguration(draftConfig)
                    syncConfigFields()
                    showsConfiguration = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            ScrollView {
                switch settingsTab {
                case .model:
                    modelSettings
                case .memory:
                    memorySettings
                case .skills:
                    skillsSettings
                case .mcp:
                    mcpSettings
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            if settingsTab == .memory {
                service.refreshMemoryAudit()
            }
        }
        .onChange(of: settingsTab) { _, tab in
            if tab == .memory {
                service.refreshMemoryAudit()
            }
        }
    }

    private var memorySettings: some View {
        SettingsSection(title: "长期记忆与自进化", icon: "brain.head.profile") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("参考 Hermes Agent：关键记忆有界注入，完整会话按需检索；Skill 演化先生成候选，审核后才写入。")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.52))
                    Spacer(minLength: 8)
                    Button {
                        service.refreshMemoryAudit()
                    } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                HStack(spacing: 12) {
                    MemorySettingCard(
                        title: "MEMORY.md",
                        subtitle: "环境、约定、纠错和可复用经验",
                        usage: service.memoryUsageText,
                        isEnabled: $draftConfig.memoryEnabled,
                        limit: $draftConfig.memoryCharLimit
                    )
                    MemorySettingCard(
                        title: "USER.md",
                        subtitle: "偏好、表达方式和工作习惯",
                        usage: service.userMemoryUsageText,
                        isEnabled: $draftConfig.userProfileEnabled,
                        limit: $draftConfig.userCharLimit
                    )
                }

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 7) {
                        Label("跨会话检索", systemImage: "magnifyingglass")
                            .font(.system(size: 12, weight: .bold))
                        Toggle(isOn: $draftConfig.semanticSearchEnabled) {
                            Text("Embedding 语义检索")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .toggleStyle(.switch)
                        Text("完整聊天写入 sessions.jsonl，并同步生成本地向量索引。")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.48))
                        Stepper(value: $draftConfig.sessionSearchLimit, in: 1...1000) {
                            Text("最多 \(draftConfig.sessionSearchLimit) 条")
                                .font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .agentSettingCard()

                    VStack(alignment: .leading, spacing: 7) {
                        Toggle(isOn: $draftConfig.autoMemoryEnabled) {
                            Label("自动提取记忆", systemImage: "wand.and.stars")
                                .font(.system(size: 12, weight: .bold))
                        }
                        Toggle(isOn: $draftConfig.autoTitleEnabled) {
                            Label("自动生成标题", systemImage: "text.cursor")
                                .font(.system(size: 12, weight: .bold))
                        }
                        Divider()
                            .background(.white.opacity(0.12))
                        Toggle(isOn: $draftConfig.evolutionEnabled) {
                            Label("Skill 自进化", systemImage: "arrow.triangle.branch")
                                .font(.system(size: 12, weight: .bold))
                        }
                        Text("待审核候选 \(service.evolutionCandidateCount) 个。应用候选时仍需权限确认。")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.48))
                    }
                    .agentSettingCard()
                }

                HStack(spacing: 10) {
                    TextField("Embedding Model（空则用本地轻量向量）", text: $draftConfig.embeddingModel)
                        .textFieldStyle(.plain)
                        .agentField()
                    TextField("Embedding Base URL（空则跟随 Base URL）", text: $draftConfig.embeddingBaseURL)
                        .textFieldStyle(.plain)
                        .agentField()
                }

                HStack(alignment: .top, spacing: 12) {
                    MemoryAuditList(
                        title: "MEMORY 条目",
                        entries: service.memoryEntries,
                        emptyText: "还没有项目记忆。",
                        onSave: { entry, text in service.replaceMemoryEntry(entry, with: text) },
                        onDelete: service.deleteMemoryEntry
                    )
                    MemoryAuditList(
                        title: "USER 条目",
                        entries: service.userMemoryEntries,
                        emptyText: "还没有用户画像。",
                        onSave: { entry, text in service.replaceMemoryEntry(entry, with: text) },
                        onDelete: service.deleteMemoryEntry
                    )
                }

                EvolutionCandidateList(
                    candidates: service.evolutionCandidates,
                    onApply: service.applyEvolutionCandidate,
                    onReject: service.rejectEvolutionCandidate
                )
            }
        }
    }

    private var modelSettings: some View {
        SettingsSection(title: "模型", icon: "cpu") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Picker("协议", selection: $draftConfig.apiProtocol) {
                        Text("OpenAI").tag("openai")
                        Text("Anthropic").tag("anthropic")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                    TextField("Provider", text: $draftConfig.providerId)
                        .textFieldStyle(.plain)
                        .agentField()
                        .frame(width: 130)
                    TextField("服务根地址", text: $draftConfig.baseURL)
                        .textFieldStyle(.plain)
                        .agentField()
                    TextField("Model", text: $draftConfig.model)
                        .textFieldStyle(.plain)
                        .agentField()
                        .frame(width: 180)
                }
                SecureField("API Key", text: $draftConfig.apiKey)
                    .textFieldStyle(.plain)
                    .agentField()
                HStack(spacing: 10) {
                    TextField("压缩模型（空则跟随 Model）", text: $draftConfig.compactModel)
                        .textFieldStyle(.plain)
                        .agentField()
                    Text("上下文达到 80% 时自动压缩")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.46))
                }
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Temperature")
                            .settingsCaption()
                        Slider(value: $draftConfig.temperature, in: 0...2)
                            .frame(width: 220)
                    }
                    Text(String(format: "%.1f", draftConfig.temperature))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 38, alignment: .leading)
                    TextField("Max tokens", value: $draftConfig.maxTokens, format: .number)
                        .textFieldStyle(.plain)
                        .agentField()
                        .frame(width: 120)
                    TextField("Context", value: $draftConfig.contextLimit, format: .number)
                        .textFieldStyle(.plain)
                        .agentField()
                        .frame(width: 120)
                    TextField("History", value: $draftConfig.historyLimit, format: .number)
                        .textFieldStyle(.plain)
                        .agentField()
                        .frame(width: 100)
                }
                Toggle(isOn: lazyModeBinding) {
                    Label("懒人模式", systemImage: "bolt.shield")
                        .font(.system(size: 12, weight: .bold))
                }
                .toggleStyle(.switch)
                .padding(11)
                .background(lazyModeBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text("开启后危险工具自动放行；关闭时继续逐条确认。保存并启动后生效。")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.46))
            }
        }
    }

    private var skillsSettings: some View {
        SettingsSection(title: "Skills", icon: "sparkles") {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 7) {
                        Label("已加载 Skills", systemImage: "checkmark.seal")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white.opacity(0.76))
                        Text("\(service.knownSkills.count)")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.42))
                        Spacer()
                    }

                    if service.knownSkills.isEmpty {
                        EmptyConfigHint(text: "runtime 还没有上报已加载 skill。保存并启动后会刷新。")
                    } else {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(service.knownSkills) { skill in
                                AgentRuntimeSkillRow(skill: skill)
                            }
                        }
                    }
                }

                HStack {
                    Text("下面添加的是 App 配置里的自定义 skill，会和文件目录里的 skills 一起加载。")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.52))
                    Spacer()
                    Button {
                        draftConfig.customSkills.append(
                            AgentSkillConfig(
                                name: "custom-skill",
                                title: "Custom Skill",
                                content: "# Custom Skill\n\nUse this skill when the request matches your custom workflow.\n\n## Workflow\n\n1. Inspect the task.\n2. Use tools when needed.\n3. Return concise results."
                            )
                        )
                    } label: {
                        Label("新增 Skill", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if draftConfig.customSkills.isEmpty {
                    EmptyConfigHint(text: "还没有 App 配置自定义 skill。")
                }

                ForEach(draftConfig.customSkills.indices, id: \.self) { index in
                    skillEditor(index: index)
                }
            }
        }
    }

    private func skillEditor(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Toggle("", isOn: $draftConfig.customSkills[index].enabled)
                    .labelsHidden()
                TextField("name", text: $draftConfig.customSkills[index].name)
                    .textFieldStyle(.plain)
                    .agentField()
                    .frame(width: 170)
                TextField("title", text: $draftConfig.customSkills[index].title)
                    .textFieldStyle(.plain)
                    .agentField()
                Button {
                    draftConfig.customSkills.remove(at: index)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(AgentIconButtonStyle())
            }
            TextEditor(text: $draftConfig.customSkills[index].content)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.86))
                .scrollContentBackground(.hidden)
                .padding(9)
                .frame(minHeight: 110)
                .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(12)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var mcpSettings: some View {
        SettingsSection(title: "MCP Servers", icon: "point.3.connected.trianglepath.dotted") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("配置文件归 App 自己管理，支持 stdio、SSE、streamable HTTP。")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.52))
                    Spacer()
                    Button {
                        draftConfig.mcpServers.append(
                            AgentMCPServerConfig(name: "local-mcp", transport: "stdio", command: "npx", args: ["-y", "server-name"])
                        )
                    } label: {
                        Label("新增 MCP", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if draftConfig.mcpServers.isEmpty {
                    EmptyConfigHint(text: "还没有 MCP server。")
                }

                ForEach(draftConfig.mcpServers.indices, id: \.self) { index in
                    mcpEditor(index: index)
                }
            }
        }
    }

    private func mcpEditor(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Toggle("", isOn: $draftConfig.mcpServers[index].enabled)
                    .labelsHidden()
                TextField("name", text: $draftConfig.mcpServers[index].name)
                    .textFieldStyle(.plain)
                    .agentField()
                    .frame(width: 160)
                Picker("", selection: $draftConfig.mcpServers[index].transport) {
                    Text("stdio").tag("stdio")
                    Text("SSE").tag("sse")
                    Text("HTTP").tag("streamable_http")
                }
                .pickerStyle(.segmented)
                .frame(width: 230)
                Button {
                    draftConfig.mcpServers.remove(at: index)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(AgentIconButtonStyle())
            }

            if draftConfig.mcpServers[index].transport == "stdio" {
                HStack(spacing: 10) {
                    TextField("command", text: optionalStringBinding(for: index, keyPath: \.command))
                        .textFieldStyle(.plain)
                        .agentField()
                        .frame(width: 210)
                    TextField("args，用空格分隔", text: argsTextBinding(for: index))
                        .textFieldStyle(.plain)
                        .agentField()
                }
            } else {
                TextField("url", text: optionalStringBinding(for: index, keyPath: \.url))
                    .textFieldStyle(.plain)
                    .agentField()
            }

            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Headers")
                        .settingsCaption()
                    TextEditor(text: dictionaryTextBinding(for: index, keyPath: \.headers))
                        .settingsTextEditor(height: 70)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("Env")
                        .settingsCaption()
                    TextEditor(text: dictionaryTextBinding(for: index, keyPath: \.env))
                        .settingsTextEditor(height: 70)
                }
            }
        }
        .padding(12)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var content: some View {
        messagesPane
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var messagesPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if service.messages.isEmpty && service.toolEvents.isEmpty {
                        emptyState
                    }
                    ForEach(timelineItems) { item in
                        switch item {
                        case let .message(message):
                            MessageBubble(message: message)
                                .id(item.id)
                        case let .tool(event):
                            ToolEventRow(event: event)
                                .id(item.id)
                        }
                    }
                    if let request = service.permissionRequest {
                        PermissionCard(request: request) {
                            service.approvePermission()
                        } onDeny: {
                            service.denyPermission()
                        }
                        .id("permission-\(request.id)")
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("timeline-bottom")
                }
                .padding(.vertical, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                scrollTimelineToBottomAfterLayout(proxy)
            }
            .onChange(of: service.activeConversationId) { _, _ in
                scrollTimelineToBottomAfterLayout(proxy)
            }
            .onChange(of: service.messages.count) { _, _ in
                scrollTimelineToBottom(proxy)
            }
            .onChange(of: service.toolEvents.count) { _, _ in
                scrollTimelineToBottom(proxy)
            }
            .onChange(of: service.permissionRequest?.id ?? "") { _, _ in
                scrollTimelineToBottom(proxy)
            }
            .onChange(of: service.messages.last?.text ?? "") { _, _ in
                scrollTimelineToBottom(proxy)
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !service.pendingAttachments.isEmpty {
                attachmentStrip
            }

            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    startNewConversation()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(AgentIconButtonStyle())
                .help("新对话")

                Button {
                    showsFilePicker = true
                } label: {
                    Image(systemName: "paperclip")
                }
                .buttonStyle(AgentIconButtonStyle())
                .help("上传文件")

                TextField("跟悬屿说点什么，或拖文件到岛里", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .submitLabel(.send)
                    .agentField()
                    .frame(minHeight: 36)
                    .layoutPriority(1)
                    .onSubmit(sendDraft)

                Button {
                    sendDraft()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 34, height: 34)
                        .background(service.isConfigured ? .white : .white.opacity(0.18), in: Circle())
                        .foregroundStyle(service.isConfigured ? .black : .white.opacity(0.46))
                }
                .buttonStyle(.plain)
                .disabled(!service.isConfigured || (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && service.pendingAttachments.isEmpty))
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(service.pendingAttachments) { attachment in
                    AttachmentChip(attachment: attachment) {
                        service.removeAttachment(attachment)
                    }
                }
            }
        }
        .frame(height: 30)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("悬屿已就位")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
            Text("支持 OpenAI-compatible 模型、App 内置 skills、MCP 工具和危险操作确认。")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.56))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 30)
    }

    private var statusColor: Color {
        switch service.status {
        case .ready: Color(red: 0.36, green: 1.0, blue: 0.52)
        case .running: Color(red: 0.42, green: 0.78, blue: 1.0)
        case .waitingForPermission: Color(red: 1.0, green: 0.78, blue: 0.32)
        case .error: Color(red: 1.0, green: 0.34, blue: 0.34)
        case .stopped: Color.white.opacity(0.35)
        }
    }

    private func syncConfigFields() {
        draftConfig = service.config
        draftConfig.apiKey = service.apiKey
    }

    private var lazyModeBinding: Binding<Bool> {
        Binding {
            draftConfig.lazyModeEnabled
        } set: { value in
            if value {
                showsLazyModeAlert = true
            } else {
                draftConfig.lazyModeEnabled = false
            }
        }
    }

    private var lazyModeBackground: Color {
        draftConfig.lazyModeEnabled ? Color(red: 0.36, green: 0.22, blue: 0.05).opacity(0.58) : .white.opacity(0.055)
    }

    private var timelineItems: [AgentTimelineItem] {
        let messageItems = service.messages.map(AgentTimelineItem.message)
        let toolItems = service.toolEvents.map(AgentTimelineItem.tool)
        return (messageItems + toolItems).sorted { left, right in
            if left.createdAt == right.createdAt {
                return left.id < right.id
            }
            return left.createdAt < right.createdAt
        }
    }

    private var filteredConversations: [AgentConversation] {
        let query = conversationSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return service.conversations.filter { conversation in
            if !showsArchivedConversations && conversation.isArchived {
                return false
            }
            guard !query.isEmpty else {
                return true
            }
            let haystack = ([conversation.title, conversation.previewText] + conversation.messages.suffix(20).map(\.text))
                .joined(separator: "\n")
                .lowercased()
            return haystack.contains(query)
        }
    }

    private func scrollTimelineToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        let action = {
            proxy.scrollTo("timeline-bottom", anchor: .bottom)
        }
        if animated {
            withAnimation(.snappy(duration: 0.2), action)
        } else {
            action()
        }
    }

    private func scrollTimelineToBottomAfterLayout(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            scrollTimelineToBottom(proxy, animated: false)
            DispatchQueue.main.async {
                scrollTimelineToBottom(proxy, animated: false)
            }
        }
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !service.pendingAttachments.isEmpty else { return }
        if handleSlashCommand(text) {
            draft = ""
            return
        }
        draft = ""
        service.send(text)
    }

    private func handleSlashCommand(_ text: String) -> Bool {
        switch text.lowercased() {
        case "/new":
            startNewConversation()
            return true
        case "/clear":
            service.clearCurrentConversation()
            return true
        case "/compact":
            service.compactConversation()
            return true
        default:
            return false
        }
    }

    private var fileDropOverlay: some View {
        Group {
            if isFileDropTargeted {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.78), lineWidth: 2)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
                    .overlay {
                        Label("松开添加到输入栏", systemImage: "doc.badge.plus")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(.black.opacity(0.72), in: Capsule())
                    }
                    .allowsHitTesting(false)
            }
        }
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        return AgentFileDrop.loadFileURLs(from: providers) { urls in
            service.addAttachmentURLs(urls)
        }
    }

    private func startNewConversation() {
        draft = ""
        service.startNewConversation()
    }

    private func optionalStringBinding(for index: Int, keyPath: WritableKeyPath<AgentMCPServerConfig, String?>) -> Binding<String> {
        Binding {
            guard draftConfig.mcpServers.indices.contains(index) else { return "" }
            return draftConfig.mcpServers[index][keyPath: keyPath] ?? ""
        } set: { value in
            guard draftConfig.mcpServers.indices.contains(index) else { return }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            draftConfig.mcpServers[index][keyPath: keyPath] = trimmed.isEmpty ? nil : trimmed
        }
    }

    private func argsTextBinding(for index: Int) -> Binding<String> {
        Binding {
            guard draftConfig.mcpServers.indices.contains(index) else { return "" }
            return draftConfig.mcpServers[index].args.joined(separator: " ")
        } set: { value in
            guard draftConfig.mcpServers.indices.contains(index) else { return }
            draftConfig.mcpServers[index].args = value
                .split(separator: " ")
                .map(String.init)
                .filter { !$0.isEmpty }
        }
    }

    private func dictionaryTextBinding(for index: Int, keyPath: WritableKeyPath<AgentMCPServerConfig, [String: String]>) -> Binding<String> {
        Binding {
            guard draftConfig.mcpServers.indices.contains(index) else { return "" }
            return draftConfig.mcpServers[index][keyPath: keyPath]
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "\n")
        } set: { value in
            guard draftConfig.mcpServers.indices.contains(index) else { return }
            draftConfig.mcpServers[index][keyPath: keyPath] = parseKeyValueLines(value)
        }
    }

    private func parseKeyValueLines(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                values[key] = value
            }
        }
        return values
    }
}

private enum AgentTimelineItem: Identifiable {
    case message(AgentMessage)
    case tool(AgentToolEvent)

    var id: String {
        switch self {
        case let .message(message):
            "message-\(message.id.uuidString)"
        case let .tool(event):
            "tool-\(event.id)"
        }
    }

    var createdAt: Date {
        switch self {
        case let .message(message):
            message.createdAt
        case let .tool(event):
            event.createdAt
        }
    }
}

enum AgentSettingsTab: String, CaseIterable, Identifiable {
    case model = "模型"
    case memory = "记忆"
    case skills = "Skills"
    case mcp = "MCP"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .model: "cpu"
        case .memory: "brain.head.profile"
        case .skills: "sparkles"
        case .mcp: "point.3.connected.trianglepath.dotted"
        }
    }
}

private struct AgentSettingsTabButton: View {
    let tab: AgentSettingsTab
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(tab.rawValue, systemImage: tab.icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(selected ? .black : .white.opacity(0.66))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(selected ? .white : .white.opacity(0.075), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct AgentConversationRow: View {
    let conversation: AgentConversation
    let selected: Bool
    let onSelect: () -> Void
    let onTogglePin: () -> Void
    let onToggleArchive: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        if conversation.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 8, weight: .bold))
                        }
                        if conversation.isArchived {
                            Image(systemName: "archivebox.fill")
                                .font(.system(size: 8, weight: .bold))
                        }
                        Text(conversation.title)
                            .lineLimit(1)
                    }
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(selected ? .black : .white.opacity(0.82))
                    Text(conversation.previewText)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(selected ? .black.opacity(0.58) : .white.opacity(0.45))
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text("\(conversation.messages.count) 条")
                        Text(conversation.updatedAt.formatted(date: .omitted, time: .shortened))
                    }
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(selected ? .black.opacity(0.46) : .white.opacity(0.32))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onTogglePin) {
                Image(systemName: conversation.isPinned ? "pin.slash" : "pin")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(selected ? .black.opacity(0.54) : .white.opacity(0.34))
            .help(conversation.isPinned ? "取消置顶" : "置顶")

            Button(action: onToggleArchive) {
                Image(systemName: conversation.isArchived ? "tray.and.arrow.up" : "archivebox")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(selected ? .black.opacity(0.54) : .white.opacity(0.34))
            .help(conversation.isArchived ? "恢复对话" : "归档")

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(selected ? .black.opacity(0.52) : .white.opacity(0.36))
            .help("删除对话")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(selected ? .white : .white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contextMenu {
            Button(conversation.isPinned ? "取消置顶" : "置顶", action: onTogglePin)
            Button(conversation.isArchived ? "恢复对话" : "归档", action: onToggleArchive)
            Divider()
            Button("删除", role: .destructive, action: onDelete)
        }
    }
}

private struct AgentRuntimeSkillRow: View {
    let skill: AgentRuntimeSkill

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.62))
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(skill.name)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.84))
                        .lineLimit(1)
                    Text(skill.sourceLabel)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(skill.path.hasPrefix("config:") ? .blue.opacity(0.9) : .green.opacity(0.9))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.white.opacity(0.08), in: Capsule())
                    Spacer()
                }

                Text(skill.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)

                if !skill.summary.isEmpty {
                    Text(skill.summary)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.38))
                        .lineLimit(2)
                }

                if !skill.path.isEmpty {
                    Text(skill.path)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.30))
                        .lineLimit(1)
                }
            }
        }
        .padding(10)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white.opacity(0.82))
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct MemorySettingCard: View {
    let title: String
    let subtitle: String
    let usage: String
    @Binding var isEnabled: Bool
    @Binding var limit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Toggle(isOn: $isEnabled) {
                Text(title)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
            }
            Text(subtitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.48))
            HStack {
                Text(usage)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.58))
                Spacer()
                TextField("上限", value: $limit, format: .number)
                    .textFieldStyle(.plain)
                    .agentField()
                    .frame(width: 94)
            }
        }
        .agentSettingCard()
    }
}

private struct MemoryAuditList: View {
    let title: String
    let entries: [AgentMemoryEntry]
    let emptyText: String
    let onSave: (AgentMemoryEntry, String) -> Void
    let onDelete: (AgentMemoryEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 11, weight: .bold))
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                Text("\(entries.count)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.38))
            }
            .foregroundStyle(.white.opacity(0.74))

            if entries.isEmpty {
                EmptyConfigHint(text: emptyText)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(entries) { entry in
                        MemoryEntryRow(entry: entry, onSave: onSave, onDelete: onDelete)
                    }
                }
            }
        }
        .agentSettingCard()
    }
}

private struct MemoryEntryRow: View {
    let entry: AgentMemoryEntry
    let onSave: (AgentMemoryEntry, String) -> Void
    let onDelete: (AgentMemoryEntry) -> Void
    @State private var draft: String

    init(
        entry: AgentMemoryEntry,
        onSave: @escaping (AgentMemoryEntry, String) -> Void,
        onDelete: @escaping (AgentMemoryEntry) -> Void
    ) {
        self.entry = entry
        self.onSave = onSave
        self.onDelete = onDelete
        _draft = State(initialValue: entry.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Text("#\(entry.index + 1)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.42))
                Spacer()
                Button {
                    onSave(entry, draft)
                } label: {
                    Image(systemName: "checkmark")
                }
                .buttonStyle(AgentIconButtonStyle())
                .disabled(!canSave)
                .help("保存条目")

                Button {
                    onDelete(entry)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(AgentIconButtonStyle())
                .help("删除条目")
            }
            TextEditor(text: $draft)
                .settingsTextEditor(height: 64)
        }
        .padding(9)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onChange(of: entry.text) { _, newText in
            draft = newText
        }
    }

    private var canSave: Bool {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != entry.text
    }
}

private struct EvolutionCandidateList: View {
    let candidates: [AgentEvolutionCandidate]
    let onApply: (AgentEvolutionCandidate) -> Void
    let onReject: (AgentEvolutionCandidate) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .bold))
                Text("Skill 演化候选")
                    .font(.system(size: 12, weight: .bold))
                Text("\(candidates.filter { $0.isProposed }.count)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.38))
            }
            .foregroundStyle(.white.opacity(0.74))

            if candidates.isEmpty {
                EmptyConfigHint(text: "还没有待审核候选。")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(candidates.reversed()) { candidate in
                        EvolutionCandidateRow(candidate: candidate, onApply: onApply, onReject: onReject)
                    }
                }
            }
        }
        .agentSettingCard()
    }
}

private struct EvolutionCandidateRow: View {
    let candidate: AgentEvolutionCandidate
    let onApply: (AgentEvolutionCandidate) -> Void
    let onReject: (AgentEvolutionCandidate) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                statusDot
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.title.isEmpty ? candidate.skill : candidate.title)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(1)
                    Text(candidate.skill)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.42))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(statusText)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(statusColor.opacity(0.13), in: Capsule())
                if candidate.isProposed {
                    Button("拒绝") {
                        onReject(candidate)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button("应用") {
                        onApply(candidate)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            if !candidate.reason.isEmpty {
                Text(candidate.reason)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(2)
            }

            if !candidate.evidence.isEmpty {
                Text(candidate.evidence.prefix(3).joined(separator: "  ·  "))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(2)
            }

            HStack(alignment: .top, spacing: 8) {
                CandidatePreview(title: "候选", text: candidate.content)
                CandidatePreview(title: "当前", text: candidate.currentContent.isEmpty ? candidate.currentSummary : candidate.currentContent)
            }
        }
        .padding(10)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 7, height: 7)
    }

    private var statusText: String {
        switch candidate.status {
        case "applied": "已应用"
        case "rejected": "已拒绝"
        default: "待审核"
        }
    }

    private var statusColor: Color {
        switch candidate.status {
        case "applied": Color.green.opacity(0.8)
        case "rejected": Color.red.opacity(0.78)
        default: Color(red: 1.0, green: 0.78, blue: 0.32)
        }
    }
}

private struct CandidatePreview: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.38))
            Text(text.isEmpty ? "无" : text)
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(5)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(8)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct EmptyConfigHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.38))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct MessageBubble: View {
    let message: AgentMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 44) }
            VStack(alignment: .leading, spacing: 7) {
                if !message.attachments.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(message.attachments) { attachment in
                            AttachmentChip(attachment: attachment)
                        }
                    }
                }
                if message.role == .assistant {
                    MarkdownMessageView(text: message.text.isEmpty ? "..." : message.text)
                } else {
                    Text(message.text.isEmpty ? "..." : message.text)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.94))
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(message.role == .user ? .white.opacity(0.16) : .white.opacity(0.075), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            if message.role == .assistant { Spacer(minLength: 44) }
        }
    }
}

private struct MarkdownMessageView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(parseBlocks(text)) { block in
                switch block.kind {
                case .heading:
                    Text(inlineMarkdown(block.text))
                        .font(.system(size: headingSize(block.level), weight: .bold))
                        .foregroundStyle(.white.opacity(0.92))
                        .textSelection(.enabled)
                        .padding(.top, block.level <= 2 ? 4 : 2)
                case .paragraph:
                    Text(inlineMarkdown(block.text))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                case .listItem:
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(block.marker)
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.48))
                            .frame(width: 18, alignment: .trailing)
                        Text(inlineMarkdown(block.text))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineSpacing(3)
                            .textSelection(.enabled)
                    }
                case .code:
                    Text(block.text)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.78))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                case .quote:
                    Text(inlineMarkdown(block.text))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.66))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(.white.opacity(0.26))
                                .frame(width: 3)
                        }
                case .divider:
                    Rectangle()
                        .fill(.white.opacity(0.14))
                        .frame(height: 1)
                        .padding(.vertical, 3)
                case .table:
                    ScrollView(.horizontal, showsIndicators: false) {
                        MarkdownTableView(rows: block.tableRows)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 18
        case 2: 16
        case 3: 14
        default: 13
        }
    }

    private func inlineMarkdown(_ value: String) -> AttributedString {
        let normalized = value.replacingOccurrences(of: "\n", with: "  \n")
        if let attributed = try? AttributedString(markdown: normalized, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return attributed
        }
        return AttributedString(value)
    }

    private func parseBlocks(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var paragraph: [String] = []
        var codeLines: [String] = []
        var inCode = false

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                blocks.append(.paragraph(text))
            }
            paragraph.removeAll()
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(codeLines.joined(separator: "\n")))
                    codeLines.removeAll()
                    inCode = false
                } else {
                    flushParagraph()
                    inCode = true
                }
                index += 1
                continue
            }

            if inCode {
                codeLines.append(line)
                index += 1
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if isDivider(trimmed) {
                flushParagraph()
                blocks.append(.divider())
                index += 1
                continue
            }

            if let table = tableRows(from: lines, start: index) {
                flushParagraph()
                blocks.append(.table(table.rows))
                index = table.nextIndex
                continue
            }

            if let heading = heading(from: trimmed) {
                flushParagraph()
                blocks.append(.heading(level: heading.level, text: heading.text))
                index += 1
                continue
            }

            if let list = listItem(from: trimmed) {
                flushParagraph()
                blocks.append(.listItem(marker: list.marker, text: list.text))
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                flushParagraph()
                blocks.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
                index += 1
                continue
            }

            paragraph.append(line)
            index += 1
        }

        if inCode {
            blocks.append(.code(codeLines.joined(separator: "\n")))
        }
        flushParagraph()
        return blocks.isEmpty ? [.paragraph(markdown)] : blocks
    }

    private func heading(from line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard hashes > 0, hashes <= 6, line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, String(line.dropFirst(hashes)).trimmingCharacters(in: .whitespaces))
    }

    private func listItem(from line: String) -> (marker: String, text: String)? {
        if line.hasPrefix("- ") || line.hasPrefix("* ") {
            return ("•", String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
        }
        guard let dot = line.firstIndex(of: ".") else { return nil }
        let number = String(line[..<dot])
        guard !number.isEmpty, number.allSatisfy(\.isNumber) else { return nil }
        let afterDot = line.index(after: dot)
        guard afterDot < line.endIndex, line[afterDot] == " " else { return nil }
        return ("\(number).", String(line[line.index(after: afterDot)...]).trimmingCharacters(in: .whitespaces))
    }

    private func isDivider(_ line: String) -> Bool {
        let chars = Set(line)
        return line.count >= 3 && (chars == ["-"] || chars == ["*"] || chars == ["_"])
    }

    private func tableRows(from lines: [String], start: Int) -> (rows: [[String]], nextIndex: Int)? {
        guard start + 1 < lines.count else { return nil }
        let first = lines[start].trimmingCharacters(in: .whitespaces)
        let second = lines[start + 1].trimmingCharacters(in: .whitespaces)
        guard first.contains("|"), isTableSeparator(second) else { return nil }

        var rows: [[String]] = [splitTableRow(first)]
        var index = start + 2
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            guard line.contains("|"), !line.isEmpty else { break }
            rows.append(splitTableRow(line))
            index += 1
        }
        return rows.count > 1 ? (rows, index) : nil
    }

    private func isTableSeparator(_ line: String) -> Bool {
        guard line.contains("|") else { return false }
        let cleaned = line.replacingOccurrences(of: "|", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty
    }

    private func splitTableRow(_ line: String) -> [String] {
        line.split(separator: "|", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .drop { $0.isEmpty }
            .reversed()
            .drop { $0.isEmpty }
            .reversed()
    }
}

private struct MarkdownBlock: Identifiable {
    enum Kind {
        case heading
        case paragraph
        case listItem
        case code
        case quote
        case divider
        case table
    }

    let id = UUID()
    let kind: Kind
    let text: String
    let level: Int
    let marker: String
    let tableRows: [[String]]

    static func heading(level: Int, text: String) -> MarkdownBlock {
        MarkdownBlock(kind: .heading, text: text, level: level, marker: "", tableRows: [])
    }

    static func paragraph(_ text: String) -> MarkdownBlock {
        MarkdownBlock(kind: .paragraph, text: text, level: 0, marker: "", tableRows: [])
    }

    static func listItem(marker: String, text: String) -> MarkdownBlock {
        MarkdownBlock(kind: .listItem, text: text, level: 0, marker: marker, tableRows: [])
    }

    static func code(_ text: String) -> MarkdownBlock {
        MarkdownBlock(kind: .code, text: text, level: 0, marker: "", tableRows: [])
    }

    static func quote(_ text: String) -> MarkdownBlock {
        MarkdownBlock(kind: .quote, text: text, level: 0, marker: "", tableRows: [])
    }

    static func divider() -> MarkdownBlock {
        MarkdownBlock(kind: .divider, text: "", level: 0, marker: "", tableRows: [])
    }

    static func table(_ rows: [[String]]) -> MarkdownBlock {
        MarkdownBlock(kind: .table, text: "", level: 0, marker: "", tableRows: rows)
    }
}

private struct MarkdownTableView: View {
    let rows: [[String]]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows.indices, id: \.self) { rowIndex in
                HStack(alignment: .top, spacing: 0) {
                    ForEach(columnIndices, id: \.self) { column in
                        Text(cell(row: rowIndex, column: column))
                            .font(.system(size: 10.5, weight: rowIndex == 0 ? .bold : .medium))
                            .foregroundStyle(.white.opacity(rowIndex == 0 ? 0.78 : 0.58))
                            .lineLimit(4)
                            .frame(minWidth: 84, maxWidth: 150, alignment: .leading)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 6)
                            .background(rowIndex == 0 ? .white.opacity(0.07) : .clear)
                    }
                }
                if rowIndex < rows.count - 1 {
                    Rectangle()
                        .fill(.white.opacity(0.08))
                        .frame(height: 1)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        }
    }

    private var columnIndices: [Int] {
        Array(0..<(rows.map(\.count).max() ?? 0))
    }

    private func cell(row: Int, column: Int) -> String {
        guard rows.indices.contains(row), rows[row].indices.contains(column) else { return "" }
        return rows[row][column]
    }
}

private struct AttachmentChip: View {
    let attachment: AgentAttachment
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.72))
            Text(attachment.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(1)
            Text(sizeText)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.42))
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.58))
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.white.opacity(0.075), in: Capsule())
    }

    private var iconName: String {
        if attachment.typeIdentifier.contains("folder") { return "folder" }
        if attachment.typeIdentifier.contains("image") { return "photo" }
        if attachment.typeIdentifier.contains("pdf") { return "doc.richtext" }
        if attachment.typeIdentifier.contains("text") || attachment.typeIdentifier.contains("source") { return "doc.text" }
        return "doc"
    }

    private var sizeText: String {
        guard attachment.sizeBytes > 0 else { return "" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: attachment.sizeBytes)
    }
}

private struct ToolEventRow: View {
    let event: AgentToolEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: event.isPending ? "hourglass" : (event.isApproved == false ? "xmark.circle" : "checkmark.circle"))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(event.isPending ? .white.opacity(0.46) : (event.isApproved == false ? Color.red.opacity(0.8) : Color.green.opacity(0.8)))
                Text(event.tool)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
            }
            if !event.summary.isEmpty {
                Text(event.summary)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.54))
                    .lineLimit(2)
            }
            if !event.resultPreview.isEmpty {
                Text(event.resultPreview)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(3)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct PermissionCard: View {
    let request: AgentPermissionRequest
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("需要确认", systemImage: "exclamationmark.shield")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color(red: 1.0, green: 0.78, blue: 0.32))
            Text(request.tool)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text(request.summary.isEmpty ? request.argumentsPreview : request.summary)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(4)
            HStack(spacing: 8) {
                Button("拒绝", action: onDeny)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("允许", action: onApprove)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(Color(red: 0.18, green: 0.14, blue: 0.06).opacity(0.95), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct AgentIconButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(selected ? .black : .white.opacity(configuration.isPressed ? 0.65 : 0.78))
            .frame(width: 27, height: 27)
            .background(selected ? .white : .white.opacity(configuration.isPressed ? 0.16 : 0.08), in: Circle())
    }
}

private struct AgentCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.64 : 0.82))
            .padding(.horizontal, 10)
            .frame(height: 27)
            .background(.white.opacity(configuration.isPressed ? 0.16 : 0.08), in: Capsule())
    }
}

private extension View {
    func agentField() -> some View {
        self
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    func settingsCaption() -> some View {
        self
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white.opacity(0.48))
    }

    func settingsTextEditor(height: CGFloat) -> some View {
        self
            .font(.system(size: 11, weight: .regular, design: .monospaced))
            .foregroundStyle(.white.opacity(0.82))
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(height: height)
            .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    func agentSettingCard() -> some View {
        self
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
