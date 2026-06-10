import AppKit
import Observation

@MainActor
@Observable
final class IslandAppState {
    let media = MediaIslandService()
    let agent = AgentService()
    let pomodoro = PomodoroService()
    let quickLaunch = QuickLaunchService()
    let dashboard = SystemDashboardService()
    let clipboard = ClipboardService()
    var isExpanded = false
    var isMiniExpanded = false
    var mode: IslandMode = .dashboard
    var agentShowsSettings = false
    var agentSettingsTab: AgentSettingsTab = .model
    var agentCollapsedReminder: String?
    var pomodoroCollapsedReminder: String?

    var shouldShowCollapsedLyrics: Bool {
        return media.playback.isPlaying && media.playback.hasPlayableTrack
    }

    var usesTallCollapsedDropdown: Bool {
        return shouldShowCollapsedLyrics ||
        pomodoro.status == .running ||
        pomodoro.status == .completed ||
        pomodoroCollapsedReminder != nil
    }

    var usesIdleCollapsedHeight: Bool {
        return !agent.isBusy &&
        agentCollapsedReminder == nil &&
        pomodoro.status != .running &&
        pomodoro.status != .completed &&
        pomodoroCollapsedReminder == nil
    }

    func collapsedIslandHeight(for screen: NSScreen) -> CGFloat {
        ScreenDetector.collapsedIslandHeight(
            for: screen,
            usesTallDropdown: usesTallCollapsedDropdown,
            isIdle: usesIdleCollapsedHeight
        )
    }
}
