import Foundation

enum AppSupportDirectory {
    static var root: URL {
        if let overridePath = ProcessInfo.processInfo.environment["XUANYU_APP_SUPPORT_ROOT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !overridePath.isEmpty
        {
            return URL(fileURLWithPath: overridePath, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Xuanyu", isDirectory: true)
    }

    static var agent: URL {
        root.appendingPathComponent("agent", isDirectory: true)
    }

    static var voice: URL {
        root.appendingPathComponent("voice", isDirectory: true)
    }
}
