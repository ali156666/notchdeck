import AppKit
import SwiftUI

struct MediaIslandPanel: View {
    var service: MediaIslandService
    var showsHeader = true

    var body: some View {
        VStack(spacing: 12) {
            if showsHeader {
                header
            }
            player
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 16)
    }

    private var header: some View {
        HStack(spacing: 10) {
            AirPodsInlineView(status: service.airPods)
            Spacer(minLength: 12)
            Button {
                Task { await service.refreshAirPods() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(width: 24, height: 24)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .help("刷新 AirPods")
        }
    }

    private var player: some View {
        HStack(alignment: .center, spacing: 22) {
            artwork

            VStack(alignment: .leading, spacing: 10) {
                titleBlock
                progress
                controls
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var artwork: some View {
        ZStack {
            if let data = service.playback.artwork, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(
                    colors: [.white.opacity(0.17), .white.opacity(0.04)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: service.playback.hasPlayableTrack ? "music.note" : "play.rectangle")
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.70))
            }
        }
        .frame(width: 128, height: 128)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.10), lineWidth: 1)
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(simplifiedChinese: service.playback.title)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)

            Text(simplifiedChinese: service.playback.artist)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(1)

            TimelineView(.animation(minimumInterval: 0.25)) { timeline in
                Text(simplifiedChinese: service.currentLyricLine(at: timeline.date))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.66))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var progress: some View {
        TimelineView(.animation(minimumInterval: service.playback.isPlaying ? 0.2 : nil)) { timeline in
            let duration = max(service.playback.duration, 1)
            Slider(
                value: Binding(
                    get: { min(service.displayedElapsedTime(at: timeline.date), duration) },
                    set: { value in
                        Task { await service.seek(to: value) }
                    }
                ),
                in: 0...duration
            )
            .controlSize(.small)
            .tint(.white)
        }
        .frame(height: 22)
    }

    private var controls: some View {
        HStack(spacing: 13) {
            MediaCircleButton(icon: "backward.fill", size: 40, tooltip: "上一首") {
                Task { await service.previousTrack() }
            }
            MediaCircleButton(
                icon: service.playback.isPlaying ? "pause.fill" : "play.fill",
                size: 54,
                tooltip: service.playback.isPlaying ? "暂停" : "播放"
            ) {
                Task { await service.togglePlay() }
            }
            MediaCircleButton(icon: "forward.fill", size: 40, tooltip: "下一首") {
                Task { await service.nextTrack() }
            }
            MediaCircleButton(icon: "shuffle", size: 40, selected: service.playback.isShuffled, tooltip: "随机播放") {
                Task { await service.toggleShuffle() }
            }
            MediaCircleButton(icon: "repeat", size: 40, selected: service.playback.repeatMode != .off, tooltip: "循环播放") {
                Task { await service.toggleRepeat() }
            }
            if service.playback.supportsFavorite {
                MediaCircleButton(
                    icon: service.playback.isFavorite ? "star.fill" : "star",
                    size: 40,
                    selected: service.playback.isFavorite,
                    tooltip: "收藏"
                ) {
                    Task { await service.toggleFavorite() }
                }
            }
        }
    }
}

struct AirPodsInlineView: View {
    let status: IslandAirPodsStatus

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: status.isConnected ? "airpodspro" : "airpodspro.chargingcase.wireless")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))

            Text(status.isConnected ? status.name : "AirPods 未连接")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.80))
                .lineLimit(1)

            if status.isConnected {
                BatteryPill(label: "L", value: status.leftBattery)
                BatteryPill(label: "R", value: status.rightBattery)
                BatteryPill(label: "C", value: status.caseBattery)
            }
        }
    }
}

struct BatteryPill: View {
    let label: String
    let value: Int?

    var body: some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.58))
            Text(value.map { "\($0)%" } ?? "--")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(value == nil ? .white.opacity(0.36) : .white.opacity(0.88))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.white.opacity(0.09), in: Capsule())
    }
}

private extension Text {
    /// Tags the string as Simplified Chinese so CoreText selects Simplified
    /// glyph variants instead of falling back to Traditional/Japanese forms for
    /// Han-unified code points.
    init(simplifiedChinese string: String) {
        var attributed = AttributedString(string)
        attributed.languageIdentifier = "zh-Hans"
        self.init(attributed)
    }
}

private struct MediaCircleButton: View {
    let icon: String
    let size: CGFloat
    var selected = false
    let tooltip: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size > 44 ? 22 : 16, weight: .bold))
                .foregroundStyle(selected ? Color(red: 0.45, green: 1.0, blue: 0.58) : .white.opacity(0.92))
                .frame(width: size, height: size)
                .background(.white.opacity(hovering ? 0.20 : 0.11), in: Circle())
                .scaleEffect(hovering ? 1.06 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tooltip)
    }
}
