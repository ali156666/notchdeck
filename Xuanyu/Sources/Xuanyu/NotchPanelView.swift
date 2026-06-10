import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NotchPanelView: View {
    @Bindable var state: IslandAppState
    let screen: NSScreen
    @State private var isFileDropTargeted = false
    @State private var showsQuitConfirmation = false
    @State private var miniExpandTask: Task<Void, Never>?

    private var hasNotch: Bool {
        ScreenDetector.screenHasNotch(screen)
    }

    private var notchHeight: CGFloat {
        ScreenDetector.topBarHeight(for: screen)
    }

    private var collapsedWidth: CGFloat {
        ScreenDetector.collapsedIslandWidth(for: screen)
    }

    private var collapsedHeight: CGFloat {
        state.collapsedIslandHeight(for: screen)
    }

    private var collapsedDropdownHeight: CGFloat {
        if state.usesIdleCollapsedHeight {
            return ScreenDetector.idleCollapsedDropdownHeight(for: screen)
        }
        return ScreenDetector.collapsedDropdownHeight(for: screen, usesTallDropdown: state.usesTallCollapsedDropdown)
    }

    private var expandedWidth: CGFloat {
        switch state.mode {
        case .dashboard:
            return min(960, screen.frame.width - 40)
        case .music:
            return min(840, screen.frame.width - 40)
        case .quickApps:
            return min(960, screen.frame.width - 40)
        case .clipboard:
            return min(760, screen.frame.width - 40)
        case .agent:
            return min(900, screen.frame.width - 40)
        }
    }

    private var miniExpandedWidth: CGFloat {
        min(500, screen.frame.width - 40)
    }

    private var miniExpandedHeight: CGFloat {
        notchHeight + 64
    }

    private var currentWidth: CGFloat {
        if state.isExpanded { return expandedWidth }
        if state.isMiniExpanded { return miniExpandedWidth }
        return collapsedWidth
    }

    private var currentHeight: CGFloat? {
        if state.isExpanded { return nil }
        return state.isMiniExpanded ? miniExpandedHeight : collapsedHeight
    }

    var body: some View {
        VStack(spacing: 0) {
            island
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.locale, Locale(identifier: "zh-Hans"))
        .animation(.snappy(duration: 0.32), value: state.isExpanded)
        .animation(.snappy(duration: 0.24), value: state.isMiniExpanded)
        .animation(.snappy(duration: 0.22), value: state.mode)
        .alert("退出悬屿？", isPresented: $showsQuitConfirmation) {
            Button("取消", role: .cancel) {}
            Button("退出", role: .destructive) {
                NSApplication.shared.terminate(nil)
            }
        } message: {
            Text("悬屿会停止顶栏面板、音乐状态刷新、剪贴板和 Agent runtime。")
        }
        .onChange(of: state.agent.attentionToken) { _, _ in
            guard !state.agent.attentionText.isEmpty else { return }
            if !state.isExpanded {
                state.agentCollapsedReminder = state.agent.attentionText
                NSSound(named: "Ping")?.play()
            }
        }
        .onChange(of: state.pomodoro.noticeToken) { _, _ in
            guard !state.pomodoro.noticeText.isEmpty else { return }
            state.pomodoroCollapsedReminder = state.pomodoro.noticeText
            NSSound(named: "Glass")?.play()
        }
        .onChange(of: state.isExpanded) { _, expanded in
            if expanded {
                miniExpandTask?.cancel()
                state.isMiniExpanded = false
                state.agentCollapsedReminder = nil
                state.pomodoroCollapsedReminder = nil
                state.agent.clearAttention()
            }
        }
    }

    private var island: some View {
        VStack(spacing: 0) {
            if state.isExpanded {
                expandedPanel
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else if state.isMiniExpanded {
                miniExpandedPanel
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                collapsedBar
                    .transition(.opacity)
            }
        }
        .frame(width: currentWidth)
        .frame(height: currentHeight)
        .frame(minHeight: notchHeight)
        .background(.black)
        .clipShape(
            UnevenRoundedRectangle(
                bottomLeadingRadius: state.isExpanded || state.isMiniExpanded ? 24 : 13,
                bottomTrailingRadius: state.isExpanded || state.isMiniExpanded ? 24 : 13
            )
        )
        .contentShape(Rectangle())
        .overlay(islandDropOverlay)
        .onDrop(of: AgentFileDrop.typeIdentifiers, isTargeted: $isFileDropTargeted, perform: handleIslandFileDrop)
        .onHover { hovering in
            handleIslandHover(hovering)
        }
    }

    private var islandDropOverlay: some View {
        Group {
            if isFileDropTargeted && !(state.isExpanded && state.mode == .agent) {
                RoundedRectangle(cornerRadius: state.isExpanded ? 24 : 13, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.74), lineWidth: 2)
                    .background(Color.white.opacity(0.08))
                    .overlay {
                        Label("拖入待发送", systemImage: "doc.badge.plus")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.black.opacity(0.72), in: Capsule())
                    }
                    .allowsHitTesting(false)
            }
        }
    }

    private func handleIslandFileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !(state.isExpanded && state.mode == .agent) else { return false }
        return AgentFileDrop.loadFileURLs(from: providers) { urls in
            state.mode = .agent
            state.agentShowsSettings = false
            state.agentCollapsedReminder = nil
            state.isExpanded = true
            state.agent.addAttachmentURLs(urls)
        }
    }

    private var expandedPanel: some View {
        VStack(spacing: 0) {
            expandedHeader
            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(height: 1)
            switch state.mode {
            case .dashboard:
                SystemDashboardPanel(service: state.dashboard)
                    .frame(height: 376)
            case .music:
                MediaIslandPanel(service: state.media, showsHeader: true)
                    .frame(height: 224)
            case .quickApps:
                QuickAppsPanel(service: state.quickLaunch)
                    .frame(height: 132)
            case .clipboard:
                ClipboardPanel(service: state.clipboard)
                    .frame(height: 224)
            case .agent:
                AgentIslandPanel(
                    service: state.agent,
                    showsConfiguration: $state.agentShowsSettings,
                    settingsTab: $state.agentSettingsTab
                )
                    .frame(height: min(500, screen.frame.height - 92))
            }
        }
    }

    private var miniExpandedPanel: some View {
        VStack(spacing: 0) {
            miniStatusBar
                .frame(height: notchHeight)

            if state.media.playback.hasPlayableTrack {
                miniMusicControls
            } else {
                miniQuickApps
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture {
                    state.mode = state.media.playback.hasPlayableTrack ? .music : .quickApps
                    expandFully()
                }
        }
    }

    private var miniStatusBar: some View {
        HStack(alignment: .center, spacing: 8) {
            MiniStatusPill(icon: "memorychip", text: "\(Int(state.dashboard.memory.percent * 100))%")
            if let airPodsText = miniAirPodsText {
                MiniStatusPill(icon: "airpodspro", text: airPodsText)
            }

            Spacer(minLength: 96)

            MiniStatusPill(icon: "cloud.sun", text: miniWeatherText)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .allowsHitTesting(false)
    }

    private var miniWeatherText: String {
        let weather = state.dashboard.weather
        if weather.temperature != "--" {
            return "\(weather.temperature) \(weather.description)"
        }
        return weather.description
    }

    private var miniAirPodsText: String? {
        let airPods = state.media.airPods
        guard airPods.isConnected else { return nil }
        let values = [airPods.leftBattery, airPods.rightBattery].compactMap { $0 }
        if !values.isEmpty {
            return "\(values.min() ?? values[0])%"
        }
        if let caseBattery = airPods.caseBattery {
            return "\(caseBattery)%"
        }
        return "已连"
    }

    private var miniMusicControls: some View {
        HStack(spacing: 11) {
            miniArtwork
            VStack(alignment: .leading, spacing: 3) {
                Text(state.media.playback.title)
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.94))
                    .lineLimit(1)
                Text(state.media.playback.artist)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.56))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                state.mode = .music
                expandFully()
            }

            MiniCircleButton(icon: "backward.fill", help: "上一首") {
                Task { await state.media.previousTrack() }
            }
            MiniCircleButton(icon: state.media.playback.isPlaying ? "pause.fill" : "play.fill", size: 34, help: state.media.playback.isPlaying ? "暂停" : "播放") {
                Task { await state.media.togglePlay() }
            }
            MiniCircleButton(icon: "forward.fill", help: "下一首") {
                Task { await state.media.nextTrack() }
            }
            MiniCircleButton(icon: "chevron.down", help: "完全展开") {
                state.mode = .music
                expandFully()
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 64)
    }

    private var miniQuickApps: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white.opacity(0.82))
                .contentShape(Rectangle())
                .onTapGesture {
                    state.mode = .quickApps
                    expandFully()
                }

            ForEach(Array(state.quickLaunch.apps.prefix(5))) { app in
                Button {
                    state.quickLaunch.launch(app)
                } label: {
                    Image(nsImage: state.quickLaunch.icon(for: app))
                        .resizable()
                        .scaledToFit()
                        .frame(width: 25, height: 25)
                        .frame(width: 38, height: 38)
                        .background(.white.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!app.isInstalled)
                .opacity(app.isInstalled ? 1 : 0.45)
                .help(app.name)
            }

            Spacer(minLength: 0)

            MiniCircleButton(icon: "chevron.down", help: "完全展开") {
                state.mode = .quickApps
                expandFully()
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 64)
    }

    private var miniArtwork: some View {
        ZStack {
            if let data = state.media.playback.artwork, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: state.media.playback.isPlaying ? "waveform" : "music.note")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white.opacity(0.08))
            }
        }
        .frame(width: 42, height: 42)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            state.mode = .music
            expandFully()
        }
    }

    private var expandedHeader: some View {
        HStack(spacing: 10) {
            LingdongHomeButton(selected: state.mode == .dashboard) {
                withAnimation(.snappy(duration: 0.22)) {
                    state.mode = .dashboard
                    state.agentShowsSettings = false
                }
            }

            HeaderPageButton(title: "快捷", icon: "square.grid.2x2", selected: state.mode == .quickApps) {
                withAnimation(.snappy(duration: 0.22)) {
                    state.mode = state.mode == .quickApps ? .music : .quickApps
                    state.agentShowsSettings = false
                }
            }

            HeaderPageButton(title: "剪贴板", icon: "doc.on.clipboard", selected: state.mode == .clipboard) {
                withAnimation(.snappy(duration: 0.22)) {
                    state.mode = .clipboard
                    state.agentShowsSettings = false
                }
            }

            Spacer(minLength: 10)

            PomodoroInlineView(service: state.pomodoro)

            HStack(spacing: 4) {
                ModeSegmentButton(title: "Music", icon: "music.note", selected: state.mode == .music) {
                    withAnimation(.snappy(duration: 0.22)) {
                        state.mode = .music
                        state.agentShowsSettings = false
                        state.agentSettingsTab = .model
                    }
                }
                ModeSegmentButton(title: "悬屿", icon: "sparkles", selected: state.mode == .agent) {
                    withAnimation(.snappy(duration: 0.22)) { state.mode = .agent }
                }
            }
            .padding(3)
            .background(.white.opacity(0.08), in: Capsule())

            HeaderIconButton(icon: "power", help: "退出悬屿") {
                showsQuitConfirmation = true
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 48)
    }

    private var nowPlayingChip: some View {
        HStack(spacing: 7) {
            Image(systemName: state.media.playback.isPlaying ? "waveform" : "play.circle")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.64))
            Text(state.media.playback.hasPlayableTrack ? state.media.playback.title : "未播放")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.white.opacity(0.06), in: Capsule())
        .frame(width: 170, alignment: .leading)
    }

    private var collapsedBar: some View {
        Group {
            if hasNotch {
                collapsedNotchDropdownBar
            } else if state.shouldShowCollapsedLyrics {
                collapsedLyricsBar
            } else {
                collapsedStatusBar
            }
        }
        .frame(height: hasNotch ? collapsedHeight : notchHeight)
        .onTapGesture {
            expandFully()
        }
    }

    private var collapsedNotchDropdownBar: some View {
        TimelineView(.animation(minimumInterval: 0.25)) { timeline in
            VStack(spacing: 0) {
                Color.clear
                    .frame(height: notchHeight)
                    .allowsHitTesting(false)

                collapsedDropdownContent(at: timeline.date)
                    .frame(height: collapsedDropdownHeight)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func collapsedDropdownContent(at date: Date) -> some View {
        HStack(spacing: 9) {
            if shouldCenterCollapsedDropdown {
                Spacer(minLength: 0)
            }

            Image(systemName: collapsedDropdownIcon)
                .font(.system(size: 12, weight: .bold))
                .symbolEffect(.variableColor.iterative, options: .repeating, value: state.media.playback.title)
                .foregroundStyle(.white.opacity(0.9))

            Text(collapsedDropdownTitle(at: date))
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.82)

            if shouldCenterCollapsedDropdown {
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 4)
                collapsedAccessory
            }
        }
        .padding(.horizontal, 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: shouldCenterCollapsedDropdown ? .center : .leading)
    }

    private var collapsedLyricsBar: some View {
        TimelineView(.animation(minimumInterval: 0.25)) { timeline in
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: 12, weight: .bold))
                    .symbolEffect(.variableColor.iterative, options: .repeating, value: state.media.playback.title)
                    .foregroundStyle(.white.opacity(0.9))

                Text(collapsedLyricText(at: timeline.date))
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.82)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 15)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    private var collapsedStatusBar: some View {
        HStack(spacing: 9) {
            Image(systemName: collapsedIcon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.88))

            Text(collapsedTitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)

            Spacer(minLength: 4)

            collapsedAccessory
        }
        .padding(.horizontal, 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var collapsedAccessory: some View {
        Group {
            if state.agent.isBusy {
                Circle()
                    .fill(Color(red: 0.42, green: 0.78, blue: 1.0))
                    .frame(width: 7, height: 7)
            } else if state.agentCollapsedReminder != nil {
                Circle()
                    .fill(Color(red: 1.0, green: 0.78, blue: 0.32))
                    .frame(width: 7, height: 7)
            } else if state.pomodoro.status == .completed || state.pomodoroCollapsedReminder != nil {
                Circle()
                    .fill(Color(red: 1.0, green: 0.32, blue: 0.28))
                    .frame(width: 7, height: 7)
            } else if state.media.airPods.isConnected {
                Image(systemName: "airpodspro")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
    }

    private var shouldCenterCollapsedDropdown: Bool {
        state.pomodoro.status == .running
    }

    private var collapsedIcon: String {
        if state.agentCollapsedReminder != nil { return "checkmark.message" }
        if state.agent.isBusy { return "sparkles" }
        if state.pomodoro.status == .completed || state.pomodoroCollapsedReminder != nil { return "timer" }
        if state.pomodoro.status == .running { return "timer" }
        return state.media.playback.isPlaying ? "waveform" : "sparkles"
    }

    private var collapsedTitle: String {
        if let reminder = state.agentCollapsedReminder { return reminder }
        if state.agent.isBusy { return "悬屿运行中" }
        if let reminder = state.pomodoroCollapsedReminder { return reminder }
        if state.pomodoro.status == .completed { return state.pomodoro.noticeText.isEmpty ? "番茄钟完成" : state.pomodoro.noticeText }
        if state.pomodoro.status == .running { return "\(state.pomodoro.collapsedRunningTitle) \(state.pomodoro.formattedRemaining)" }
        return state.media.playback.isPlaying ? state.media.playback.title : "悬屿"
    }

    private var collapsedDropdownIcon: String {
        if state.agentCollapsedReminder != nil { return "checkmark.message" }
        if state.agent.isBusy { return "sparkles" }
        if state.pomodoro.status == .completed || state.pomodoroCollapsedReminder != nil { return "timer" }
        if state.pomodoro.status == .running { return "timer" }
        if state.media.playback.isPlaying { return "waveform" }
        return "sparkles"
    }

    private func collapsedDropdownTitle(at date: Date) -> String {
        if let reminder = state.agentCollapsedReminder { return reminder }
        if state.agent.isBusy { return "悬屿运行中" }
        if let reminder = state.pomodoroCollapsedReminder { return reminder }
        if state.pomodoro.status == .completed { return state.pomodoro.noticeText.isEmpty ? "番茄钟完成" : state.pomodoro.noticeText }
        if state.pomodoro.status == .running { return "\(state.pomodoro.collapsedRunningTitle) \(state.pomodoro.formattedRemaining)" }
        if state.media.playback.isPlaying { return collapsedLyricText(at: date) }
        return "悬屿"
    }

    private func collapsedLyricText(at date: Date) -> String {
        let lyric = state.media.currentLyricLine(at: date).trimmingCharacters(in: .whitespacesAndNewlines)
        if lyric.isEmpty || lyric == "暂无歌词" || lyric == "歌词加载中" {
            return state.media.playback.title
        }
        return lyric
    }

    private func expandFully() {
        guard !state.isExpanded else { return }
        miniExpandTask?.cancel()
        withAnimation(.snappy(duration: 0.32)) {
            state.isMiniExpanded = false
            state.isExpanded = true
            state.agentCollapsedReminder = nil
            state.pomodoroCollapsedReminder = nil
        }
    }

    private func handleIslandHover(_ hovering: Bool) {
        guard !state.isExpanded else { return }
        miniExpandTask?.cancel()

        if hovering {
            miniExpandTask = Task {
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard !state.isExpanded else { return }
                    withAnimation(.snappy(duration: 0.24)) {
                        state.isMiniExpanded = true
                    }
                    state.dashboard.refreshAll()
                    Task { await state.media.refreshPlayback() }
                    Task { await state.media.refreshAirPods() }
                }
            }
        } else {
            withAnimation(.snappy(duration: 0.20)) {
                state.isMiniExpanded = false
            }
        }
    }
}

private struct MiniCircleButton: View {
    let icon: String
    var size: CGFloat = 30
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size > 32 ? 14 : 12, weight: .bold))
                .foregroundStyle(.white.opacity(hovering ? 0.96 : 0.76))
                .frame(width: size, height: size)
                .background(.white.opacity(hovering ? 0.17 : 0.08), in: Circle())
                .scaleEffect(hovering ? 1.05 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct MiniStatusPill: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .bold))
            Text(text)
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(.white.opacity(0.72))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.white.opacity(0.07), in: Capsule())
    }
}

private struct LingdongHomeButton: View {
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .bold))
                Text("悬屿")
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? .black : .white.opacity(0.72))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .frame(width: 104)
            .background(selected ? .white : .white.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
        .frame(width: 104)
        .help("悬屿看板")
    }
}

private struct HeaderPageButton: View {
    let title: String
    let icon: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                Text(title)
                    .font(.system(size: 17, weight: .bold))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? .white : .white.opacity(0.56))
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(selected ? .white.opacity(0.10) : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

private struct PomodoroInlineView: View {
    @Bindable var service: PomodoroService
    @State private var showsEditor = false

    var body: some View {
        HStack(spacing: 5) {
            Button {
                showsEditor.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "timer")
                    Text(service.formattedRemaining)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(color)
            .help("设置番茄钟")
            .popover(isPresented: $showsEditor, arrowEdge: .top) {
                PomodoroEditorView(service: service)
            }

            Button {
                service.startPause()
            } label: {
                Image(systemName: service.status == .running ? "pause.fill" : "play.fill")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.78))
            .help(service.status == .running ? "暂停番茄钟" : "开始番茄钟")

            Button {
                service.reset()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.54))
            .help("重置番茄钟")
        }
        .font(.system(size: 12, weight: .bold, design: .rounded))
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.white.opacity(0.06), in: Capsule())
        .frame(width: 150)
    }

    private var color: Color {
        switch service.status {
        case .completed:
            Color(red: 1.0, green: 0.58, blue: 0.38)
        case .running:
            Color(red: 0.36, green: 1.0, blue: 0.52)
        case .paused:
            Color(red: 1.0, green: 0.78, blue: 0.32)
        case .idle:
            .white.opacity(0.66)
        }
    }
}

private struct ModeSegmentButton: View {
    let title: String
    let icon: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(selected ? .black : .white.opacity(0.64))
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(selected ? .white : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct HeaderIconButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.64))
                .frame(width: 28, height: 28)
                .background(.white.opacity(0.06), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
