import Foundation

enum AppSupportDirectory {
    static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Xuanyu", isDirectory: true)
    }

    static var agent: URL {
        root.appendingPathComponent("agent", isDirectory: true)
    }

}
