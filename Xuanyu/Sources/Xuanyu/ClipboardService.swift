import AppKit
import Observation

enum ClipboardItemKind: String, Codable, Equatable {
    case text
    case image
    case files
}

struct ClipboardItem: Identifiable, Codable, Equatable {
    var id: UUID
    var type: ClipboardItemKind
    var title: String
    var previewText: String
    var text: String?
    var fileURLs: [URL]
    var imageData: Data?
    var createdAt: Date
    var sourceAppName: String?
    var signature: String
    var byteCount: Int

    init(
        id: UUID = UUID(),
        type: ClipboardItemKind,
        title: String,
        previewText: String,
        text: String? = nil,
        fileURLs: [URL] = [],
        imageData: Data? = nil,
        createdAt: Date = Date(),
        sourceAppName: String? = nil,
        signature: String,
        byteCount: Int = 0
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.previewText = previewText
        self.text = text
        self.fileURLs = fileURLs
        self.imageData = imageData
        self.createdAt = createdAt
        self.sourceAppName = sourceAppName
        self.signature = signature
        self.byteCount = byteCount
    }
}

@MainActor
@Observable
final class ClipboardService {
    var items: [ClipboardItem] = []
    var isMonitoring = false
    var lastCapturedAt: Date?

    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private let maxItems = 50

    init() {
        load()
    }

    func start() {
        guard !isMonitoring else { return }
        isMonitoring = true
        lastChangeCount = NSPasteboard.general.changeCount
        captureCurrentPasteboard()
        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollPasteboard() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isMonitoring = false
    }

    func refresh() {
        lastChangeCount = NSPasteboard.general.changeCount - 1
        pollPasteboard()
    }

    func clear() {
        items.removeAll()
        save()
    }

    func remove(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func copy(_ item: ClipboardItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch item.type {
        case .text:
            guard let text = item.text else { return }
            pasteboard.setString(text, forType: .string)
        case .image:
            guard let data = item.imageData else { return }
            if let image = NSImage(data: data) {
                pasteboard.writeObjects([image])
            } else {
                pasteboard.setData(data, forType: .png)
            }
        case .files:
            pasteboard.writeObjects(item.fileURLs.map { $0 as NSURL })
        }

        lastChangeCount = pasteboard.changeCount
    }

    func icon(for url: URL) -> NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }

    private func pollPasteboard() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        captureCurrentPasteboard(from: pasteboard)
    }

    private func captureCurrentPasteboard(from pasteboard: NSPasteboard = .general) {
        guard let item = makeItem(from: pasteboard) else { return }
        guard items.first?.signature != item.signature else { return }
        items.insert(item, at: 0)
        if items.count > maxItems {
            items.removeLast(items.count - maxItems)
        }
        lastCapturedAt = item.createdAt
        save()
    }

    private func makeItem(from pasteboard: NSPasteboard) -> ClipboardItem? {
        if let filesItem = makeFilesItem(from: pasteboard) {
            return filesItem
        }
        if let imageItem = makeImageItem(from: pasteboard) {
            return imageItem
        }
        if let textItem = makeTextItem(from: pasteboard) {
            return textItem
        }
        return nil
    }

    private func makeTextItem(from pasteboard: NSPasteboard) -> ClipboardItem? {
        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }

        let trimmedLines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let title = trimmedLines.first.map { String($0.prefix(18)) } ?? "文本"
        let preview = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(4)
            .joined(separator: "\n")
        let data = Data(text.utf8)

        return ClipboardItem(
            type: .text,
            title: title.isEmpty ? "文本" : title,
            previewText: preview.isEmpty ? text : preview,
            text: text,
            createdAt: Date(),
            sourceAppName: sourceAppName(),
            signature: "text:\(Self.stableHash(data))",
            byteCount: text.count
        )
    }

    private func makeImageItem(from pasteboard: NSPasteboard) -> ClipboardItem? {
        var data = pasteboard.data(forType: .png)
        if data == nil, let tiffData = pasteboard.data(forType: .tiff) {
            data = Self.pngData(fromImageData: tiffData) ?? tiffData
        }
        if data == nil,
           let image = NSImage(pasteboard: pasteboard) {
            data = Self.pngData(from: image)
        }
        guard let imageData = data, !imageData.isEmpty else { return nil }

        let image = NSImage(data: imageData)
        let sizeText: String
        if let size = image?.size, size.width > 0, size.height > 0 {
            sizeText = "\(Int(size.width)) x \(Int(size.height))"
        } else {
            sizeText = Self.formatBytes(imageData.count)
        }

        return ClipboardItem(
            type: .image,
            title: "图片",
            previewText: sizeText,
            imageData: imageData,
            createdAt: Date(),
            sourceAppName: sourceAppName(),
            signature: "image:\(Self.stableHash(imageData))",
            byteCount: imageData.count
        )
    }

    private func makeFilesItem(from pasteboard: NSPasteboard) -> ClipboardItem? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [NSURL] else {
            return nil
        }

        let urls = objects
            .map { $0 as URL }
            .filter { $0.isFileURL }
            .map { $0.standardizedFileURL }
        guard !urls.isEmpty else { return nil }

        let names = urls.map(\.lastPathComponent)
        let title = urls.count == 1 ? names[0] : "\(urls.count) 个文件"
        let preview = names.prefix(4).joined(separator: "\n")
        let signatureInput = urls
            .map(\.path)
            .sorted()
            .joined(separator: "\n")
        let byteCount = urls.reduce(0) { partial, url in
            partial + Self.fileByteCount(for: url)
        }

        return ClipboardItem(
            type: .files,
            title: title,
            previewText: preview,
            fileURLs: urls,
            createdAt: Date(),
            sourceAppName: sourceAppName(),
            signature: "files:\(Self.stableHash(Data(signatureInput.utf8)))",
            byteCount: byteCount
        )
    }

    private func sourceAppName() -> String? {
        NSWorkspace.shared.frontmostApplication?.localizedName
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.configURL),
              let savedItems = try? Self.decoder.decode([ClipboardItem].self, from: data)
        else {
            return
        }
        items = Array(savedItems.prefix(maxItems))
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: Self.configDirectory, withIntermediateDirectories: true)
            try Self.encoder.encode(items).write(to: Self.configURL, options: .atomic)
        } catch {
            NSLog("Xuanyu clipboard save failed: \(error)")
        }
    }

    private static var configDirectory: URL {
        AppSupportDirectory.root
    }

    private static var configURL: URL {
        configDirectory.appendingPathComponent("clipboard-history.json")
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func stableHash(_ data: Data) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in data {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        return String(hash, radix: 16)
    }

    private static func pngData(fromImageData data: Data) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        return pngData(from: image)
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData)
        else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func fileByteCount(for url: URL) -> Int {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey]) else {
            return 0
        }
        return values.fileSize ?? values.totalFileAllocatedSize ?? 0
    }

    static func formatBytes(_ bytes: Int) -> String {
        guard bytes > 0 else { return "0 KB" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
