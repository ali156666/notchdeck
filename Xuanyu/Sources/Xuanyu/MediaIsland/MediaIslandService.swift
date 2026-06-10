import AppKit
import Foundation

@MainActor
@Observable
final class MediaIslandService {
    var playback = IslandPlaybackState()
    var lyrics = IslandLyricsResult()
    var isFetchingLyrics = false
    var airPods = IslandAirPodsStatus()

    @ObservationIgnored private let appleMusic = IslandAppleMusicController()
    @ObservationIgnored private let spotify = IslandSpotifyController()
    @ObservationIgnored private let lyricsService = IslandLyricsService()
    @ObservationIgnored private let airPodsProbe = IslandAirPodsProbe()
    @ObservationIgnored private var mediaObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var refreshTimer: Timer?
    @ObservationIgnored private var airPodsTimer: Timer?
    @ObservationIgnored private var lyricsTask: Task<Void, Never>?
    @ObservationIgnored private var airPodsTask: Task<IslandAirPodsStatus?, Never>?
    @ObservationIgnored private var lastLyricsKey = ""

    func start() {
        guard mediaObservers.isEmpty else { return }

        mediaObservers = [
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.apple.Music.playerInfo"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.refreshPlayback() }
            },
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.spotify.client.PlaybackStateChanged"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.refreshPlayback() }
            }
        ]

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshPlayback() }
        }

        airPodsTimer = Timer.scheduledTimer(withTimeInterval: 25, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshAirPods() }
        }

        Task { @MainActor in await refreshAirPods() }
        Task { @MainActor in await refreshPlayback() }
    }

    func stop() {
        mediaObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        mediaObservers.removeAll()
        refreshTimer?.invalidate()
        airPodsTimer?.invalidate()
        refreshTimer = nil
        airPodsTimer = nil
        lyricsTask?.cancel()
        airPodsTask?.cancel()
    }

    func refreshPlayback() async {
        let appleState = await appleMusic.updatePlaybackInfo()
        let spotifyState = await spotify.updatePlaybackInfo()
        let next = preferredPlaybackState(apple: appleState, spotify: spotifyState)

        guard let next else { return }
        playback = next
        updateLyricsIfNeeded(for: next)
    }

    func refreshAirPods() async {
        airPodsTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return nil as IslandAirPodsStatus? }
            let status = await self.airPodsProbe.probe()
            guard !Task.isCancelled else { return nil }
            return status
        }
        airPodsTask = task

        guard let status = await task.value, !Task.isCancelled else { return }
        airPods = status

        if status.isConnected {
            NSLog("Xuanyu AirPods probe: name=\(status.name) left=\(status.leftBattery.map(String.init) ?? "--") right=\(status.rightBattery.map(String.init) ?? "--") case=\(status.caseBattery.map(String.init) ?? "--") source=\(status.batteryEvidenceSource ?? "none") evidence=\(status.probeEvidence.joined(separator: " | "))")
        } else {
            NSLog("Xuanyu AirPods probe: disconnected evidence=\(status.probeEvidence.joined(separator: " | "))")
        }
    }

    func displayedElapsedTime(at date: Date = Date()) -> TimeInterval {
        guard playback.isPlaying else { return playback.currentTime }
        let delta = date.timeIntervalSince(playback.lastUpdated)
        return min(max(playback.currentTime + delta * playback.playbackRate, 0), max(playback.duration, 0))
    }

    func currentLyricLine(at date: Date = Date()) -> String {
        if isFetchingLyrics { return "歌词加载中" }
        let line = IslandLyricsService.lyricLine(at: displayedElapsedTime(at: date), result: lyrics)
        return line.isEmpty ? "暂无歌词" : line
    }

    func togglePlay() async {
        await activeController().togglePlay()
        try? await Task.sleep(for: .milliseconds(120))
        await refreshPlayback()
    }

    func nextTrack() async {
        await activeController().nextTrack()
        try? await Task.sleep(for: .milliseconds(160))
        await refreshPlayback()
    }

    func previousTrack() async {
        await activeController().previousTrack()
        try? await Task.sleep(for: .milliseconds(160))
        await refreshPlayback()
    }

    func seek(to time: TimeInterval) async {
        await activeController().seek(to: time)
        try? await Task.sleep(for: .milliseconds(120))
        await refreshPlayback()
    }

    func toggleShuffle() async {
        await activeController().toggleShuffle()
        try? await Task.sleep(for: .milliseconds(120))
        await refreshPlayback()
    }

    func toggleRepeat() async {
        await activeController().toggleRepeat()
        try? await Task.sleep(for: .milliseconds(120))
        await refreshPlayback()
    }

    func toggleFavorite() async {
        guard playback.supportsFavorite else { return }
        await activeController().setFavorite(!playback.isFavorite)
        try? await Task.sleep(for: .milliseconds(120))
        await refreshPlayback()
    }

    private func preferredPlaybackState(apple: IslandPlaybackState?, spotify: IslandPlaybackState?) -> IslandPlaybackState? {
        if let apple, apple.isPlaying { return apple }
        if let spotify, spotify.isPlaying { return spotify }
        if let current = [apple, spotify].compactMap({ $0 }).first(where: { $0.bundleIdentifier == playback.bundleIdentifier && $0.hasPlayableTrack }) {
            return current
        }
        if let spotify, spotify.hasPlayableTrack { return spotify }
        if let apple, apple.hasPlayableTrack { return apple }
        return apple ?? spotify
    }

    private func updateLyricsIfNeeded(for state: IslandPlaybackState) {
        let key = "\(state.bundleIdentifier)|\(state.title)|\(state.artist)|\(state.album)|\(Int(state.duration.rounded()))"
        guard key != lastLyricsKey, state.hasPlayableTrack else { return }

        lastLyricsKey = key
        lyricsTask?.cancel()
        isFetchingLyrics = true
        lyrics = IslandLyricsResult()
        NSLog("Xuanyu lyrics fetch: title=\(state.title) artist=\(state.artist) album=\(state.album) duration=\(Int(state.duration.rounded())) source=\(state.bundleIdentifier)")

        lyricsTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.lyricsService.fetchLyrics(
                title: state.title,
                artist: state.artist,
                album: state.album,
                duration: state.duration,
                bundleIdentifier: state.bundleIdentifier
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.lyrics = result
                self.isFetchingLyrics = false
                NSLog("Xuanyu lyrics result: title=\(state.title) artist=\(state.artist) plainChars=\(result.plainText.count) syncedLines=\(result.syncedLines.count)")
            }
        }
    }

    private func activeController() -> IslandMediaController {
        if playback.bundleIdentifier == "com.spotify.client" {
            return spotify
        }
        if playback.bundleIdentifier == "com.apple.Music" {
            return appleMusic
        }
        if spotify.isActive() {
            return spotify
        }
        return appleMusic
    }
}
