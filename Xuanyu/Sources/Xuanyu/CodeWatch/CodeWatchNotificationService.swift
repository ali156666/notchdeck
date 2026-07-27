import AppKit
import Foundation
@preconcurrency import UserNotifications

enum CodeWatchNotificationAuthorization: String, Sendable {
    case unknown
    case notDetermined
    case denied
    case authorized

    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined:
            self = .notDetermined
        case .denied:
            self = .denied
        case .authorized, .provisional, .ephemeral:
            self = .authorized
        @unknown default:
            self = .unknown
        }
    }
}

final class CodeWatchNotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CodeWatchNotificationService()

    private var didStart = false

    private override init() {
        super.init()
    }

    func start(statusHandler: @escaping (CodeWatchNotificationAuthorization) -> Void) {
        guard Bundle.main.bundleIdentifier == "com.xuanyu.app" else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.getNotificationSettings { [weak self] settings in
            let status = CodeWatchNotificationAuthorization(settings.authorizationStatus)
            statusHandler(status)
            guard status == .notDetermined, self?.didStart == false else { return }
            self?.didStart = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in
                center.getNotificationSettings { updatedSettings in
                    statusHandler(CodeWatchNotificationAuthorization(updatedSettings.authorizationStatus))
                }
            }
        }
    }

    func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func send(_ completion: CodeWatchCompletion) {
        guard Bundle.main.bundleIdentifier == "com.xuanyu.app" else { return }
        let content = UNMutableNotificationContent()
        content.title = completion.title
        let message = completion.message?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if let message, !message.isEmpty {
            content.body = "\(completion.projectName) · \(String(message.prefix(120)))"
        } else {
            content.body = completion.projectName
        }
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "codewatch.\(completion.sessionId).\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
