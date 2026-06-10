import Foundation
import Observation

enum PomodoroMode: String, CaseIterable, Codable, Identifiable {
    case focus
    case shortBreak
    case longBreak

    var id: String { rawValue }

    var title: String {
        switch self {
        case .focus: "专注"
        case .shortBreak: "短休息"
        case .longBreak: "长休息"
        }
    }

    var defaultMinutes: Int {
        switch self {
        case .focus: 25
        case .shortBreak: 5
        case .longBreak: 15
        }
    }
}

enum PomodoroStatus: String, Codable {
    case idle
    case running
    case paused
    case completed
}

struct PomodoroModeConfig: Codable, Equatable {
    var title: String
    var minutes: Int

    static func defaultValue(for mode: PomodoroMode) -> PomodoroModeConfig {
        PomodoroModeConfig(title: "", minutes: mode.defaultMinutes)
    }
}

private struct PomodoroPersistedState: Codable {
    var mode: PomodoroMode
    var status: PomodoroStatus
    var remainingSeconds: Int
    var completedFocusCount: Int
    var endDate: Date?
    var focus: PomodoroModeConfig
    var shortBreak: PomodoroModeConfig
    var longBreak: PomodoroModeConfig
}

@MainActor
@Observable
final class PomodoroService {
    var mode: PomodoroMode = .focus
    var status: PomodoroStatus = .idle
    var remainingSeconds = PomodoroMode.focus.defaultMinutes * 60
    var completedFocusCount = 0
    var noticeToken = 0
    var noticeText = ""

    @ObservationIgnored private var configurations: [PomodoroMode: PomodoroModeConfig] = [
        .focus: .defaultValue(for: .focus),
        .shortBreak: .defaultValue(for: .shortBreak),
        .longBreak: .defaultValue(for: .longBreak),
    ]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var endDate: Date?

    init() {
        if !restore() {
            persist()
        }
    }

    var isActive: Bool {
        status == .running || status == .paused || status == .completed
    }

    var formattedRemaining: String {
        let minutes = max(remainingSeconds, 0) / 60
        let seconds = max(remainingSeconds, 0) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var collapsedRunningTitle: String {
        let title = configuration(for: mode).title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? mode.title : title
    }

    func configuration(for mode: PomodoroMode) -> PomodoroModeConfig {
        configurations[mode] ?? .defaultValue(for: mode)
    }

    func saveConfiguration(mode editedMode: PomodoroMode, title: String, minutes: Int) {
        let sanitizedTitle = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        configurations[editedMode] = PomodoroModeConfig(title: sanitizedTitle, minutes: min(max(minutes, 1), 240))
        if editedMode == mode {
            reset()
        } else {
            persist()
        }
    }

    func selectMode(_ newMode: PomodoroMode) {
        guard status != .running else { return }
        mode = newMode
        reset()
    }

    func startPause() {
        switch status {
        case .running:
            syncRemainingSeconds()
            status = .paused
            endDate = nil
            stopTimer()
        case .idle, .paused, .completed:
            if remainingSeconds <= 0 || status == .completed {
                remainingSeconds = duration(for: mode)
            }
            status = .running
            noticeText = ""
            endDate = Date().addingTimeInterval(TimeInterval(remainingSeconds))
            startTimer()
        }
        persist()
    }

    func reset() {
        stopTimer()
        status = .idle
        remainingSeconds = duration(for: mode)
        endDate = nil
        noticeText = ""
        persist()
    }

    func stop() {
        stopTimer()
    }

    func completeForDebug() {
        complete()
    }

    func cycleMode() {
        guard status != .running else { return }
        switch mode {
        case .focus:
            selectMode(.shortBreak)
        case .shortBreak:
            selectMode(.longBreak)
        case .longBreak:
            selectMode(.focus)
        }
    }

    private func restore() -> Bool {
        guard let data = try? Data(contentsOf: Self.configURL),
              let saved = try? JSONDecoder().decode(PomodoroPersistedState.self, from: data)
        else {
            return false
        }
        mode = saved.mode
        status = saved.status
        remainingSeconds = saved.remainingSeconds
        completedFocusCount = saved.completedFocusCount
        endDate = saved.endDate
        configurations = [
            .focus: saved.focus,
            .shortBreak: saved.shortBreak,
            .longBreak: saved.longBreak,
        ]

        if status == .running {
            syncRemainingSeconds()
            if remainingSeconds <= 0 {
                complete()
            } else {
                startTimer()
            }
        } else if status == .completed {
            noticeText = completionNotice
        }
        return true
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard status == .running else { return }
        syncRemainingSeconds()
        if remainingSeconds <= 0 {
            complete()
        }
    }

    private func syncRemainingSeconds() {
        guard let endDate else { return }
        remainingSeconds = max(0, Int(ceil(endDate.timeIntervalSinceNow)))
    }

    private func complete() {
        stopTimer()
        remainingSeconds = 0
        endDate = nil
        status = .completed
        if mode == .focus {
            completedFocusCount += 1
        }
        noticeText = completionNotice
        noticeToken += 1
        persist()
    }

    private var completionNotice: String {
        let title = configuration(for: mode).title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            return "\(title) · 已完成"
        }
        return mode == .focus ? "专注完成" : "休息结束"
    }

    private func duration(for mode: PomodoroMode) -> Int {
        configuration(for: mode).minutes * 60
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: Self.configDirectory, withIntermediateDirectories: true)
            let state = PomodoroPersistedState(
                mode: mode,
                status: status,
                remainingSeconds: remainingSeconds,
                completedFocusCount: completedFocusCount,
                endDate: endDate,
                focus: configuration(for: .focus),
                shortBreak: configuration(for: .shortBreak),
                longBreak: configuration(for: .longBreak)
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: Self.configURL, options: .atomic)
        } catch {
            NSLog("Xuanyu pomodoro save failed: \(error)")
        }
    }

    private static var configDirectory: URL {
        AppSupportDirectory.root
    }

    private static var configURL: URL {
        configDirectory.appendingPathComponent("pomodoro.json")
    }
}
