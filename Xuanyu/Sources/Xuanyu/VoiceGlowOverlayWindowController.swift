import AppKit
import SwiftUI

private final class VoiceGlowPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
    }
}

@MainActor
final class VoiceGlowOverlayWindowController: NSObject {
    private let state: IslandAppState
    private var panel: NSPanel?
    private var layoutTimer: Timer?

    init(state: IslandAppState) {
        self.state = state
        super.init()
    }

    func showOverlay() {
        let screen = ScreenDetector.preferredScreen
        let panel = VoiceGlowPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = makeContentView(for: screen)
        panel.setFrame(screen.frame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        installLayoutTimer()
    }

    func close() {
        NotificationCenter.default.removeObserver(self)
        layoutTimer?.invalidate()
        layoutTimer = nil
        panel?.close()
        panel = nil
    }

    @objc private func screenParametersChanged() {
        let screen = ScreenDetector.preferredScreen
        panel?.contentView = makeContentView(for: screen)
        updatePanelFrame()
    }

    private func installLayoutTimer() {
        layoutTimer?.invalidate()
        layoutTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updatePanelFrame() }
        }
    }

    private func updatePanelFrame() {
        guard let panel else { return }
        let screen = ScreenDetector.preferredScreen
        guard abs(panel.frame.width - screen.frame.width) > 0.5 ||
              abs(panel.frame.height - screen.frame.height) > 0.5 ||
              abs(panel.frame.minX - screen.frame.minX) > 0.5 ||
              abs(panel.frame.minY - screen.frame.minY) > 0.5
        else {
            return
        }
        panel.contentView?.setFrameSize(screen.frame.size)
        panel.setFrame(screen.frame, display: true)
    }

    private func makeContentView(for screen: NSScreen) -> NSView {
        let hostingView = TransparentHostingView(rootView: VoiceGlowOverlayView(state: state))
        hostingView.frame = NSRect(origin: .zero, size: screen.frame.size)
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.isOpaque = false
        return hostingView
    }
}

private struct VoiceGlowOverlayView: View {
    let state: IslandAppState
    @State private var wakeStartedAt: Date?

    private let wakeDuration: TimeInterval = 0.24

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            GeometryReader { proxy in
                let wakeProgress = wakeProgress(at: timeline.date)
                let breath = breathValue(at: timeline.date)
                let flowPhase = timeline.date.timeIntervalSinceReferenceDate
                ZStack {
                    if shouldShowVoiceGlow {
                        VoiceWaterFlowEdgeGlow(
                            palette: palette,
                            intensity: glowIntensity,
                            wakeProgress: wakeProgress,
                            breath: breath,
                            flowPhase: flowPhase,
                            flowStrength: flowStrength,
                            flowSpeed: flowSpeed
                        )
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.easeOut(duration: 0.18), value: shouldShowVoiceGlow)
                .animation(.easeInOut(duration: 0.18), value: state.voiceInput.state)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            syncWakeVisibility(shouldShowVoiceGlow)
        }
        .onChange(of: shouldShowVoiceGlow) { _, visible in
            syncWakeVisibility(visible)
        }
    }

    private var shouldShowVoiceGlow: Bool {
        switch state.voiceInput.state {
        case .idle, .arming:
            return false
        case .preparing, .permission, .recording, .transcribing, .reviewing, .submitted, .error:
            return true
        }
    }

    private var glowIntensity: Double {
        switch state.voiceInput.state {
        case .idle:
            return 0
        case .arming:
            return 0
        case .preparing, .permission:
            return 0.95
        case .recording:
            return 1.35
        case .transcribing, .reviewing:
            return 1.10
        case .submitted:
            return 0.80
        case .error:
            return 1.15
        }
    }

    private var flowStrength: Double {
        switch state.voiceInput.state {
        case .recording:
            return 1.0
        case .preparing, .permission:
            return 0.56
        case .transcribing, .reviewing:
            return 0.42
        case .submitted, .error:
            return 0.26
        case .idle, .arming:
            return 0
        }
    }

    private var flowSpeed: Double {
        switch state.voiceInput.state {
        case .recording:
            return 0.18
        case .preparing, .permission:
            return 0.12
        case .transcribing, .reviewing:
            return 0.075
        case .submitted, .error:
            return 0.045
        case .idle, .arming:
            return 0
        }
    }

    private var palette: [Color] {
        switch state.voiceInput.state {
        case .recording:
            return [
                Color(red: 0.36, green: 0.58, blue: 1.00),
                Color(red: 0.74, green: 0.24, blue: 1.00),
                Color(red: 1.00, green: 0.20, blue: 0.78),
                Color(red: 0.22, green: 0.76, blue: 1.00),
                Color(red: 0.64, green: 0.28, blue: 1.00),
            ]
        case .transcribing, .reviewing:
            return [
                Color(red: 0.34, green: 0.78, blue: 1.00),
                Color(red: 0.50, green: 0.58, blue: 1.00),
                Color(red: 0.72, green: 0.48, blue: 1.00),
                Color(red: 0.34, green: 0.78, blue: 1.00),
            ]
        case .submitted:
            return [
                Color(red: 0.36, green: 1.00, blue: 0.58),
                Color(red: 0.44, green: 0.86, blue: 1.00),
                Color(red: 0.70, green: 1.00, blue: 0.72),
            ]
        case .error:
            return [
                Color(red: 1.00, green: 0.40, blue: 0.28),
                Color(red: 1.00, green: 0.62, blue: 0.20),
                Color(red: 0.86, green: 0.42, blue: 1.00),
            ]
        case .preparing, .permission:
            return [
                Color(red: 1.00, green: 0.70, blue: 0.26),
                Color(red: 0.86, green: 0.52, blue: 1.00),
                Color(red: 0.48, green: 0.74, blue: 1.00),
            ]
        case .arming, .idle:
            return [
                Color.white.opacity(0.78),
                Color(red: 0.72, green: 0.62, blue: 1.00),
                Color(red: 0.44, green: 0.78, blue: 1.00),
            ]
        }
    }

    private func breathValue(at date: Date) -> Double {
        guard state.voiceInput.state == .recording else { return 0.40 }
        let phase = date.timeIntervalSinceReferenceDate * (2.0 * Double.pi / 1.45)
        return (sin(phase) + 1) / 2
    }

    private func syncWakeVisibility(_ visible: Bool) {
        if visible {
            guard wakeStartedAt == nil else { return }
            wakeStartedAt = Date()
        } else {
            wakeStartedAt = nil
        }
    }

    private func wakeProgress(at date: Date) -> Double {
        guard shouldShowVoiceGlow, let wakeStartedAt else { return 0 }
        let elapsed = date.timeIntervalSince(wakeStartedAt)
        return max(0, min(1, elapsed / wakeDuration))
    }
}

private struct VoiceWaterFlowEdgeGlow: View {
    let palette: [Color]
    let intensity: Double
    let wakeProgress: Double
    let breath: Double
    let flowPhase: TimeInterval
    let flowStrength: Double
    let flowSpeed: Double

    var body: some View {
        GeometryReader { proxy in
            let edgeReveal = pow(clamp(wakeProgress), 1.35)
            let flowReveal = smoothstep(clamp(wakeProgress))
            let effectiveFlowStrength = flowStrength * flowReveal
            let revealOpacity = 0.03 + 0.97 * edgeReveal
            let breathLift = 0.90 + 0.20 * breath * effectiveFlowStrength
            let edgeScale = 0.82 + 0.18 * edgeReveal
            let cornerRadius = min(max(proxy.size.width, proxy.size.height) * 0.035, 46)
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            let rotation = flowPhase * flowSpeed * 2.0 * Double.pi
            let gradient = AngularGradient(
                gradient: Gradient(colors: palette + [palette.first ?? .purple]),
                center: .center,
                startAngle: .radians(rotation),
                endAngle: .radians(rotation + 2.0 * Double.pi)
            )
            let counterGradient = AngularGradient(
                gradient: Gradient(colors: Array(palette.reversed()) + [palette.last ?? .blue]),
                center: .center,
                startAngle: .radians(-rotation * 0.62),
                endAngle: .radians(-rotation * 0.62 + 2.0 * Double.pi)
            )
            let sideGradient = LinearGradient(
                colors: [
                    .clear,
                    palette.first?.opacity(0.92) ?? .purple.opacity(0.92),
                    palette.dropFirst().first?.opacity(1.0) ?? .blue.opacity(1.0),
                    palette.last?.opacity(0.92) ?? .purple.opacity(0.92),
                    .clear,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            let coreOpacity = min(1.0, 1.00 * intensity * revealOpacity * breathLift)
            let middleOpacity = min(1.0, (0.44 + 0.32 * flowReveal) * intensity * revealOpacity * breathLift)
            let outerOpacity = min(1.0, (0.24 + 0.26 * flowReveal) * intensity * revealOpacity * breathLift)
            let sideOpacity = min(1.0, (0.48 + 0.34 * flowReveal) * intensity * revealOpacity * breathLift)
            let topOpacity = min(1.0, (0.26 + 0.22 * flowReveal) * intensity * revealOpacity * breathLift)
            let lineBreath = 1.0 + 0.20 * breath * effectiveFlowStrength
            let blurBreath = 1.0 + 0.16 * breath * effectiveFlowStrength
            let firstFlow = normalized(flowPhase * flowSpeed + 0.02)
            let secondFlow = normalized(flowPhase * flowSpeed * 0.72 + 0.36)
            let thirdFlow = normalized(0.88 - flowPhase * flowSpeed * 0.52)

            ZStack {
                shape
                    .stroke(gradient, lineWidth: (4.2 + 1.8 * effectiveFlowStrength) * lineBreath)
                    .blur(radius: 0.85 * blurBreath)
                    .opacity(coreOpacity)
                    .padding(10)

                shape
                    .stroke(gradient, lineWidth: (22 + 19 * flowReveal) * lineBreath)
                    .blur(radius: (10 + 15 * flowReveal) * blurBreath)
                    .opacity(middleOpacity)
                    .padding(8)

                shape
                    .stroke(counterGradient, lineWidth: (44 + 54 * flowReveal) * lineBreath)
                    .blur(radius: (22 + 34 * flowReveal) * blurBreath)
                    .opacity(outerOpacity)
                    .padding(2)

                flowingSegment(
                    shape: shape,
                    phase: firstFlow,
                    length: 0.22,
                    gradient: gradient,
                    lineWidth: (16 + 8 * breath) * effectiveFlowStrength + 5,
                    blur: 4 + 4 * effectiveFlowStrength,
                    opacity: min(1, 0.88 * intensity * revealOpacity * effectiveFlowStrength),
                    padding: 9
                )

                flowingSegment(
                    shape: shape,
                    phase: secondFlow,
                    length: 0.14,
                    gradient: counterGradient,
                    lineWidth: (12 + 5 * breath) * effectiveFlowStrength + 4,
                    blur: 7 + 5 * effectiveFlowStrength,
                    opacity: min(1, 0.58 * intensity * revealOpacity * effectiveFlowStrength),
                    padding: 7
                )

                flowingSegment(
                    shape: shape,
                    phase: thirdFlow,
                    length: 0.09,
                    gradient: gradient,
                    lineWidth: (9 + 4 * breath) * effectiveFlowStrength + 3,
                    blur: 2 + 4 * effectiveFlowStrength,
                    opacity: min(1, 0.48 * intensity * revealOpacity * effectiveFlowStrength),
                    padding: 12
                )

                HStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(sideGradient)
                        .frame(width: (30 + 26 * flowReveal) * lineBreath)
                        .blur(radius: (20 + 22 * flowReveal) * blurBreath)
                        .opacity(sideOpacity)

                    Spacer(minLength: 0)

                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(sideGradient)
                        .frame(width: (30 + 26 * flowReveal) * lineBreath)
                        .blur(radius: (20 + 22 * flowReveal) * blurBreath)
                        .opacity(sideOpacity)
                }
                .padding(.vertical, 28)
                .padding(.horizontal, 2)

                VStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    .clear,
                                    palette.dropFirst().first?.opacity(0.82) ?? .purple.opacity(0.82),
                                    palette.last?.opacity(0.72) ?? .pink.opacity(0.72),
                                    .clear,
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(height: (20 + 20 * flowReveal) * lineBreath)
                        .blur(radius: (18 + 17 * flowReveal) * blurBreath)
                        .opacity(topOpacity)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 36)
            }
            .scaleEffect(edgeScale, anchor: .center)
            .opacity(revealOpacity)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func flowingSegment(
        shape: RoundedRectangle,
        phase: Double,
        length: Double,
        gradient: AngularGradient,
        lineWidth: Double,
        blur: Double,
        opacity: Double,
        padding: Double
    ) -> some View {
        let start = normalized(phase)
        let segmentLength = min(max(length, 0), 1)
        let end = start + segmentLength
        let style = StrokeStyle(lineWidth: CGFloat(lineWidth), lineCap: .round, lineJoin: .round)

        if end <= 1 {
            shape
                .trim(from: start, to: end)
                .stroke(gradient, style: style)
                .blur(radius: blur)
                .opacity(opacity)
                .padding(padding)
        } else {
            shape
                .trim(from: start, to: 1)
                .stroke(gradient, style: style)
                .blur(radius: blur)
                .opacity(opacity)
                .padding(padding)

            shape
                .trim(from: 0, to: end - 1)
                .stroke(gradient, style: style)
                .blur(radius: blur)
                .opacity(opacity)
                .padding(padding)
        }
    }

    private func clamp(_ value: Double) -> Double {
        max(0, min(1, value))
    }

    private func smoothstep(_ value: Double) -> Double {
        let clamped = clamp(value)
        return clamped * clamped * (3 - 2 * clamped)
    }

    private func normalized(_ value: Double) -> Double {
        let remainder = value.truncatingRemainder(dividingBy: 1)
        return remainder >= 0 ? remainder : remainder + 1
    }
}
