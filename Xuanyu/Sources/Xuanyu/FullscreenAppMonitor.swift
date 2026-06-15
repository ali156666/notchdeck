import AppKit

@MainActor
final class FullscreenAppMonitor {
    private let interval: TimeInterval = 0.45
    private let isEnabled: () -> Bool
    private let update: (Bool) -> Void
    private var workspaceObservers: [NSObjectProtocol] = []
    private var timer: Timer?

    init(isEnabled: @escaping () -> Bool, update: @escaping (Bool) -> Void) {
        self.isEnabled = isEnabled
        self.update = update
    }

    func start() {
        stop()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }

        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            },
            center.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            },
        ]
    }

    func stop() {
        timer?.invalidate()
        timer = nil

        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { center.removeObserver($0) }
        workspaceObservers.removeAll()
    }

    private func refresh() {
        guard isEnabled() else {
            update(false)
            return
        }

        update(FullscreenAppDetector.hasFullscreenWindow(on: ScreenDetector.preferredScreen))
    }
}
