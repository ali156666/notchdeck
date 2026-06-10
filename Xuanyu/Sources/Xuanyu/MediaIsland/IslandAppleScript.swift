import AppKit
import Foundation

enum IslandAppleScript {
    static func execute(_ source: String) async throws -> NSAppleEventDescriptor? {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                guard let script = NSAppleScript(source: source) else {
                    continuation.resume(returning: nil)
                    return
                }
                let descriptor = script.executeAndReturnError(&error)
                if let error {
                    continuation.resume(throwing: NSError(
                        domain: "IslandAppleScript",
                        code: 1,
                        userInfo: error as? [String: Any]
                    ))
                } else {
                    continuation.resume(returning: descriptor)
                }
            }
        }
    }

    static func executeVoid(_ source: String) async throws {
        _ = try await execute(source)
    }
}

@MainActor
protocol IslandMediaController: AnyObject {
    var supportsFavorite: Bool { get }
    func isActive() -> Bool
    func updatePlaybackInfo() async -> IslandPlaybackState?
    func togglePlay() async
    func nextTrack() async
    func previousTrack() async
    func seek(to time: TimeInterval) async
    func toggleShuffle() async
    func toggleRepeat() async
    func setFavorite(_ favorite: Bool) async
}
