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
    let voiceInput = VoiceInputService()
    let codeWatch = CodeWatchService()
    var isExpanded = false
    var mode: IslandMode = .dashboard
    var agentShowsSettings = false
    var agentSettingsTab: AgentSettingsTab = .model
    var agentCollapsedReminder: String?
    var pomodoroCollapsedReminder: String?
    var codeWatchCollapsedReminder: String?

    var shouldShowCollapsedLyrics: Bool {
        return media.playback.isPlaying && media.playback.hasPlayableTrack
    }

    var usesTallCollapsedDropdown: Bool {
        return voiceInput.shouldDisplay ||
        shouldShowCollapsedLyrics ||
        codeWatch.hasActiveSessions ||
        codeWatchCollapsedReminder != nil ||
        pomodoro.status == .running ||
        pomodoro.status == .completed ||
        pomodoroCollapsedReminder != nil
    }

    var usesIdleCollapsedHeight: Bool {
        return !voiceInput.shouldDisplay &&
        !agent.isBusy &&
        agentCollapsedReminder == nil &&
        !codeWatch.hasActiveSessions &&
        codeWatchCollapsedReminder == nil &&
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
