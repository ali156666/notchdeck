import AppKit
import Foundation

@MainActor
final class IslandAppleMusicController: IslandMediaController {
    let supportsFavorite = true

    private var cachedArtwork: Data?
    private var cachedArtworkKey: String?

    func isActive() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.Music" }
    }

    func updatePlaybackInfo() async -> IslandPlaybackState? {
        guard isActive() else {
            return IslandPlaybackState(
                bundleIdentifier: "com.apple.Music",
                title: "未播放",
                artist: "打开 Apple Music",
                supportsFavorite: true
            )
        }

        // The playback script is intentionally lean (no artwork blob) and reads
        // `player position` as its very last statement, so the value returned is
        // sampled right before the script returns. `parsePlaybackDescriptor`
        // therefore anchors `lastUpdated` at the return instant, keeping the
        // lyric clock aligned with the audio without the artwork-serialization lag.
        let descriptor: NSAppleEventDescriptor?
        do {
            descriptor = try await fetchPlaybackInfo()
        } catch {
            NSLog("Xuanyu Music AppleScript failed: \(error)")
            return IslandPlaybackState(
                bundleIdentifier: "com.apple.Music",
                title: "需要授权",
                artist: "允许悬屿控制 Apple Music",
                supportsFavorite: true
            )
        }

        guard let descriptor,
              var state = Self.parsePlaybackDescriptor(descriptor)
        else {
            return nil
        }

        // Artwork only changes when the track changes, and serializing it over
        // AppleScript is slow — fetch it lazily and cache it so it never sits on
        // the position-sampling path.
        let key = "\(state.title)|\(state.artist)|\(state.album)"
        if key == cachedArtworkKey {
            state.artwork = cachedArtwork
        } else if state.hasPlayableTrack {
            let artwork = await fetchArtworkData(for: state)
            cachedArtworkKey = key
            cachedArtwork = artwork
            state.artwork = artwork
        }

        return state
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
        await executeCommand("set shuffle enabled to not shuffle enabled")
    }

    func toggleRepeat() async {
        await executeCommand("""
        if song repeat is off then
            set song repeat to all
        else if song repeat is all then
            set song repeat to one
        else
            set song repeat to off
        end if
        """)
    }

    func setFavorite(_ favorite: Bool) async {
        let value = favorite ? "true" : "false"
        let script = """
        tell application "Music"
            if it is running then
                try
                    set favorited of current track to \(value)
                end try
            end if
        end tell
        """
        try? await IslandAppleScript.executeVoid(script)
    }

    private func executeCommand(_ command: String) async {
        guard isActive() else { return }
        try? await IslandAppleScript.executeVoid("tell application \"Music\" to \(command)")
    }

    private func fetchPlaybackInfo() async throws -> NSAppleEventDescriptor? {
        let script = """
        tell application "Music"
            try
                set playerState to player state is playing
                set currentTrackName to name of current track
                set currentTrackArtist to artist of current track
                set currentTrackAlbum to album of current track
                set trackDuration to duration of current track
                set shuffleState to shuffle enabled
                set repeatState to song repeat
                if repeatState is off then
                    set repeatValue to 1
                else if repeatState is one then
                    set repeatValue to 2
                else if repeatState is all then
                    set repeatValue to 3
                end if

                try
                    set favoriteState to favorited of current track
                on error
                    set favoriteState to false
                end try

                set trackPosition to player position
                return {playerState, currentTrackName, currentTrackArtist, currentTrackAlbum, trackPosition, trackDuration, shuffleState, repeatValue, sound volume, favoriteState}
            on error
                return {false, "未播放", "打开 Apple Music", "", 0, 0, false, 1, 50, false}
            end try
        end tell
        """
        return try await IslandAppleScript.execute(script)
    }

    private func fetchArtworkData(for state: IslandPlaybackState) async -> Data? {
        if let artwork = await fetchAppleScriptArtworkData() {
            return artwork
        }
        return await fetchCatalogArtworkData(for: state)
    }

    private func fetchAppleScriptArtworkData() async -> Data? {
        let script = """
        tell application "Music"
            try
                return {data of artwork 1 of current track}
            on error
                return {""}
            end try
        end tell
        """
        guard let descriptor = try? await IslandAppleScript.execute(script),
              let data = descriptor.atIndex(1)?.data,
              !data.isEmpty
        else {
            return nil
        }
        return data
    }

    private func fetchCatalogArtworkData(for state: IslandPlaybackState) async -> Data? {
        let query = [state.title, state.artist, state.album]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " ")
        guard !query.isEmpty,
              var components = URLComponents(string: "https://itunes.apple.com/search")
        else {
            return nil
        }

        components.queryItems = [
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "5"),
            URLQueryItem(name: "country", value: "cn"),
        ]

        guard let url = components.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder().decode(ITunesSearchResponse.self, from: data),
              let artworkURL = bestArtworkURL(from: response.results, matching: state),
              let (artworkData, _) = try? await URLSession.shared.data(from: artworkURL),
              !artworkData.isEmpty
        else {
            return nil
        }
        return artworkData
    }

    private func bestArtworkURL(from results: [ITunesSearchResult], matching state: IslandPlaybackState) -> URL? {
        let normalizedTitle = Self.normalizedSearchText(state.title)
        let normalizedArtist = Self.normalizedSearchText(state.artist)

        let ranked = results.sorted { lhs, rhs in
            score(lhs, title: normalizedTitle, artist: normalizedArtist) > score(rhs, title: normalizedTitle, artist: normalizedArtist)
        }
        guard let match = ranked.first,
              score(match, title: normalizedTitle, artist: normalizedArtist) > 0,
              let urlString = match.artworkUrl100
        else {
            return nil
        }

        let largerURLString = urlString
            .replacingOccurrences(of: "100x100bb", with: "600x600bb")
            .replacingOccurrences(of: "100x100", with: "600x600")
        return URL(string: largerURLString)
    }

    private func score(_ result: ITunesSearchResult, title: String, artist: String) -> Int {
        let resultTitle = Self.normalizedSearchText(result.trackName ?? "")
        let resultArtist = Self.normalizedSearchText(result.artistName ?? "")
        var value = 0
        if !title.isEmpty && resultTitle == title { value += 4 }
        if !title.isEmpty && (resultTitle.contains(title) || title.contains(resultTitle)) { value += 2 }
        if !artist.isEmpty && resultArtist == artist { value += 3 }
        if !artist.isEmpty && (resultArtist.contains(artist) || artist.contains(resultArtist)) { value += 1 }
        return value
    }

    nonisolated static func parsePlaybackDescriptor(_ descriptor: NSAppleEventDescriptor) -> IslandPlaybackState? {
        guard descriptor.numberOfItems >= 10 else { return nil }

        var state = IslandPlaybackState(
            bundleIdentifier: "com.apple.Music",
            supportsFavorite: true
        )
        state.isPlaying = descriptor.atIndex(1)?.booleanValue ?? false
        state.title = descriptor.atIndex(2)?.stringValue ?? "未播放"
        state.artist = descriptor.atIndex(3)?.stringValue ?? "未知艺人"
        state.album = descriptor.atIndex(4)?.stringValue ?? ""
        state.currentTime = descriptor.atIndex(5)?.doubleValue ?? 0
        state.duration = descriptor.atIndex(6)?.doubleValue ?? 0
        state.isShuffled = descriptor.atIndex(7)?.booleanValue ?? false
        state.repeatMode = IslandRepeatMode(rawValue: Int(descriptor.atIndex(8)?.int32Value ?? 1)) ?? .off
        state.volume = Double(descriptor.atIndex(9)?.int32Value ?? 50) / 100.0
        state.isFavorite = descriptor.atIndex(10)?.booleanValue ?? false
        state.lastUpdated = Date()
        return state
    }

    private static func normalizedSearchText(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "zh-Hans"))
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
    }
}

private struct ITunesSearchResponse: Decodable {
    let results: [ITunesSearchResult]
}

private struct ITunesSearchResult: Decodable {
    let trackName: String?
    let artistName: String?
    let artworkUrl100: String?
}
