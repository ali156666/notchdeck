import AppKit
import SwiftUI

private final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class TransparentPanelHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }

    required init(rootView: Content) {
        super.init(rootView: rootView)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
    }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
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
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.layer?.isOpaque = false

        let hostingView = TransparentPanelHostingView(rootView: NotchPanelView(state: state, screen: screen))
        hostingView.sizingOptions = []
        hostingView.frame = container.bounds
        hostingView.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)
        return container
    }

    private func panelSize(for screen: NSScreen) -> NSSize {
        if state.voiceInput.prefersLargeHUD {
            let isReviewing = state.voiceInput.state == .reviewing
            return NSSize(
                width: isReviewing ? min(620, screen.frame.width - 40) : min(480, screen.frame.width - 40),
                height: ScreenDetector.topBarHeight(for: screen) + (isReviewing ? 164 : 96)
            )
        }

        if state.isExpanded {
            // 多出的 40/28 边距给 SwiftUI 自绘阴影留空间，避免被窗口边缘硬裁
            switch state.mode {
            case .dashboard:
                return NSSize(width: min(1020, screen.frame.width - 24), height: 454)
            case .music:
                return NSSize(width: min(920, screen.frame.width - 24), height: 304)
            case .quickApps:
                return NSSize(width: min(1020, screen.frame.width - 24), height: 212)
            case .clipboard:
                return NSSize(width: min(800, screen.frame.width - 40), height: 304)
            case .agent:
                return NSSize(width: min(960, screen.frame.width - 24), height: min(588, screen.frame.height - 32))
            }
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
