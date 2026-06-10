import Foundation

final class IslandLyricsService {
    func fetchLyrics(
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval,
        bundleIdentifier: String?
    ) async -> IslandLyricsResult {
        var nativeLyrics = IslandLyricsResult()
        if bundleIdentifier == "com.apple.Music" {
            nativeLyrics = await fetchAppleMusicLyrics()
        }

        let lrclibLyrics = await fetchFromLRCLIB(title: title, artist: artist, album: album, duration: duration)
        if !lrclibLyrics.syncedLines.isEmpty { return lrclibLyrics }
        if !nativeLyrics.isEmpty { return nativeLyrics }
        return lrclibLyrics
    }

    private func fetchAppleMusicLyrics() async -> IslandLyricsResult {
        let script = """
        tell application "Music"
            if it is running then
                try
                    set trackLyrics to lyrics of current track
                    if trackLyrics is missing value then
                        return ""
                    else
                        return trackLyrics
                    end if
                on error
                    return ""
                end try
            else
                return ""
            end if
        end tell
        """

        guard let descriptor = try? await IslandAppleScript.execute(script),
              let lyrics = descriptor.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !lyrics.isEmpty
        else {
            return IslandLyricsResult()
        }

        return IslandLyricsResult(plainText: Self.cleanLyricText(lyrics), syncedLines: [])
    }

    private func fetchFromLRCLIB(title: String, artist: String, album: String, duration: TimeInterval) async -> IslandLyricsResult {
        let normalizedTitle = Self.normalizedQuery(title)
        let normalizedArtist = Self.normalizedQuery(artist)
        let normalizedAlbum = Self.normalizedQuery(album)
        guard !normalizedTitle.isEmpty else { return IslandLyricsResult() }

        if !normalizedArtist.isEmpty, !normalizedAlbum.isEmpty, duration > 0 {
            for titleVariant in Self.titleQueryVariants(title).prefix(2) {
                for artistVariant in Self.artistQueryVariants(artist).prefix(2) {
                    guard let data = await fetchLRCLIB(
                        path: "/api/get-cached",
                        queryItems: [
                            URLQueryItem(name: "track_name", value: titleVariant),
                            URLQueryItem(name: "artist_name", value: artistVariant),
                            URLQueryItem(name: "album_name", value: normalizedAlbum),
                            URLQueryItem(name: "duration", value: String(Int(duration.rounded())))
                        ]
                    ) else { continue }

                    let result = Self.parseLRCLIBTrack(data: data)
                    if !result.isEmpty { return result }
                }
            }
        }

        for queryItems in Self.searchQueries(title: title, artist: artist) {
            guard let data = await fetchLRCLIB(path: "/api/search", queryItems: queryItems) else { continue }
            let result = Self.parseLRCLIBSearch(
                data: data,
                title: title,
                artist: artist,
                album: album,
                duration: duration
            )
            if !result.isEmpty { return result }
        }

        return IslandLyricsResult()
    }

    private func fetchLRCLIB(path: String, queryItems: [URLQueryItem]) async -> Data? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "lrclib.net"
        components.path = path
        components.queryItems = queryItems.filter { !($0.value ?? "").isEmpty }

        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Xuanyu/1.0 (macOS)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return data
        } catch {
            return nil
        }
    }

    static func parseLRCLIBSearch(data: Data) -> IslandLyricsResult {
        parseLRCLIBSearch(data: data, title: "", artist: "", album: "", duration: 0)
    }

    static func parseLRCLIBSearch(
        data: Data,
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval
    ) -> IslandLyricsResult {
        guard let tracks = try? JSONDecoder().decode([LRCLIBTrack].self, from: data) else {
            return IslandLyricsResult()
        }

        return tracks
            .map { track in
                (track: track, score: score(track: track, title: title, artist: artist, album: album, duration: duration))
            }
            .filter { !$0.track.lyricsResult.isEmpty }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return !lhs.track.syncedLyricsText.isEmpty && rhs.track.syncedLyricsText.isEmpty
                }
                return lhs.score > rhs.score
            }
            .first?
            .track
            .lyricsResult ?? IslandLyricsResult()
    }

    static func parseLRCLIBTrack(data: Data) -> IslandLyricsResult {
        guard let track = try? JSONDecoder().decode(LRCLIBTrack.self, from: data) else {
            return IslandLyricsResult()
        }
        return track.lyricsResult
    }

    static func parseLRC(_ lrc: String) -> [IslandLyricLine] {
        guard !lrc.isEmpty else { return [] }
        let pattern = #"\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        // Optional global shift declared by the file: [offset:+/-ms].
        // Positive values mean the lyrics should appear earlier.
        let offsetSeconds = parseLRCOffset(lrc)

        var result: [IslandLyricLine] = []
        for rawLine in lrc.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let nsLine = line as NSString
            let range = NSRange(location: 0, length: nsLine.length)
            let matches = regex.matches(in: line, range: range)
            guard !matches.isEmpty else { continue }

            let textStart = matches.last!.range.location + matches.last!.range.length
            let text = cleanLyricText(
                nsLine.substring(from: textStart).trimmingCharacters(in: .whitespaces)
            )
            guard !text.isEmpty else { continue }

            for match in matches {
                let minutes = Double(nsLine.substring(with: match.range(at: 1))) ?? 0
                let seconds = Double(nsLine.substring(with: match.range(at: 2))) ?? 0
                let fractionRange = match.range(at: 3)
                let fraction: Double
                if fractionRange.location == NSNotFound {
                    fraction = 0
                } else {
                    let fractionText = nsLine.substring(with: fractionRange)
                    let divisor = pow(10.0, Double(fractionText.count))
                    fraction = (Double(fractionText) ?? 0) / divisor
                }

                let time = max(0, minutes * 60 + seconds + fraction - offsetSeconds)
                result.append(IslandLyricLine(time: time, text: text))
            }
        }

        return result.sorted { $0.time < $1.time }
    }

    private static func parseLRCOffset(_ lrc: String) -> TimeInterval {
        let pattern = #"\[offset:\s*([+-]?\d+)\s*\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return 0
        }
        let nsLrc = lrc as NSString
        let range = NSRange(location: 0, length: nsLrc.length)
        guard let match = regex.firstMatch(in: lrc, range: range),
              let milliseconds = Double(nsLrc.substring(with: match.range(at: 1)))
        else {
            return 0
        }
        return milliseconds / 1000
    }

    static func lyricLine(at elapsed: TimeInterval, result: IslandLyricsResult) -> String {
        if result.syncedLines.isEmpty {
            return result.plainText.replacingOccurrences(of: "\n", with: " ")
        }

        var low = 0
        var high = result.syncedLines.count - 1
        var bestIndex = 0

        while low <= high {
            let mid = (low + high) / 2
            if result.syncedLines[mid].time <= elapsed {
                bestIndex = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        return result.syncedLines[bestIndex].text
    }

    static func debugLRCLIBSearchQueries(title: String, artist: String) -> [[URLQueryItem]] {
        searchQueries(title: title, artist: artist)
    }

    static func debugTitleQueryVariants(_ title: String) -> [String] {
        titleQueryVariants(title)
    }

    static func debugArtistQueryVariants(_ artist: String) -> [String] {
        artistQueryVariants(artist)
    }

    private static func searchQueries(title: String, artist: String) -> [[URLQueryItem]] {
        let titles = titleQueryVariants(title)
        let artists = artistQueryVariants(artist)
        var queries: [[URLQueryItem]] = []

        for titleVariant in titles.prefix(3) {
            for artistVariant in artists.prefix(2) {
                queries.append([
                    URLQueryItem(name: "track_name", value: titleVariant),
                    URLQueryItem(name: "artist_name", value: artistVariant)
                ])
            }
        }

        for titleVariant in titles.prefix(3) {
            queries.append([URLQueryItem(name: "q", value: "\(titleVariant) \(artists.first ?? "")")])
            queries.append([URLQueryItem(name: "track_name", value: titleVariant)])
        }

        var seen = Set<String>()
        return queries.filter { items in
            let key = items.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&")
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    private static func titleQueryVariants(_ title: String) -> [String] {
        let normalized = normalizedQuery(title)
        let withoutNoise = removeVersionNoise(from: normalized)
        let withoutDashSuffix = removeDashVersionSuffix(from: normalized)

        return uniqueNonEmpty([
            normalized,
            withoutNoise,
            withoutDashSuffix,
            removeVersionNoise(from: withoutDashSuffix)
        ])
    }

    private static func artistQueryVariants(_ artist: String) -> [String] {
        let normalized = normalizedQuery(artist)
        let primary = normalized
            .components(separatedBy: CharacterSet(charactersIn: ",，、/&;"))
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return uniqueNonEmpty([normalized, primary])
    }

    private static func score(
        track: LRCLIBTrack,
        title: String,
        artist: String,
        album: String,
        duration: TimeInterval
    ) -> Int {
        var score = 0

        if !track.syncedLyricsText.isEmpty { score += 120 }
        if !track.plainLyricsText.isEmpty { score += 60 }
        if track.instrumental == true { score -= 80 }

        let wantedTitles = titleQueryVariants(title).map(canonicalMatchText)
        let trackTitle = canonicalMatchText(track.trackName ?? "")
        if wantedTitles.contains(trackTitle) {
            score += 90
        } else if wantedTitles.contains(where: { !$0.isEmpty && (trackTitle.contains($0) || $0.contains(trackTitle)) }) {
            score += 45
        }

        let wantedArtists = artistQueryVariants(artist).map(canonicalMatchText)
        let trackArtist = canonicalMatchText(track.artistName ?? "")
        if wantedArtists.contains(trackArtist) {
            score += 70
        } else if wantedArtists.contains(where: { !$0.isEmpty && (trackArtist.contains($0) || $0.contains(trackArtist)) }) {
            score += 35
        }

        let wantedAlbum = canonicalMatchText(album)
        let trackAlbum = canonicalMatchText(track.albumName ?? "")
        if !wantedAlbum.isEmpty, wantedAlbum == trackAlbum {
            score += 25
        }

        if duration > 0, let trackDuration = track.duration {
            let delta = abs(Double(trackDuration) - duration)
            switch delta {
            case 0...2:
                score += 65
            case 2...8:
                score += 35
            case 8...20:
                score += 10
            default:
                score -= 35
            }
        }

        return score
    }

    private static func normalizedQuery(_ string: String) -> String {
        string
            .folding(options: .diacriticInsensitive, locale: .current)
            .replacingOccurrences(of: "\u{FFFD}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removeVersionNoise(from title: String) -> String {
        let pattern = #"\s*[\(\[\{（【].*?(feat\.?|ft\.?|featuring|with|remaster(?:ed)?|live|acoustic|demo|edit|version|mix|remix|sped|slowed|nightcore|karaoke|instrumental|explicit|mono|stereo).*?[\)\]\}）】]"#
        return title
            .replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removeDashVersionSuffix(from title: String) -> String {
        let pattern = #"\s+[-–—]\s+.*?(feat\.?|ft\.?|featuring|with|remaster(?:ed)?|live|acoustic|demo|edit|version|mix|remix|sped|slowed|nightcore|karaoke|instrumental|explicit|mono|stereo).*$"#
        return title
            .replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func canonicalMatchText(_ text: String) -> String {
        removeVersionNoise(from: normalizedQuery(text))
            .lowercased()
            .replacingOccurrences(of: #"['’`´]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func uniqueNonEmpty(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let normalized = normalizedQuery(value)
            guard !normalized.isEmpty, !seen.contains(normalized.lowercased()) else { return nil }
            seen.insert(normalized.lowercased())
            return normalized
        }
    }

    private static func cleanLyricText(_ text: String) -> String {
        let stripped = text
            .replacingOccurrences(
                of: #"<\d{1,2}:\d{2}(?:\.\d{1,3})?>"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return simplifiedChinese(stripped)
    }

    /// LRCLIB community lyrics for many Mandarin songs are uploaded in
    /// Traditional Chinese. Normalize to Simplified for display. The transform
    /// is idempotent for text that is already Simplified (or non-Chinese), so it
    /// is safe to apply unconditionally.
    static func simplifiedChinese(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let mutable = NSMutableString(string: text) as CFMutableString
        var range = CFRangeMake(0, CFStringGetLength(mutable))
        if CFStringTransform(mutable, &range, "Traditional-Simplified" as CFString, false) {
            return mutable as String
        }
        return text
    }

    struct LRCLIBTrack: Decodable {
        var trackName: String?
        var artistName: String?
        var albumName: String?
        var duration: TimeInterval?
        var instrumental: Bool?
        var plainLyrics: String?
        var syncedLyrics: String?

        var plainLyricsText: String {
            cleanLyricText(plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        }

        var syncedLyricsText: String {
            syncedLyrics?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        var lyricsResult: IslandLyricsResult {
            IslandLyricsResult(
                plainText: plainLyricsText.isEmpty ? syncedLyricsText : plainLyricsText,
                syncedLines: parseLRC(syncedLyricsText)
            )
        }
    }
}
