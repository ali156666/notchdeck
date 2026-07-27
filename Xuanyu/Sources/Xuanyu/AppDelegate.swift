import AppKit
import AVFoundation
import SwiftUI

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    public override init() {
        super.init()
    }

    private let state = IslandAppState()
    private var keepAliveWindow: NSWindow?
    private var panelController: PanelWindowController?
    private var voiceGlowController: VoiceGlowOverlayWindowController?
    private var commandHoldMonitor: CommandHoldMonitor?
    private var debugObservers: [NSObjectProtocol] = []
    private var servicesStarted = false
    private var voiceHoldIsActive = false
    private var voiceStartTask: Task<Void, Never>?
    private var voiceMaximumDurationTask: Task<Void, Never>?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        terminateDuplicateInstances()
        ProcessInfo.processInfo.disableAutomaticTermination("悬屿需要持续显示播放状态")
        ProcessInfo.processInfo.disableSuddenTermination()

        installKeepAliveWindow()
        panelController = PanelWindowController(state: state)
        panelController?.showPanel()
        voiceGlowController = VoiceGlowOverlayWindowController(state: state)
        voiceGlowController?.showOverlay()
        startServices()
        installCommandHoldMonitor()
        installDebugNotifications()
        requestInitialVoicePermissions()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        commandHoldMonitor?.stop()
        commandHoldMonitor = nil
        voiceStartTask?.cancel()
        voiceMaximumDurationTask?.cancel()
        state.voiceInput.cancelRecording()
        debugObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        debugObservers.removeAll()
        stopServices()
        voiceGlowController?.close()
        voiceGlowController = nil
        panelController?.close()
        keepAliveWindow?.close()
        keepAliveWindow = nil
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func installDebugNotifications() {
        debugObservers = [
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.xuanyu.media.open"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.state.mode = .music
                    self?.state.isExpanded = true
                }
            },
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.xuanyu.media.close"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.state.isExpanded = false }
            },
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.xuanyu.media.refreshAirPods"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.state.media.refreshAirPods() }
            },
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.xuanyu.agent.open"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.state.mode = .agent
                    self?.state.agentShowsSettings = false
                    self?.state.isExpanded = true
                }
            },
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.xuanyu.agent.settings"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.state.mode = .agent
                    self?.state.agentSettingsTab = .model
                    self?.state.agentShowsSettings = true
                    self?.state.isExpanded = true
                }
            },
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.xuanyu.agent.settings.skills"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.openAgentSettings(.skills) }
            },
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.xuanyu.agent.settings.mcp"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.openAgentSettings(.mcp) }
            },
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.xuanyu.agent.debugComplete"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.state.isExpanded = false
                    self?.state.agent.raiseAnswerAttentionForDebug()
                }
            },
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.xuanyu.quick.open"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.state.mode = .quickApps
                    self?.state.isExpanded = true
                }
            },
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.xuanyu.clipboard.open"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.state.mode = .clipboard
                    self?.state.agentShowsSettings = false
                    self?.state.isExpanded = true
                }
            },
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.xuanyu.agent.debugRecognizeFile"),
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor in
                    guard let path = notification.userInfo?["path"] as? String else { return }
                    self?.state.mode = .agent
                    self?.state.agentShowsSettings = false
                    self?.state.isExpanded = true
                    self?.state.agent.recognizeFileURLs([URL(fileURLWithPath: path)])
                }
            },
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.xuanyu.pomodoro.debugConfigure"),
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor in
                    let title = notification.userInfo?["title"] as? String ?? ""
                    let minutes = notification.userInfo?["minutes"] as? Int ?? 1
                    self?.state.pomodoro.saveConfiguration(mode: .focus, title: title, minutes: minutes)
                    self?.state.pomodoro.selectMode(.focus)
                    self?.state.pomodoro.startPause()
                }
            },
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.xuanyu.pomodoro.debugComplete"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.state.isExpanded = false
                    self?.state.pomodoro.completeForDebug()
                }
            },
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.xuanyu.voice.debugArming"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.state.voiceInput.debugShowArming() }
            },
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.xuanyu.voice.debugRecording"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.state.voiceInput.debugShowRecording() }
            },
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.xuanyu.voice.debugReviewing"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.state.voiceInput.debugShowReviewing() }
            },
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.xuanyu.voice.debugDismiss"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.state.voiceInput.debugDismiss() }
            },
        ]
    }

    private func installKeepAliveWindow() {
        guard keepAliveWindow == nil else { return }
        let screen = ScreenDetector.preferredScreen
        let window = NSWindow(
            contentRect: NSRect(x: screen.frame.minX, y: screen.frame.minY, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.backgroundColor = .clear
        window.isOpaque = false
        window.alphaValue = 0.001
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.level = .normal
        window.orderFrontRegardless()
        keepAliveWindow = window
    }

    private func openAgentSettings(_ tab: AgentSettingsTab) {
        state.mode = .agent
        state.agentSettingsTab = tab
        state.agentShowsSettings = true
        state.isExpanded = true
    }

    private func installCommandHoldMonitor() {
        let monitor = CommandHoldMonitor(holdDuration: 0.5)
        monitor.onHoldBegan = { [weak self] in
            Task { @MainActor in self?.state.voiceInput.beginArming() }
        }
        monitor.onHoldProgress = { [weak self] progress in
            Task { @MainActor in self?.state.voiceInput.updateArmingProgress(progress) }
        }
        monitor.onLongPress = { [weak self] in
            Task { @MainActor in self?.beginVoiceInput() }
        }
        monitor.onRelease = { [weak self] in
            Task { @MainActor in self?.finishVoiceInput() }
        }
        monitor.onCancel = { [weak self] in
            Task { @MainActor in self?.cancelVoiceInput() }
        }
        monitor.onPermissionChanged = { [weak self] authorized in
            Task { @MainActor in self?.state.voiceInput.setInputMonitoringAuthorized(authorized) }
        }
        state.voiceInput.setInputMonitoringPermissionRequester { [weak monitor] in
            monitor?.requestPermission()
        }
        commandHoldMonitor = monitor
        monitor.start()
    }

    private func requestInitialVoicePermissions() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard let self else { return }
            NSApp.activate(ignoringOtherApps: true)
            _ = await state.voiceInput.requestMicrophonePermission()
        }
    }

    private func terminateDuplicateInstances() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        for application in NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ) where application.processIdentifier != currentPID {
            application.terminate()
        }
    }

    private func beginVoiceInput() {
        guard state.agent.isConfigured else {
            state.voiceInput.cancelArming()
            openAgentSettings(.model)
            return
        }

        voiceHoldIsActive = true
        voiceStartTask?.cancel()
        voiceMaximumDurationTask?.cancel()
        voiceStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let started = await state.voiceInput.startRecording()
            guard started else {
                voiceHoldIsActive = false
                return
            }
            guard voiceHoldIsActive, !Task.isCancelled else {
                state.voiceInput.cancelRecording()
                return
            }

            voiceMaximumDurationTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                self?.finishVoiceInput()
            }
        }
    }

    private func finishVoiceInput() {
        guard voiceHoldIsActive else {
            state.voiceInput.cancelPendingStart()
            state.voiceInput.cancelArming()
            return
        }

        voiceHoldIsActive = false
        voiceStartTask?.cancel()
        voiceStartTask = nil
        voiceMaximumDurationTask?.cancel()
        voiceMaximumDurationTask = nil
        state.voiceInput.cancelPendingStart()

        Task { @MainActor [weak self] in
            guard let self,
                  let text = await state.voiceInput.finishRecording(),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return
            }
            state.isExpanded = false
        }
    }

    private func cancelVoiceInput() {
        voiceHoldIsActive = false
        voiceStartTask?.cancel()
        voiceStartTask = nil
        voiceMaximumDurationTask?.cancel()
        voiceMaximumDurationTask = nil
        if state.voiceInput.state == .arming {
            state.voiceInput.cancelArming()
        } else {
            state.voiceInput.cancelRecording()
        }
    }

    private func startServices() {
        guard !servicesStarted else { return }
        servicesStarted = true
        state.dashboard.start()
        state.media.start()
        state.agent.start()
        state.clipboard.start()
        state.codeWatch.start()
    }

    private func stopServices() {
        guard servicesStarted else { return }
        state.agent.stop()
        state.media.stop()
        state.pomodoro.stop()
        state.dashboard.stop()
        state.clipboard.stop()
        state.codeWatch.stop()
        servicesStarted = false
    }
}
