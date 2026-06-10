import Foundation
import UniformTypeIdentifiers

enum AgentFileDrop {
    static let typeIdentifiers = [UTType.fileURL.identifier]

    static func loadFileURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) -> Bool {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        var didStart = false

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            didStart = true
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let url = fileURL(from: item) {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }

        if didStart {
            group.notify(queue: .main) {
                completion(urls)
            }
        }
        return didStart
    }

    static func fileURL(from item: NSSecureCoding?) -> URL? {
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let url = item as? URL {
            return url
        }
        if let url = item as? NSURL {
            return url as URL
        }
        if let text = item as? String {
            return URL(string: text)
        }
        return nil
    }
}
