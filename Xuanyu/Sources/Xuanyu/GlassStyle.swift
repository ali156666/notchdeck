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

    // 面板玻璃常驻黑色 tint，保证浅色壁纸下白色文字可读
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
        }
    }
}

// 液态玻璃面板高光层：内侧折射柔光带 + 顶部光泽 + 锐利 specular 边缘。
// 底部圆角是视觉上的"玻璃曲面"，反光最强；顶边贴屏幕边缘，光泽收敛。
struct LiquidGlassHighlight<S: InsettableShape>: View {
    let shape: S

    var body: some View {
        ZStack {
            // 内侧柔光带：模拟厚玻璃边缘的折射光晕
            shape
                .strokeBorder(.white.opacity(0.30), lineWidth: 6)
                .blur(radius: 8)
                .clipShape(shape)

            // 顶部斜向光泽 + 底部回光：大面积柔和渐变让表面显得顺滑
            shape
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.20), location: 0),
                            .init(color: .white.opacity(0.07), location: 0.22),
                            .init(color: .clear, location: 0.52),
                            .init(color: .white.opacity(0.10), location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            // 锐利 specular 边缘：底部曲面反光最亮
            shape
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.38), location: 0),
                            .init(color: .white.opacity(0.16), location: 0.30),
                            .init(color: .white.opacity(0.30), location: 0.72),
                            .init(color: .white.opacity(0.82), location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
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
