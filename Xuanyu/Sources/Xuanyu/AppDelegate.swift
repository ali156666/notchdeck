import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = IslandAppState()
    private var panelController: PanelWindowController?
    private var debugObservers: [NSObjectProtocol] = []
    private var servicesStarted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination("悬屿需要持续显示播放状态")
        ProcessInfo.processInfo.disableSuddenTermination()

        panelController = PanelWindowController(state: state)
        panelController?.showPanel()
        startServices()
        installDebugNotifications()
    }

    func applicationWillTerminate(_ notification: Notification) {
        debugObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        debugObservers.removeAll()
        stopServices()
        panelController?.close()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
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
        ]
    }

    private func openAgentSettings(_ tab: AgentSettingsTab) {
        state.mode = .agent
        state.agentSettingsTab = tab
        state.agentShowsSettings = true
        state.isExpanded = true
    }

    private func startServices() {
        guard !servicesStarted else { return }
        servicesStarted = true
        state.dashboard.start()
        state.media.start()
        state.agent.start()
        state.clipboard.start()
    }

    private func stopServices() {
        guard servicesStarted else { return }
        state.agent.stop()
        state.media.stop()
        state.pomodoro.stop()
        state.dashboard.stop()
        state.clipboard.stop()
        servicesStarted = false
    }
}
