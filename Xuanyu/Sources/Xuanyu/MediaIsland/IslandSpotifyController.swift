import AppKit
import Foundation

@MainActor
final class IslandSpotifyController: IslandMediaController {
    let supportsFavorite = false
    private var lastArtworkURL: String?
    private var cachedArtwork: Data?

    func isActive() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.spotify.client" }
    }

    func updatePlaybackInfo() async -> IslandPlaybackState? {
        guard isActive() else {
            return IslandPlaybackState(
                bundleIdentifier: "com.spotify.client",
                title: "未播放",
                artist: "打开 Spotify"
            )
        }

        // `parsePlaybackDescriptor` anchors `lastUpdated` at the script's return
        // instant (the script reads `player position` last), so the clock stays
        // aligned with the audio. The artwork network fetch below happens after
        // and is accounted for by the wall-clock extrapolation.
        let descriptor: NSAppleEventDescriptor?
        do {
            descriptor = try await fetchPlaybackInfo()
        } catch {
            NSLog("Xuanyu Spotify AppleScript failed: \(error)")
            return IslandPlaybackState(
                bundleIdentifier: "com.spotify.client",
                title: "需要授权",
                artist: "允许悬屿控制 Spotify"
            )
        }

        guard let descriptor,
              var parsed = Self.parsePlaybackDescriptor(descriptor)?.state
        else {
            return nil
        }

        let artworkURL = Self.parsePlaybackDescriptor(descriptor)?.artworkURL
        if artworkURL == lastArtworkURL {
            parsed.artwork = cachedArtwork
            return parsed
        }

        guard let artworkURL,
              let url = URL(string: artworkURL),
              let (data, _) = try? await URLSession.shared.data(from: url)
        else {
            return parsed
        }

        lastArtworkURL = artworkURL
        cachedArtwork = data
        parsed.artwork = data
        return parsed
    }

    func togglePlay() async {
        await executeCommand("playpause")
    }

    func nextTrack() async {
        await executeCommand("next track")
    }

    func previousTrack() async {
        await executeCommand("previous track")
    }

    func seek(to time: TimeInterval) async {
        await executeCommand("set player position to \(time)")
    }

    func toggleShuffle() async {
        await executeCommand("set shuffling to not shuffling")
    }

    func toggleRepeat() async {
        await executeCommand("set repeating to not repeating")
    }

    func setFavorite(_ favorite: Bool) async {}

    private func executeCommand(_ command: String) async {
        guard isActive() else { return }
        try? await IslandAppleScript.executeVoid("tell application \"Spotify\" to \(command)")
    }

    private func fetchPlaybackInfo() async throws -> NSAppleEventDescriptor? {
        let script = """
        tell application "Spotify"
            try
                set playerState to player state is playing
                set currentTrackName to name of current track
                set currentTrackArtist to artist of current track
                set currentTrackAlbum to album of current track
                set trackDuration to duration of current track
                set shuffleState to shuffling
                set repeatState to repeating
                set currentVolume to sound volume
                set artworkURL to artwork url of current track
                set trackPosition to player position
                return {playerState, currentTrackName, currentTrackArtist, currentTrackAlbum, trackPosition, trackDuration, shuffleState, repeatState, currentVolume, artworkURL}
            on error
                return {false, "未播放", "打开 Spotify", "", 0, 0, false, false, 50, ""}
            end try
        end tell
        """
        return try await IslandAppleScript.execute(script)
    }

    nonisolated static func parsePlaybackDescriptor(_ descriptor: NSAppleEventDescriptor) -> (state: IslandPlaybackState, artworkURL: String?)? {
        guard descriptor.numberOfItems >= 10 else { return nil }

        let durationMilliseconds = descriptor.atIndex(6)?.doubleValue ?? 0
        let state = IslandPlaybackState(
            bundleIdentifier: "com.spotify.client",
            isPlaying: descriptor.atIndex(1)?.booleanValue ?? false,
            title: descriptor.atIndex(2)?.stringValue ?? "未播放",
            artist: descriptor.atIndex(3)?.stringValue ?? "未知艺人",
            album: descriptor.atIndex(4)?.stringValue ?? "",
            currentTime: descriptor.atIndex(5)?.doubleValue ?? 0,
            duration: durationMilliseconds / 1000,
            playbackRate: 1,
            isShuffled: descriptor.atIndex(7)?.booleanValue ?? false,
            repeatMode: (descriptor.atIndex(8)?.booleanValue ?? false) ? .all : .off,
            lastUpdated: Date(),
            volume: Double(descriptor.atIndex(9)?.int32Value ?? 50) / 100.0,
            isFavorite: false,
            supportsFavorite: false
        )

        return (state, descriptor.atIndex(10)?.stringValue)
    }
}
