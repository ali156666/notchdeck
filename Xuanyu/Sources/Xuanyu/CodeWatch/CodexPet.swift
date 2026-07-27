import AppKit
import CodeWatchCore
import ImageIO
import SwiftUI

struct CodexPet: Identifiable, Equatable {
    let id: String
    let displayName: String
    let description: String
    let spritesheetURL: URL
    let spriteVersionNumber: Int
}

enum CodexPetCatalog {
    private struct Manifest: Decodable {
        let id: String
        let displayName: String
        let description: String
        let spriteVersionNumber: Int?
        let spritesheetPath: String
    }

    static func defaultRoot() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let codexHome = environment["CODEX_HOME"], !codexHome.isEmpty {
            return URL(fileURLWithPath: codexHome, isDirectory: true)
                .appendingPathComponent("pets", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/pets", isDirectory: true)
    }

    static func load(from root: URL = defaultRoot()) -> [CodexPet] {
        let fileManager = FileManager.default
        guard let directories = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return directories.compactMap { directory -> CodexPet? in
            guard directory.lastPathComponent != "_runs",
                  (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else {
                return nil
            }

            let manifestURL = directory.appendingPathComponent("pet.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
            else {
                return nil
            }

            let spritesheetURL = directory.appendingPathComponent(manifest.spritesheetPath)
            guard let dimensions = imageDimensions(at: spritesheetURL),
                  dimensions.width == 1536,
                  dimensions.height == 1872 || dimensions.height == 2288
            else {
                return nil
            }

            guard let version = resolvedVersion(
                width: dimensions.width,
                height: dimensions.height,
                declaredVersion: manifest.spriteVersionNumber
            ) else { return nil }

            return CodexPet(
                id: manifest.id,
                displayName: manifest.displayName,
                description: manifest.description,
                spritesheetURL: spritesheetURL,
                spriteVersionNumber: version
            )
        }
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    static func resolvedVersion(width: Int, height: Int, declaredVersion: Int?) -> Int? {
        guard width == 1536 else { return nil }
        let inferredVersion: Int
        switch height {
        case 1872: inferredVersion = 1
        case 2288: inferredVersion = 2
        default: return nil
        }
        let version = declaredVersion ?? inferredVersion
        guard version == inferredVersion else { return nil }
        return version
    }

    private static func imageDimensions(at url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else {
            return nil
        }
        return (width, height)
    }
}

private final class CodexPetSpriteSheet {
    private static let columns = 8
    private static let cellWidth = 192
    private static let cellHeight = 208

    private let framesByRow: [[CGImage]]

    init?(url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == Self.columns * Self.cellWidth,
              image.height % Self.cellHeight == 0
        else {
            return nil
        }

        let rows = image.height / Self.cellHeight
        var loadedRows: [[CGImage]] = []
        loadedRows.reserveCapacity(rows)

        for row in 0..<rows {
            var rowFrames: [CGImage] = []
            for column in 0..<Self.columns {
                let cropRect = CGRect(
                    x: column * Self.cellWidth,
                    y: row * Self.cellHeight,
                    width: Self.cellWidth,
                    height: Self.cellHeight
                )
                guard let frame = image.cropping(to: cropRect) else { continue }
                if Self.hasVisiblePixels(frame) {
                    rowFrames.append(frame)
                }
            }
            loadedRows.append(rowFrames)
        }

        framesByRow = loadedRows
    }

    func frames(for status: MascotAgentStatus) -> [CGImage] {
        let preferredRow: Int
        switch status {
        case .idle:
            preferredRow = 0
        case .processing, .running:
            preferredRow = 7
        case .waitingApproval, .waitingQuestion:
            preferredRow = 6
        }

        if framesByRow.indices.contains(preferredRow), !framesByRow[preferredRow].isEmpty {
            return framesByRow[preferredRow]
        }
        return framesByRow.first(where: { !$0.isEmpty }) ?? []
    }

    private static func hasVisiblePixels(_ image: CGImage) -> Bool {
        let sampleWidth = min(image.width, 96)
        let sampleHeight = min(image.height, 104)
        var pixels = [UInt8](repeating: 0, count: sampleWidth * sampleHeight * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: sampleWidth,
                height: sampleHeight,
                bitsPerComponent: 8,
                bytesPerRow: sampleWidth * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .none
            context.clear(CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
            context.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
            return true
        }
        guard rendered else { return false }
        return stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] > 3 }
    }
}

private final class CodexPetSpriteCache {
    static let shared = CodexPetSpriteCache()
    private let cache = NSCache<NSString, CodexPetSpriteSheet>()

    func sheet(for pet: CodexPet) -> CodexPetSpriteSheet? {
        let key = pet.spritesheetURL.path as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let loaded = CodexPetSpriteSheet(url: pet.spritesheetURL) else { return nil }
        cache.setObject(loaded, forKey: key)
        return loaded
    }
}

struct CodexPetSpriteView: View {
    let pet: CodexPet
    let status: MascotAgentStatus
    var size: CGFloat = 27

    var body: some View {
        let frames = CodexPetSpriteCache.shared.sheet(for: pet)?.frames(for: status) ?? []
        if frames.isEmpty {
            Image(systemName: "pawprint.fill")
                .font(.system(size: size * 0.58, weight: .bold))
                .foregroundStyle(.white.opacity(0.82))
                .frame(width: size, height: size)
        } else {
            MascotTimeline(interval: status == .idle ? 0.16 : 0.10) { time in
                let interval = status == .idle ? 0.16 : 0.10
                let index = Int(max(0, time) / interval) % frames.count
                Image(decorative: frames[index], scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: size, height: size)
            }
            .frame(width: size, height: size)
            .clipped()
        }
    }
}
