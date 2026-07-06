import AppKit
import SwiftUI

struct QuickAppsPanel: View {
    @Bindable var service: QuickLaunchService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("打开 App", systemImage: "square.grid.2x2")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.84))
                Text("\(service.apps.count)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.42))
                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(spacing: 10) {
                    ForEach(service.apps) { app in
                        QuickAppCard(app: app, service: service)
                    }
                    AddQuickAppCard {
                        service.chooseApplications()
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }
}

private struct QuickAppCard: View {
    let app: QuickLaunchApp
    var service: QuickLaunchService
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                service.launch(app)
            } label: {
                VStack(spacing: 6) {
                    Image(nsImage: service.icon(for: app))
                        .resizable()
                        .scaledToFit()
                        .frame(width: 44, height: 44)
                        .shadow(color: .black.opacity(0.20), radius: 1.5, y: 1)

                    Text(app.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(app.isInstalled ? 0.92 : 0.48))
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.42), radius: 2, y: 1)
                }
                .padding(8)
                .frame(width: 82, height: 82)
                .transparentGlassCard(
                    radius: XYGlass.cardM,
                    opacity: hovering ? 0.10 : 0.06,
                    strokeOpacity: hovering ? 0.52 : 0.34,
                    shadowOpacity: hovering ? 0.12 : 0.06,
                    interactive: true
                )
                .scaleEffect(hovering ? 1.025 : 1)
            }
            .buttonStyle(.plain)
            .disabled(!app.isInstalled)

            if hovering {
                Button {
                    service.remove(app)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.70))
                        .frame(width: 18, height: 18)
                        .background(.white.opacity(0.13), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(5)
                .help("移除 \(app.name)")
            }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("移除 \(app.name)", role: .destructive) {
                service.remove(app)
            }
        }
    }
}

private struct AddQuickAppCard: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .medium))
                Text("添加")
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(.white.opacity(hovering ? 0.88 : 0.68))
            .frame(width: 82, height: 82)
            .transparentGlassCard(
                radius: XYGlass.cardM,
                opacity: hovering ? 0.10 : 0.05,
                strokeOpacity: hovering ? 0.48 : 0.28,
                shadowOpacity: hovering ? 0.10 : 0.05,
                interactive: true
            )
            .overlay {
                RoundedRectangle(cornerRadius: XYGlass.cardM, style: .continuous)
                    .stroke(.white.opacity(hovering ? 0.24 : 0.12), style: StrokeStyle(lineWidth: 1, dash: [6]))
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("添加快捷 App")
    }
}
