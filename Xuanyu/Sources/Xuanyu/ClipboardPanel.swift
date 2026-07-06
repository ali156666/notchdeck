import AppKit
import SwiftUI

struct ClipboardPanel: View {
    @Bindable var service: ClipboardService
    @State private var query = ""
    @State private var selectedFilter: ClipboardFilter = .all

    private var filteredItems: [ClipboardItem] {
        service.items.filter { item in
            selectedFilter.matches(item) && item.matches(query: query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label("剪贴板", systemImage: "doc.on.clipboard")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.86))
                Text("\(service.items.count)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.42))
                Circle()
                    .fill(service.isMonitoring ? Color.green : Color.white.opacity(0.28))
                    .frame(width: 6, height: 6)

                ClipboardSearchField(text: $query)
                    .frame(width: 132)

                HStack(spacing: 4) {
                    ForEach(ClipboardFilter.allCases, id: \.self) { filter in
                        ClipboardFilterButton(
                            filter: filter,
                            selected: selectedFilter == filter
                        ) {
                            selectedFilter = filter
                        }
                    }
                }

                Spacer()
                ClipboardIconButton(icon: "arrow.clockwise", help: "刷新剪贴板") {
                    service.refresh()
                }
                ClipboardIconButton(icon: "trash", help: "清空历史") {
                    service.clear()
                }
                .disabled(service.items.isEmpty)
                .opacity(service.items.isEmpty ? 0.42 : 1)
            }
            .frame(height: 28)

            if service.items.isEmpty || filteredItems.isEmpty {
                ClipboardEmptyState(
                    message: service.items.isEmpty ? "复制文字、图片或文件后会出现在这里" : "没有匹配的剪贴板内容",
                    icon: service.items.isEmpty ? "doc.on.clipboard" : "magnifyingglass"
                )
                    .frame(maxWidth: .infinity)
                    .frame(height: 136)
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    // 玻璃卡数量护栏：剪贴板历史可能很多条，超过 20 条时不再上玻璃
                    LazyHStack(alignment: .top, spacing: 10) {
                        ForEach(filteredItems) { item in
                            ClipboardCard(item: item, service: service, usesGlass: filteredItems.count <= 20)
                        }
                    }
                    .padding(.bottom, 5)
                }
                .frame(height: 142, alignment: .top)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }
}

private struct ClipboardEmptyState: View {
    let message: String
    let icon: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
            Text(message)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.44))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transparentGlassCard(
            radius: XYGlass.cardS,
            opacity: 0.05,
            strokeOpacity: 0.30,
            shadowOpacity: 0.06,
            interactive: false
        )
    }
}

private struct ClipboardCard: View {
    let item: ClipboardItem
    @Bindable var service: ClipboardService
    var usesGlass = true
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                service.copy(item)
            } label: {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .top, spacing: 7) {
                        ClipboardKindBadge(kind: item.type)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(kindTitle)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white.opacity(0.93))
                                .lineLimit(1)
                            Text(timeText)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white.opacity(0.58))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 18)
                    }

                    preview
                        .frame(maxWidth: .infinity, minHeight: 60, maxHeight: 60, alignment: .topLeading)

                    Spacer(minLength: 0)

                    HStack(spacing: 6) {
                        Text(detailText)
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(1)
                            .minimumScaleFactor(0.74)
                        Spacer(minLength: 2)
                        Image(systemName: "arrow.uturn.backward.circle.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                }
                .padding(10)
                .frame(width: 146, height: 132, alignment: .topLeading)
                .modifier(ClipboardCardSurface(
                    usesGlass: usesGlass,
                    hovering: hovering
                ))
                .scaleEffect(hovering ? 1.018 : 1)
            }
            .buttonStyle(.plain)

            if hovering {
                Button {
                    service.remove(item)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.88))
                        .frame(width: 18, height: 18)
                        .background(.white.opacity(0.14), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(6)
                .help("删除")
            }
        }
        .onHover { hovering = $0 }
        .help("复制回剪贴板")
    }

    @ViewBuilder
    private var preview: some View {
        switch item.type {
        case .text:
            Text(item.previewText)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        case .image:
            if let data = item.imageData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        Text("IMG")
                            .font(.system(size: 9, weight: .black))
                            .foregroundStyle(.white.opacity(0.86))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.white.opacity(0.16), in: Capsule())
                            .padding(5)
                    }
            } else {
                ClipboardSymbolPreview(icon: "photo")
            }
        case .files:
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Image(nsImage: firstFileIcon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 34, height: 34)
                    Text(fileCountText)
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                }
                Text(item.previewText)
                    .font(.system(size: 10.8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var firstFileIcon: NSImage {
        guard let url = item.fileURLs.first else {
            return NSImage(systemSymbolName: "doc", accessibilityDescription: nil) ?? NSImage()
        }
        return service.icon(for: url)
    }

    private var kindTitle: String {
        switch item.type {
        case .text:
            "文本"
        case .image:
            "图片"
        case .files:
            item.fileURLs.count == 1 ? "文件" : "文件组"
        }
    }

    private var detailText: String {
        switch item.type {
        case .text:
            return "\(item.byteCount) 个字符"
        case .image:
            return ClipboardService.formatBytes(item.byteCount)
        case .files:
            if item.byteCount > 0 {
                return ClipboardService.formatBytes(item.byteCount)
            }
            return fileCountText
        }
    }

    private var fileCountText: String {
        item.fileURLs.count == 1 ? item.title : "\(item.fileURLs.count) 项"
    }

    private var timeText: String {
        let seconds = max(0, Int(Date().timeIntervalSince(item.createdAt)))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(seconds / 60) 分钟前" }
        if seconds < 86400 { return "\(seconds / 3600) 小时前" }
        return "\(seconds / 86400) 天前"
    }

}

private struct ClipboardCardSurface: ViewModifier {
    let usesGlass: Bool
    let hovering: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: XYGlass.cardS, style: .continuous)
        if usesGlass {
            content.transparentGlassCard(
                radius: XYGlass.cardS,
                opacity: hovering ? 0.10 : 0.06,
                strokeOpacity: hovering ? 0.48 : 0.32,
                shadowOpacity: hovering ? 0.12 : 0.06,
                interactive: true
            )
        } else {
            content
                .background(.white.opacity(hovering ? 0.08 : 0.05), in: shape)
                .overlay {
                    shape
                        .strokeBorder(.white.opacity(hovering ? 0.34 : 0.22), lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(hovering ? 0.10 : 0.05), radius: 10, y: 7)
        }
    }
}

private struct ClipboardKindBadge: View {
    let kind: ClipboardItemKind

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 12, weight: .heavy))
            .foregroundStyle(.white.opacity(0.9))
            .frame(width: 26, height: 26)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            }
    }

    private var icon: String {
        switch kind {
        case .text:
            "text.alignleft"
        case .image:
            "photo"
        case .files:
            "folder"
        }
    }
}

private struct ClipboardSymbolPreview: View {
    let icon: String

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(.white.opacity(0.72))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(.white.opacity(0.10), lineWidth: 1)
            }
    }
}

private struct ClipboardIconButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(hovering ? 0.92 : 0.68))
                .frame(width: 28, height: 28)
                .glassCircle(tint: hovering ? Color.white.opacity(0.10) : nil)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

private enum ClipboardFilter: String, CaseIterable {
    case all
    case text
    case image
    case files

    var title: String {
        switch self {
        case .all:
            "全部"
        case .text:
            "文本"
        case .image:
            "图片"
        case .files:
            "文件"
        }
    }

    func matches(_ item: ClipboardItem) -> Bool {
        switch self {
        case .all:
            true
        case .text:
            item.type == .text
        case .image:
            item.type == .image
        case .files:
            item.type == .files
        }
    }
}

private struct ClipboardSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(.white.opacity(0.42))
            TextField("搜索", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.86))
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.46))
                }
                .buttonStyle(.plain)
                .help("清空搜索")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .transparentGlassCard(
            radius: XYGlass.cardS,
            opacity: 0.04,
            strokeOpacity: 0.20,
            shadowOpacity: 0.02,
            interactive: false
        )
    }
}

private struct ClipboardFilterButton: View {
    let filter: ClipboardFilter
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(filter.title)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(selected ? .white : .white.opacity(0.68))
                .padding(.horizontal, 7)
                .frame(height: 24)
                .background(selected ? .white.opacity(0.22) : .white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(.white.opacity(selected ? 0.22 : 0.08), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .help(filter.title)
    }
}

private extension ClipboardItem {
    func matches(query: String) -> Bool {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return true }
        let haystack = [
            title,
            previewText,
            text ?? "",
            sourceAppName ?? "",
            fileURLs.map(\.lastPathComponent).joined(separator: " "),
        ].joined(separator: " ").localizedLowercase
        return haystack.contains(trimmedQuery.localizedLowercase)
    }
}
