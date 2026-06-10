import AppKit
import SwiftUI

private final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class PanelWindowController: NSObject {
    private let state: IslandAppState
    private var panel: NSPanel?
    private var outsideClickMonitor: Any?
    private var escapeMonitor: Any?
    private var layoutTimer: Timer?

    init(state: IslandAppState) {
        self.state = state
        super.init()
    }

    func showPanel() {
        let screen = ScreenDetector.preferredScreen
        let size = panelSize(for: screen)

        let panel = IslandPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.acceptsMouseMovedEvents = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = makeContentView(for: screen, size: size)
        panel.setFrame(panelFrame(for: screen), display: true)
        panel.orderFrontRegardless()
        self.panel = panel
        installLayoutTimer()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state.isExpanded else { return }
                guard let frame = self.panel?.frame, !frame.contains(NSEvent.mouseLocation) else { return }
                withAnimation(.snappy(duration: 0.28)) {
                    self.state.isExpanded = false
                }
            }
        }

        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            Task { @MainActor in
                withAnimation(.snappy(duration: 0.28)) {
                    self?.state.isExpanded = false
                }
            }
            return nil
        }
    }

    func close() {
        NotificationCenter.default.removeObserver(self)
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        layoutTimer?.invalidate()
        outsideClickMonitor = nil
        escapeMonitor = nil
        layoutTimer = nil
        panel?.close()
        panel = nil
    }

    @objc private func screenParametersChanged() {
        if let panel {
            let screen = ScreenDetector.preferredScreen
            panel.contentView = makeContentView(for: screen, size: panel.frame.size)
        }
        updatePanelFrame(animated: true)
    }

    private func installLayoutTimer() {
        layoutTimer?.invalidate()
        layoutTimer = Timer.scheduledTimer(withTimeInterval: 0.18, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updatePanelFrame(animated: false) }
        }
    }

    private func updatePanelFrame(animated: Bool) {
        guard let panel else { return }
        let screen = ScreenDetector.preferredScreen
        let frame = panelFrame(for: screen)
        guard abs(panel.frame.width - frame.width) > 0.5 ||
              abs(panel.frame.height - frame.height) > 0.5 ||
              abs(panel.frame.minX - frame.minX) > 0.5 ||
              abs(panel.frame.minY - frame.minY) > 0.5
        else {
            return
        }
        panel.contentView?.setFrameSize(frame.size)
        panel.setFrame(frame, display: true, animate: animated)
    }

    private func makeContentView(for screen: NSScreen, size: NSSize) -> NSView {
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        let hostingView = NSHostingView(rootView: NotchPanelView(state: state, screen: screen))
        hostingView.sizingOptions = []
        hostingView.frame = container.bounds
        hostingView.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)
        return container
    }

    private func panelSize(for screen: NSScreen) -> NSSize {
        if state.isExpanded {
            switch state.mode {
            case .dashboard:
                return NSSize(width: min(980, screen.frame.width - 24), height: 426)
            case .music:
                return NSSize(width: min(880, screen.frame.width - 24), height: 276)
            case .quickApps:
                return NSSize(width: min(980, screen.frame.width - 24), height: 184)
            case .clipboard:
                return NSSize(width: min(760, screen.frame.width - 40), height: 276)
            case .agent:
                return NSSize(width: min(920, screen.frame.width - 24), height: min(560, screen.frame.height - 32))
            }
        }

        if state.isMiniExpanded {
            return NSSize(width: min(520, screen.frame.width - 24), height: ScreenDetector.topBarHeight(for: screen) + 74)
        }

        let width = ScreenDetector.collapsedIslandWidth(for: screen)
        let height = state.collapsedIslandHeight(for: screen)
        return NSSize(width: width, height: height)
    }

    private func panelFrame(for screen: NSScreen) -> NSRect {
        let size = panelSize(for: screen)
        let x = screen.frame.midX - size.width / 2
        return NSRect(
            x: x,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }
}
