import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NotchPanelView: View {
    @Bindable var state: IslandAppState
    let screen: NSScreen
    @State private var isFileDropTargeted = false
    @State private var showsQuitConfirmation = false

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
        case .code:
            return min(760, screen.frame.width - 40)
        }
    }

    private var presentedWidth: CGFloat {
        if state.voiceInput.prefersLargeHUD {
            if state.voiceInput.state == .reviewing {
                return min(620, screen.frame.width - 40)
            }
            return min(480, screen.frame.width - 40)
        }
        return state.isExpanded ? expandedWidth : collapsedWidth
    }

    private var presentedHeight: CGFloat? {
        if state.voiceInput.prefersLargeHUD {
            if state.voiceInput.state == .reviewing {
                return notchHeight + 164
            }
            return notchHeight + 96
        }
        return state.isExpanded ? nil : collapsedHeight
    }

    var body: some View {
        VStack(spacing: 0) {
            island
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.locale, Locale(identifier: "zh-Hans"))
        .animation(.snappy(duration: 0.32), value: state.isExpanded)
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
        .onChange(of: state.codeWatch.completionNoticeToken) { _, _ in
            guard !state.isExpanded, let completion = state.codeWatch.lastCompletion else { return }
            state.codeWatchCollapsedReminder = completion.collapsedTitle
        }
        .onChange(of: state.isExpanded) { _, expanded in
            if expanded {
                state.agentCollapsedReminder = nil
                state.pomodoroCollapsedReminder = nil
                state.codeWatchCollapsedReminder = nil
                state.agent.clearAttention()
            }
        }
    }

    private var islandShape: UnevenRoundedRectangle {
        let expanded = state.isExpanded || state.voiceInput.prefersLargeHUD
        return UnevenRoundedRectangle(
            topLeadingRadius: expanded ? 24 : 0,
            bottomLeadingRadius: expanded ? XYGlass.panelRadius : XYGlass.collapsedRadius,
            bottomTrailingRadius: expanded ? XYGlass.panelRadius : XYGlass.collapsedRadius,
            topTrailingRadius: expanded ? 24 : 0,
            style: .continuous
        )
    }

    private var island: some View {
        ZStack(alignment: .top) {
            islandBackground

            VStack(spacing: 0) {
                if state.voiceInput.prefersLargeHUD {
                    voiceInputHUD
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                } else if state.isExpanded {
                    expandedPanel
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    collapsedBar
                        .transition(.opacity)
                }
            }
        }
        .frame(width: presentedWidth)
        .frame(height: presentedHeight)
        .frame(minHeight: notchHeight)
        .clipShape(islandShape)
        .shadow(color: .black.opacity(state.isExpanded || state.voiceInput.prefersLargeHUD ? 0.30 : 0), radius: 18, y: 6)
        .contentShape(Rectangle())
        .overlay(islandDropOverlay)
        .onDrop(of: AgentFileDrop.typeIdentifiers, isTargeted: $isFileDropTargeted, perform: handleIslandFileDrop)
        .onTapGesture {
            guard !state.isExpanded, !state.voiceInput.prefersLargeHUD else { return }
            withAnimation(.snappy(duration: 0.32)) {
                if shouldShowCodeWatchCollapsed {
                    state.mode = .code
                }
                state.isExpanded = true
                state.agentCollapsedReminder = nil
                state.pomodoroCollapsedReminder = nil
                state.codeWatchCollapsedReminder = nil
            }
        }
    }

    @ViewBuilder
    private var islandBackground: some View {
        if state.voiceInput.prefersLargeHUD {
            VoiceIslandGlassBackground(shape: islandShape, accent: voiceInputColor)
        } else if usesTransparentPanelGlass {
            TransparentIslandGlassBackground(shape: islandShape)
        } else {
            islandShape.fill(.black)
        }
    }

    private var usesTransparentPanelGlass: Bool {
        state.isExpanded && state.mode != .agent
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
                .fill(.white.opacity(0.14))
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
                    .frame(height: 186)
            case .agent:
                AgentIslandPanel(
                    service: state.agent,
                    voiceInput: state.voiceInput,
                    showsConfiguration: $state.agentShowsSettings,
                    settingsTab: $state.agentSettingsTab
                )
                    .frame(height: min(500, screen.frame.height - 92))
            case .code:
                CodeWatchPanel(service: state.codeWatch)
                    .frame(height: 320)
            }
        }
    }

    private var expandedHeader: some View {
        HStack(spacing: 8) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
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

                    HeaderPageButton(title: "编码", icon: "terminal", selected: state.mode == .code) {
                        withAnimation(.snappy(duration: 0.22)) {
                            state.mode = .code
                            state.agentShowsSettings = false
                        }
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(2)

            Spacer(minLength: 6)

            if state.voiceInput.shouldDisplay {
                voiceInputChip
            }

            PomodoroInlineView(service: state.pomodoro)

            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
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
                    .glassCapsule(interactive: false)

                    HeaderIconButton(icon: "power", help: "退出悬屿") {
                        showsQuitConfirmation = true
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }

    private var voiceInputChip: some View {
        HStack(spacing: 7) {
            Image(systemName: voiceInputChipIcon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(voiceInputColor)
                .symbolEffect(.pulse, options: .repeating, value: state.voiceInput.state == .recording)
            Text(state.voiceInput.displayText)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: 240)
        .background(.white.opacity(0.08), in: Capsule())
    }

    private var voiceInputColor: Color {
        switch state.voiceInput.state {
        case .arming:
            return .white
        case .preparing, .permission:
            return Color(red: 1, green: 0.68, blue: 0.25)
        case .recording:
            return Color(red: 1, green: 0.25, blue: 0.28)
        case .transcribing:
            return Color(red: 0.42, green: 0.78, blue: 1)
        case .reviewing:
            return Color(red: 0.46, green: 0.78, blue: 1)
        case .submitted:
            return Color(red: 0.36, green: 1, blue: 0.52)
        case .error:
            return Color(red: 1, green: 0.58, blue: 0.2)
        case .idle:
            return .white.opacity(0.7)
        }
    }

    private var voiceInputChipIcon: String {
        switch state.voiceInput.state {
        case .recording:
            return "mic.fill"
        case .reviewing:
            return "text.bubble.fill"
        case .submitted:
            return "checkmark.circle.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        case .arming:
            return "command"
        default:
            return "waveform"
        }
    }

    private var voiceInputHUD: some View {
        VStack(spacing: 0) {
            if hasNotch {
                Color.clear
                    .frame(height: notchHeight)
                    .allowsHitTesting(false)
            }

            voiceHUDCard
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var voiceHUDCard: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)

        return ZStack {
            shape
                .fill(.clear)
                .glassEffect(.regular.interactive(), in: shape)
                .opacity(0.14)
                .allowsHitTesting(false)

            shape
                .fill(
                    LinearGradient(
                        colors: [
                            voiceInputColor.opacity(0.14),
                            .white.opacity(0.045),
                            .clear,
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .blendMode(.screen)
                .allowsHitTesting(false)

            shape
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.030), .clear, .black.opacity(0.018)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .allowsHitTesting(false)

            HStack(spacing: 16) {
                voiceHUDLeadingIcon

                VStack(alignment: .leading, spacing: 8) {
                    Text(voiceHUDTitle)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.26), radius: 3, y: 1)

                    if state.voiceInput.state == .recording {
                        voiceWaveform
                    } else if state.voiceInput.state == .reviewing {
                        voiceReviewEditor
                    } else {
                        Text(state.voiceInput.displayText)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.78))
                            .lineLimit(2)
                            .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if state.voiceInput.state == .permission {
                    voicePermissionButton
                } else if state.voiceInput.state == .reviewing {
                    voiceReviewActions
                }
            }
            .padding(.horizontal, 18)
        }
        .frame(height: state.voiceInput.state == .reviewing ? 132 : 72)
        .clipShape(shape)
        .overlay {
            shape
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.46), .white.opacity(0.14), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.16), radius: 10, y: 7)
    }

    @ViewBuilder
    private var voiceHUDLeadingIcon: some View {
        ZStack {
            Circle()
                .fill(.clear)
                .glassEffect(.regular.interactive(), in: .circle)
                .opacity(0.12)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            voiceInputColor.opacity(0.26),
                            .white.opacity(0.08),
                            .clear,
                        ],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: 58
                    )
                )
                .blendMode(.screen)

            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.42), .white.opacity(0.12), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )

            switch state.voiceInput.state {
            case .preparing, .transcribing:
                ProgressView()
                    .controlSize(.small)
                    .tint(voiceInputColor)
            case .recording:
                Image(systemName: "mic.fill")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(voiceInputColor)
                    .symbolEffect(.pulse, options: .repeating)
            case .reviewing:
                Image(systemName: "text.bubble.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(voiceInputColor)
            case .permission:
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(voiceInputColor)
            case .submitted:
                Image(systemName: "checkmark")
                    .font(.system(size: 21, weight: .heavy))
                    .foregroundStyle(voiceInputColor)
            case .error:
                Image(systemName: "exclamationmark")
                    .font(.system(size: 21, weight: .heavy))
                    .foregroundStyle(voiceInputColor)
            case .idle, .arming:
                Image(systemName: "mic")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(voiceInputColor)
            }
        }
        .frame(width: 54, height: 54)
        .shadow(color: voiceInputColor.opacity(0.20), radius: 10, y: 3)
    }

    private var voiceHUDTitle: String {
        switch state.voiceInput.state {
        case .preparing: "准备语音输入"
        case .permission: "需要系统权限"
        case .recording:
            switch state.voiceInput.activeBackend {
            case .apple: "Apple 语音识别中"
            case .senseVoiceSmall: "SenseVoice 本地识别中"
            case .localZipformer: "本地识别中"
            }
        case .transcribing: "整理识别结果"
        case .reviewing: "确认后发送给 Agent"
        case .submitted: "任务已提交"
        case .error: "语音输入未完成"
        case .idle, .arming: "语音输入"
        }
    }

    private var voiceWaveform: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(state.voiceInput.waveformLevels.enumerated()), id: \.offset) { index, level in
                Capsule()
                    .fill(index >= state.voiceInput.waveformLevels.count - 5 ? voiceInputColor : .white.opacity(0.44))
                    .frame(width: 4, height: max(5, 30 * level))
                    .animation(.easeOut(duration: 0.08), value: level)
            }
        }
        .frame(height: 32)
        .overlay(alignment: .bottomLeading) {
            if !state.voiceInput.transcript.isEmpty {
                Text(state.voiceInput.transcript)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.56))
                    .lineLimit(1)
                    .offset(y: 18)
            }
        }
    }

    private var voiceReviewEditor: some View {
        TextEditor(text: Binding(
            get: { state.voiceInput.transcript },
            set: { state.voiceInput.transcript = $0 }
        ))
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.white.opacity(0.94))
        .scrollContentBackground(.hidden)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(height: 72)
        .transparentGlassCard(
            radius: 12,
            opacity: 0.08,
            strokeOpacity: 0.28,
            shadowOpacity: 0.04,
            interactive: true
        )
    }

    private var voicePermissionButton: some View {
        Button {
            openRelevantVoicePermission()
        } label: {
            Label("打开设置", systemImage: "gear")
                .font(.system(size: 12, weight: .bold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .transparentGlassCapsule(opacity: 0.09, strokeOpacity: 0.34, interactive: true)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.88))
    }

    private var voiceReviewActions: some View {
        VStack(spacing: 8) {
            voiceReviewActionButton(
                title: "发送",
                systemImage: "paperplane.fill",
                isPrimary: true,
                isDisabled: state.voiceInput.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ) {
                submitReviewedVoiceInput()
            }

            voiceReviewActionButton(
                title: "取消",
                systemImage: "xmark",
                isPrimary: false,
                isDisabled: false
            ) {
                state.voiceInput.cancelReview()
            }
        }
    }

    private func voiceReviewActionButton(
        title: String,
        systemImage: String,
        isPrimary: Bool,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 78)
                .padding(.vertical, 7)
                .transparentGlassCapsule(
                    opacity: isPrimary ? 0.12 : 0.08,
                    strokeOpacity: isPrimary ? 0.44 : 0.30,
                    interactive: true
                )
                .overlay {
                    if isPrimary {
                        Capsule()
                            .fill(voiceInputColor.opacity(0.12))
                            .blendMode(.screen)
                            .allowsHitTesting(false)
                    }
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(isDisabled ? .white.opacity(0.36) : .white.opacity(isPrimary ? 0.96 : 0.78))
        .disabled(isDisabled)
    }

    private func submitReviewedVoiceInput() {
        guard let text = state.voiceInput.confirmReviewedTranscript() else { return }
        state.mode = .agent
        state.agentShowsSettings = false
        state.agentCollapsedReminder = nil
        state.isExpanded = true
        state.agent.send(text)
    }

    private func openRelevantVoicePermission() {
        let message = state.voiceInput.statusMessage
        if message.contains("输入监控") {
            state.voiceInput.openInputMonitoringSettings()
        } else if message.contains("麦克风") {
            state.voiceInput.openMicrophoneSettings()
        } else {
            state.voiceInput.openSpeechRecognitionSettings()
        }
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
        .glassCapsule(interactive: false)
        .frame(width: 170, alignment: .leading)
    }

    private var collapsedBar: some View {
        Group {
            if hasNotch {
                collapsedNotchDropdownBar
            } else if state.voiceInput.shouldDisplay {
                collapsedStatusBar
            } else if shouldShowCodeWatchCollapsed {
                collapsedStatusBar
            } else if state.shouldShowCollapsedLyrics {
                collapsedLyricsBar
            } else {
                collapsedStatusBar
            }
        }
        .frame(height: hasNotch ? collapsedHeight : notchHeight)
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

            if state.voiceInput.state == .arming {
                voiceArmingIndicator
            } else if shouldShowCodeWatchCollapsed {
                codeWatchCollapsedMascot(size: 28)
            } else {
                Image(systemName: collapsedDropdownIcon)
                    .font(.system(size: 12, weight: .bold))
                    .symbolEffect(.variableColor.iterative, options: .repeating, value: state.media.playback.title)
                    .foregroundStyle(.white.opacity(0.9))
            }

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
            if state.voiceInput.state == .arming {
                voiceArmingIndicator
            } else if shouldShowCodeWatchCollapsed {
                codeWatchCollapsedMascot(size: 27)
            } else {
                Image(systemName: collapsedIcon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.88))
            }

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

    private var voiceArmingIndicator: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.18), lineWidth: 2)
            Circle()
                .trim(from: 0, to: state.voiceInput.armingProgress)
                .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "command")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
        }
        .frame(width: 17, height: 17)
    }

    private var collapsedAccessory: some View {
        Group {
            if state.voiceInput.shouldDisplay {
                Circle()
                    .fill(voiceInputColor)
                    .frame(width: 7, height: 7)
            } else if state.agent.isBusy {
                Circle()
                    .fill(XYGlass.statusBusy)
                    .frame(width: 7, height: 7)
            } else if state.codeWatch.hasActiveSessions {
                Circle()
                    .fill(XYGlass.statusBusy)
                    .frame(width: 7, height: 7)
            } else if state.codeWatchCollapsedReminder != nil {
                Circle()
                    .fill(XYGlass.statusAlert)
                    .frame(width: 7, height: 7)
            } else if state.agentCollapsedReminder != nil {
                Circle()
                    .fill(XYGlass.statusPaused)
                    .frame(width: 7, height: 7)
            } else if state.pomodoro.status == .completed || state.pomodoroCollapsedReminder != nil {
                Circle()
                    .fill(XYGlass.statusAlert)
                    .frame(width: 7, height: 7)
            } else if state.media.airPods.isConnected {
                Image(systemName: "airpodspro")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
    }

    private var shouldCenterCollapsedDropdown: Bool {
        state.voiceInput.shouldDisplay ||
        shouldShowCodeWatchCollapsed ||
        state.pomodoro.status == .running
    }

    private var shouldShowCodeWatchCollapsed: Bool {
        state.codeWatch.hasActiveSessions || state.codeWatchCollapsedReminder != nil
    }

    private func codeWatchCollapsedMascot(size: CGFloat) -> some View {
        let active = state.codeWatch.primaryActiveSession
        let source = active?.snapshot.source
            ?? state.codeWatch.lastCompletion?.client.source
            ?? state.codeWatch.summary.primarySource
        let status = active?.snapshot.status ?? .idle
        return CodeWatchMascotView(
            source: source,
            status: status,
            size: size,
            pet: state.codeWatch.selectedPet
        )
    }

    private var collapsedIcon: String {
        if state.voiceInput.state == .arming { return "command" }
        if state.voiceInput.state == .preparing || state.voiceInput.state == .permission { return "ellipsis.circle" }
        if state.voiceInput.state == .recording { return "mic.fill" }
        if state.voiceInput.state == .transcribing { return "waveform" }
        if state.voiceInput.state == .reviewing { return "text.bubble.fill" }
        if state.voiceInput.state == .submitted { return "checkmark.circle.fill" }
        if state.voiceInput.state == .error { return "exclamationmark.triangle.fill" }
        if shouldShowCodeWatchCollapsed { return "terminal" }
        if state.agentCollapsedReminder != nil { return "checkmark.message" }
        if state.agent.isBusy { return "sparkles" }
        if state.pomodoro.status == .completed || state.pomodoroCollapsedReminder != nil { return "timer" }
        if state.pomodoro.status == .running { return "timer" }
        return state.media.playback.isPlaying ? "waveform" : "sparkles"
    }

    private var collapsedTitle: String {
        if state.voiceInput.shouldDisplay { return state.voiceInput.displayText }
        if shouldShowCodeWatchCollapsed {
            return state.codeWatch.hasActiveSessions
                ? state.codeWatch.collapsedStatusTitle
                : state.codeWatchCollapsedReminder ?? state.codeWatch.collapsedStatusTitle
        }
        if let reminder = state.agentCollapsedReminder { return reminder }
        if state.agent.isBusy { return "悬屿运行中" }
        if let reminder = state.pomodoroCollapsedReminder { return reminder }
        if state.pomodoro.status == .completed { return state.pomodoro.noticeText.isEmpty ? "番茄钟完成" : state.pomodoro.noticeText }
        if state.pomodoro.status == .running { return "\(state.pomodoro.collapsedRunningTitle) \(state.pomodoro.formattedRemaining)" }
        return state.media.playback.isPlaying ? state.media.playback.title : "悬屿"
    }

    private var collapsedDropdownIcon: String {
        if state.voiceInput.state == .arming { return "command" }
        if state.voiceInput.state == .preparing || state.voiceInput.state == .permission { return "ellipsis.circle" }
        if state.voiceInput.state == .recording { return "mic.fill" }
        if state.voiceInput.state == .transcribing { return "waveform" }
        if state.voiceInput.state == .reviewing { return "text.bubble.fill" }
        if state.voiceInput.state == .submitted { return "checkmark.circle.fill" }
        if state.voiceInput.state == .error { return "exclamationmark.triangle.fill" }
        if shouldShowCodeWatchCollapsed { return "terminal" }
        if state.agentCollapsedReminder != nil { return "checkmark.message" }
        if state.agent.isBusy { return "sparkles" }
        if state.pomodoro.status == .completed || state.pomodoroCollapsedReminder != nil { return "timer" }
        if state.pomodoro.status == .running { return "timer" }
        if state.media.playback.isPlaying { return "waveform" }
        return "sparkles"
    }

    private func collapsedDropdownTitle(at date: Date) -> String {
        if state.voiceInput.shouldDisplay { return state.voiceInput.displayText }
        if shouldShowCodeWatchCollapsed {
            return state.codeWatch.hasActiveSessions
                ? state.codeWatch.collapsedStatusTitle
                : state.codeWatchCollapsedReminder ?? state.codeWatch.collapsedStatusTitle
        }
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
}

private struct LingdongHomeButton: View {
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            let label = HStack(spacing: 7) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .bold))
                Text("悬屿")
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? .white : .white.opacity(0.78))
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(width: 88)

            if selected {
                label.glassCapsule(tint: .white.opacity(0.18), interactive: false)
            } else {
                label.glassCapsule()
            }
        }
        .buttonStyle(.plain)
        .frame(width: 88)
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
            let label = HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                Text(title)
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(selected ? .white : .white.opacity(0.68))
            .padding(.horizontal, 9)
            .frame(height: 34)

            if selected {
                label.glassCapsule(tint: .white.opacity(0.12), interactive: false)
            } else {
                label.glassCapsule(interactive: false)
            }
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
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
        .glassCapsule(interactive: false)
        .frame(width: 130)
    }

    private var color: Color {
        switch service.status {
        case .completed:
            XYGlass.statusCompleted
        case .running:
            XYGlass.statusRunning
        case .paused:
            XYGlass.statusPaused
        case .idle:
            .white.opacity(0.72)
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
                .foregroundStyle(selected ? .white : .white.opacity(0.64))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .glassCapsule(tint: selected ? .white.opacity(0.12) : nil, interactive: false)
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
                .foregroundStyle(.white.opacity(0.74))
                .frame(width: 28, height: 28)
                .glassCircle()
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
