import CodeWatchCore
import SwiftUI

/// 岛内的编码会话监控面板：列出本机所有 Claude Code / Codex 会话及其实时状态。
struct CodeWatchPanel: View {
    @Bindable var service: CodeWatchService

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if service.orderedSessions.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(service.orderedSessions, id: \.id) { item in
                            CodeWatchSessionRow(
                                sessionId: item.id,
                                snapshot: item.snapshot,
                                client: item.client,
                                pet: service.selectedPet
                            )
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
            if !service.lastError.isEmpty {
                Text(service.lastError)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.red.opacity(0.85))
                    .lineLimit(2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.72))
            Text("编码会话")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white.opacity(0.85))
            Text("\(service.summary.activeSessionCount) 活跃 / \(service.summary.totalSessionCount) 总计")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.42))
            Spacer(minLength: 8)
            petPicker
            notificationToggle
            soundToggle
            if service.hooksInstalled {
                Button {
                    service.uninstallHooks()
                } label: {
                    Label("已装 hooks", systemImage: "checkmark.seal")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Claude Code hooks 已安装，点击移除。移除后仍可通过进程发现监控会话，但没有实时工具状态。")
            } else {
                Button {
                    service.installHooks()
                } label: {
                    Label("安装 Claude hooks", systemImage: "bolt.badge.checkmark")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("往 ~/.claude/settings.json 写入监控 hooks（纯旁观，不拦截审批）。不装也能看到会话，只是没有实时工具状态。")
            }
        }
    }

    @State private var soundEnabled = CodeWatchSoundPlayer.shared.isEnabled

    private var petPicker: some View {
        Menu {
            Button {
                service.selectedMascotID = CodeWatchService.automaticMascotID
            } label: {
                if service.selectedMascotID == CodeWatchService.automaticMascotID {
                    Label("按来源 · Dex / Clawd", systemImage: "checkmark")
                } else {
                    Text("按来源 · Dex / Clawd")
                }
            }

            if !service.availablePets.isEmpty {
                Divider()
                ForEach(service.availablePets) { pet in
                    Button {
                        service.selectedMascotID = pet.id
                    } label: {
                        if service.selectedMascotID == pet.id {
                            Label(pet.displayName, systemImage: "checkmark")
                        } else {
                            Text(pet.displayName)
                        }
                    }
                }
            }

            Divider()
            Button {
                service.reloadPets()
            } label: {
                Label("重新扫描 Codex Pets", systemImage: "arrow.clockwise")
            }
        } label: {
            Label(service.selectedMascotName, systemImage: "pawprint.fill")
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("选择 ~/.codex/pets 中的 Codex Pet。按来源会为 Codex 显示 Dex，为 Claude Code 显示 Clawd。")
    }

    private var notificationToggle: some View {
        Button {
            service.handleNotificationButton()
        } label: {
            Image(systemName: notificationIcon)
                .foregroundStyle(
                    service.completionNotificationsEnabled && service.notificationAuthorization == .denied
                        ? Color.orange
                        : Color.white
                )
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(notificationHelp)
    }

    private var notificationIcon: String {
        guard service.completionNotificationsEnabled else { return "bell.slash" }
        return service.notificationAuthorization == .denied ? "bell.badge.fill" : "bell.fill"
    }

    private var notificationHelp: String {
        guard service.completionNotificationsEnabled else { return "任务完成通知已关闭" }
        if service.notificationAuthorization == .denied {
            return "系统通知未授权，点击打开通知设置"
        }
        return "任务完成通知已开启"
    }

    private var soundToggle: some View {
        Button {
            soundEnabled.toggle()
            CodeWatchSoundPlayer.shared.isEnabled = soundEnabled
            if soundEnabled {
                CodeWatchSoundPlayer.shared.play("8bit_boot")
            }
        } label: {
            Image(systemName: soundEnabled ? "speaker.wave.2" : "speaker.slash")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(soundEnabled ? "事件音效已开启（会话开始/完成/等待审批时播放 8-bit 音效）" : "事件音效已关闭")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white.opacity(0.3))
            Text("当前没有运行中的 Claude Code / ChatGPT / Codex 会话")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            Text("在 ChatGPT.app 开始任务，或在终端启动 claude / codex")
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.white.opacity(0.35))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CodeWatchSessionRow: View {
    let sessionId: String
    let snapshot: SessionSnapshot
    let client: CodeWatchClient
    let pet: CodexPet?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                CodeWatchMascotView(source: snapshot.source, status: snapshot.status, size: 30, pet: pet)
                statusDot
                Text(client.displayName)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.78))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(sourceColor.opacity(0.24), in: Capsule())
                Text(projectName)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                if let branch = snapshot.gitBranch, !branch.isEmpty {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(snapshot.status.displayLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(statusColor)
            }

            if let tool = snapshot.currentTool {
                HStack(spacing: 5) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.44))
                    Text(snapshot.toolDescription.map { "\(tool) · \($0)" } ?? tool)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
            }

            if let prompt = snapshot.lastUserPrompt, !prompt.isEmpty {
                Text(prompt)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                if let model = snapshot.model, !model.isEmpty {
                    Text(model)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.36))
                        .lineLimit(1)
                }
                if snapshot.totalToolCallCount > 0 {
                    Text("\(snapshot.totalToolCallCount) 次工具")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.36))
                }
                Spacer(minLength: 0)
                Text(relativeActivity)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.32))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var sourceColor: Color {
        switch client {
        case .chatGPT:
            return Color(red: 0.20, green: 0.78, blue: 0.62)
        case .codex:
            return Color(red: 0.4, green: 0.65, blue: 1.0)
        case .claudeCode:
            return Color(red: 0.85, green: 0.5, blue: 0.3)
        }
    }

    private var projectName: String {
        guard let cwd = snapshot.cwd, !cwd.isEmpty else { return "未知目录" }
        return (cwd as NSString).lastPathComponent
    }

    private var statusColor: Color {
        switch snapshot.status {
        case .idle: return .white.opacity(0.4)
        case .processing: return Color(red: 0.44, green: 0.78, blue: 1.0)
        case .running: return Color(red: 0.5, green: 0.85, blue: 0.55)
        case .waitingApproval, .waitingQuestion: return Color(red: 1.0, green: 0.78, blue: 0.32)
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 7, height: 7)
            .opacity(snapshot.status.isActive ? 1 : 0.5)
    }

    private var relativeActivity: String {
        let seconds = Int(Date().timeIntervalSince(snapshot.lastActivity))
        if seconds < 5 { return "刚刚" }
        if seconds < 60 { return "\(seconds) 秒前" }
        if seconds < 3600 { return "\(seconds / 60) 分钟前" }
        return "\(seconds / 3600) 小时前"
    }
}
