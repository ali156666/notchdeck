import SwiftUI

// 液态玻璃样式中心。
// 分层原则：玻璃最多两层（面板容器 + 一级卡片），卡片内部二级表面一律用
// innerSurface（白色覆盖层），禁止三层嵌套玻璃；ScrollView 行内不上玻璃。
enum XYGlass {
    static let panelRadius: CGFloat = 30
    static let collapsedRadius: CGFloat = 13
    static let cardL: CGFloat = 14
    static let cardM: CGFloat = 12
    static let cardS: CGFloat = 8
    static let media: CGFloat = 18

    // 面板玻璃常驻黑色 tint，恢复原来的深色灵动岛视觉。
    static let panelTint = Color.black.opacity(0.45)

    static let statusRunning = Color(red: 0.36, green: 1.0, blue: 0.52)
    static let statusPaused = Color(red: 1.0, green: 0.78, blue: 0.32)
    static let statusAlert = Color(red: 1.0, green: 0.34, blue: 0.34)
    static let statusBusy = Color(red: 0.42, green: 0.78, blue: 1.0)
    static let statusCompleted = Color(red: 1.0, green: 0.58, blue: 0.38)
}

extension View {
    func glassCard(radius: CGFloat = XYGlass.cardL,
                   tint: Color? = nil,
                   interactive: Bool = false) -> some View {
        var glass: Glass = .regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glassEffect(glass, in: .rect(cornerRadius: radius))
    }

    func glassCapsule(tint: Color? = nil, interactive: Bool = true) -> some View {
        var glass: Glass = .regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glassEffect(glass, in: .capsule)
    }

    func glassCircle(tint: Color? = nil, interactive: Bool = true) -> some View {
        var glass: Glass = .regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glassEffect(glass, in: .circle)
    }

    func innerSurface(radius: CGFloat = XYGlass.cardS, opacity: Double = 0.10) -> some View {
        background(.white.opacity(opacity),
                   in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    func transparentGlassCard(radius: CGFloat = XYGlass.cardL,
                              opacity: Double = 0.06,
                              strokeOpacity: Double = 0.36,
                              shadowOpacity: Double = 0.08,
                              interactive: Bool = true) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        var glass: Glass = .regular
        if interactive { glass = glass.interactive() }

        return ZStack {
            // 玻璃只作为底层机体；内容层放在最后，避免图标/文字被 glassEffect 当作背景一起折射。
            shape
                .fill(.clear)
                .glassEffect(glass, in: shape)
                .opacity(opacity)
                .allowsHitTesting(false)

            shape
                .fill(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.045),
                            .white.opacity(0.012),
                            .clear,
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .allowsHitTesting(false)

            self
        }
        .clipShape(shape)
        .overlay {
            shape
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(strokeOpacity), .white.opacity(0.10), .clear],
                        startPoint: .top,
                        endPoint: .center
                    ),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(shadowOpacity), radius: 10, y: 7)
    }

    func transparentGlassCapsule(opacity: Double = 0.06,
                                 strokeOpacity: Double = 0.34,
                                 interactive: Bool = false) -> some View {
        var glass: Glass = .regular
        if interactive { glass = glass.interactive() }

        return ZStack {
            Capsule()
                .fill(.clear)
                .glassEffect(glass, in: .capsule)
                .opacity(opacity)
                .allowsHitTesting(false)

            self
        }
        .overlay {
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(strokeOpacity), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
        }
    }
}

// 主岛液态玻璃背景。
// 对应 liquid-glass-react 的四个可复用信号：
// 1. backdrop blur + saturation：VisualEffectBlur + 原生 glassEffect。
// 2. over-light 深色遮罩：panelTint 压亮度，恢复黑色岛体。
// 3. pointer-driven edge highlight：鼠标位置驱动边缘 specular gradient。
// 4. elastic press：点击时轻微收缩，保留系统 glass interactive 反馈。
struct LiquidGlassPanelBackground<S: InsettableShape>: View {
    let shape: S
    var tint: Color = XYGlass.panelTint
    var accent: Color = .white
    var isExpanded = false
    var isPressed = false
    var pointerLocation: CGPoint?

    var body: some View {
        GeometryReader { proxy in
            let pointer = normalizedPointer(in: proxy.size)
            let glass = configuredGlass

            ZStack {
                VisualEffectBlur(material: .hudWindow, appearance: .darkAqua)
                    .clipShape(shape)

                shape
                    .fill(.clear)
                    .glassEffect(glass, in: shape)

                shape
                    .fill(tint)

                shape
                    .fill(baseSheen(pointer: pointer))
                    .blendMode(.screen)
                    .opacity(isExpanded ? 0.78 : 0.62)

                shape
                    .fill(pointerGlow(pointer: pointer))
                    .blendMode(.screen)
                    .opacity(pointerLocation == nil ? 0.22 : 0.44)

                LiquidGlassHighlight(
                    shape: shape,
                    pointer: pointer,
                    accent: accent,
                    isPressed: isPressed
                )
            }
            .compositingGroup()
            .clipShape(shape)
            .animation(.snappy(duration: 0.20), value: pointerLocation == nil)
        }
    }

    private var configuredGlass: Glass {
        var glass: Glass = .regular.tint(tint)
        glass = glass.interactive()
        return glass
    }

    private func normalizedPointer(in size: CGSize) -> UnitPoint {
        guard let pointerLocation, size.width > 1, size.height > 1 else {
            return UnitPoint(x: 0.52, y: 0.12)
        }
        return UnitPoint(
            x: min(max(pointerLocation.x / size.width, 0), 1),
            y: min(max(pointerLocation.y / size.height, 0), 1)
        )
    }

    private func baseSheen(pointer: UnitPoint) -> LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .white.opacity(0.30), location: 0.00),
                .init(color: accent.opacity(0.13), location: 0.18),
                .init(color: .clear, location: 0.50),
                .init(color: .white.opacity(0.12), location: 0.78),
                .init(color: .white.opacity(0.28), location: 1.00),
            ],
            startPoint: UnitPoint(x: min(max(pointer.x - 0.24, 0), 1), y: 0),
            endPoint: UnitPoint(x: min(max(pointer.x + 0.28, 0), 1), y: 1)
        )
    }

    private func pointerGlow(pointer: UnitPoint) -> RadialGradient {
        RadialGradient(
            stops: [
                .init(color: .white.opacity(0.34), location: 0.00),
                .init(color: accent.opacity(0.16), location: 0.22),
                .init(color: .clear, location: 0.72),
            ],
            center: pointer,
            startRadius: 0,
            endRadius: isExpanded ? 260 : 120
        )
    }
}

// 非 Agent 展开态的透明玻璃底板。
// 保持原来的透明感，只用极轻的 behind-window blur 压掉背后文字细节；
// 不再叠高 opacity 的 popover/aqua 磨砂灰雾。
struct TransparentIslandGlassBackground<S: InsettableShape>: View {
    let shape: S

    var body: some View {
        ZStack {
            VisualEffectBlur(material: .underWindowBackground)
                .opacity(0.24)
                .clipShape(shape)

            shape
                .fill(.clear)
                .glassEffect(.regular, in: shape)
                .opacity(0.12)

            shape
                .fill(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.018),
                            .white.opacity(0.004),
                            .clear,
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .blendMode(.screen)

            shape
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.34), .white.opacity(0.10), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        }
        .compositingGroup()
        .clipShape(shape)
        .allowsHitTesting(false)
    }
}


struct VoiceIslandGlassBackground<S: InsettableShape>: View {
    let shape: S
    var accent: Color = .white

    var body: some View {
        ZStack {
            shape
                .fill(.clear)
                .glassEffect(.regular, in: shape)
                .opacity(0.18)

            shape
                .fill(
                    LinearGradient(
                        colors: [
                            .white.opacity(0.055),
                            accent.opacity(0.055),
                            .black.opacity(0.028),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .blendMode(.screen)

            shape
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.026), .clear, .black.opacity(0.018)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            shape
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.42), .white.opacity(0.12), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        }
        .compositingGroup()
        .clipShape(shape)
        .allowsHitTesting(false)
    }
}

// 真实 behind-window 背景模糊：玻璃面板的底层。
// SwiftUI glassEffect 在全透明窗口里采不到窗口内内容，质感出不来，
// 因此主面板用 NSVisualEffectView 提供桌面模糊，再叠高光/光泽模拟液态玻璃。
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var appearance: NSAppearance.Name?

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        if let appearance {
            view.appearance = NSAppearance(named: appearance)
        }
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        if let appearance {
            view.appearance = NSAppearance(named: appearance)
        } else {
            view.appearance = nil
        }
    }
}

// 液态玻璃面板高光层：内侧折射柔光带 + 顶部光泽 + 锐利 specular 边缘。
// 底部圆角是视觉上的"玻璃曲面"，反光最强；顶边贴屏幕边缘，光泽收敛。
struct LiquidGlassHighlight<S: InsettableShape>: View {
    let shape: S
    var pointer = UnitPoint(x: 0.52, y: 0.12)
    var accent: Color = .white
    var isPressed = false

    var body: some View {
        ZStack {
            // 内侧柔光带：模拟厚玻璃边缘的折射光晕
            shape
                .strokeBorder(.white.opacity(isPressed ? 0.38 : 0.30), lineWidth: 6)
                .blur(radius: isPressed ? 6 : 8)
                .clipShape(shape)

            // 顶部斜向光泽 + 底部回光：大面积柔和渐变让表面显得顺滑
            shape
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(isPressed ? 0.28 : 0.20), location: 0),
                            .init(color: accent.opacity(0.10), location: 0.22),
                            .init(color: .clear, location: 0.52),
                            .init(color: .white.opacity(0.10), location: 1),
                        ],
                        startPoint: UnitPoint(x: pointer.x, y: 0),
                        endPoint: UnitPoint(x: 1 - pointer.x, y: 1)
                    )
                )

            // 锐利 specular 边缘：底部曲面反光最亮
            shape
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(isPressed ? 0.50 : 0.38), location: 0),
                            .init(color: .white.opacity(0.16), location: 0.30),
                            .init(color: accent.opacity(0.22), location: 0.58),
                            .init(color: .white.opacity(0.34), location: 0.72),
                            .init(color: .white.opacity(isPressed ? 0.94 : 0.82), location: 1),
                        ],
                        startPoint: UnitPoint(x: pointer.x, y: 0),
                        endPoint: UnitPoint(x: 1 - pointer.x, y: 1)
                    ),
                    lineWidth: 1.4
                )

            // 第二层细高光，紧贴边缘内侧，增强"厚玻璃"层次
            shape
                .inset(by: 1.4)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.10), .white.opacity(0.28)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.8
                )
                .blur(radius: 0.6)
        }
        .allowsHitTesting(false)
    }
}
