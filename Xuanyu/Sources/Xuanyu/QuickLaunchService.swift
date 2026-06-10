import AppKit
import Observation
import UniformTypeIdentifiers

struct QuickLaunchApp: Codable, Equatable, Identifiable {
    var bundleIdentifier: String
    var name: String
    var path: String

    var id: String { bundleIdentifier }
    var url: URL { URL(fileURLWithPath: path) }
    var isInstalled: Bool { FileManager.default.fileExists(atPath: path) }
}

@MainActor
@Observable
final class QuickLaunchService {
    var apps: [QuickLaunchApp] = []

    init() {
        if let saved = Self.loadSavedApps() {
            apps = saved
        } else {
            apps = Self.defaultApps()
            save()
        }
    }

    func chooseApplications() {
        let panel = NSOpenPanel()
        panel.title = "添加快捷 App"
        panel.prompt = "添加"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)

        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        guard response == .OK else { return }
        addApplications(panel.urls)
        if panel.urls.isEmpty {
            NSSound.beep()
        }
    }

    func addApplications(_ urls: [URL]) {
        var updated = apps
        for url in urls {
            guard let item = Self.app(from: url),
                  !updated.contains(where: { $0.bundleIdentifier == item.bundleIdentifier })
            else {
                continue
            }
            updated.append(item)
        }
        apps = updated
        save()
    }

    func remove(_ app: QuickLaunchApp) {
        apps.removeAll { $0.bundleIdentifier == app.bundleIdentifier }
        save()
    }

    func launch(_ app: QuickLaunchApp) {
        guard app.isInstalled else { return }
        NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration())
    }

    func icon(for app: QuickLaunchApp) -> NSImage {
        guard app.isInstalled else {
            return NSWorkspace.shared.icon(for: .application)
        }
        return NSWorkspace.shared.icon(forFile: app.path)
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: Self.configDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(apps).write(to: Self.configURL, options: .atomic)
        } catch {
            NSLog("Xuanyu quick launch save failed: \(error)")
        }
    }

    private static var configDirectory: URL {
        AppSupportDirectory.root
    }

    private static var configURL: URL {
        configDirectory.appendingPathComponent("quick-launch.json")
    }

    private static func loadSavedApps() -> [QuickLaunchApp]? {
        guard let data = try? Data(contentsOf: configURL),
              let apps = try? JSONDecoder().decode([QuickLaunchApp].self, from: data)
        else {
            return nil
        }
        return apps
    }

    private static func defaultApps() -> [QuickLaunchApp] {
        [
            "com.apple.finder",
            "com.apple.Safari",
            "com.google.Chrome",
            "com.apple.Music",
            "com.apple.Terminal",
            "com.tencent.xinWeChat",
        ].compactMap { bundleIdentifier in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
            return app(from: url)
        }
    }

    private static func app(from url: URL) -> QuickLaunchApp? {
        let standardizedURL = url.standardizedFileURL
        guard standardizedURL.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: standardizedURL),
              let bundleIdentifier = bundle.bundleIdentifier
        else {
            return nil
        }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? standardizedURL.deletingPathExtension().lastPathComponent
        return QuickLaunchApp(bundleIdentifier: bundleIdentifier, name: name, path: standardizedURL.path)
    }
}
