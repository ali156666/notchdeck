import Foundation

enum IslandRepeatMode: Int, Codable, Equatable {
    case off = 1
    case one = 2
    case all = 3
}

struct IslandPlaybackState: Equatable {
    var bundleIdentifier: String
    var isPlaying: Bool
    var title: String
    var artist: String
    var album: String
    var currentTime: TimeInterval
    var duration: TimeInterval
    var playbackRate: Double
    var isShuffled: Bool
    var repeatMode: IslandRepeatMode
    var lastUpdated: Date
    var artwork: Data?
    var volume: Double
    var isFavorite: Bool
    var supportsFavorite: Bool

    init(
        bundleIdentifier: String = "",
        isPlaying: Bool = false,
        title: String = "未播放",
        artist: String = "打开 Apple Music 或 Spotify",
        album: String = "",
        currentTime: TimeInterval = 0,
        duration: TimeInterval = 0,
        playbackRate: Double = 1,
        isShuffled: Bool = false,
        repeatMode: IslandRepeatMode = .off,
        lastUpdated: Date = Date.distantPast,
        artwork: Data? = nil,
        volume: Double = 0.5,
        isFavorite: Bool = false,
        supportsFavorite: Bool = false
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.isPlaying = isPlaying
        self.title = title
        self.artist = artist
        self.album = album
        self.currentTime = currentTime
        self.duration = duration
        self.playbackRate = playbackRate
        self.isShuffled = isShuffled
        self.repeatMode = repeatMode
        self.lastUpdated = lastUpdated
        self.artwork = artwork
        self.volume = volume
        self.isFavorite = isFavorite
        self.supportsFavorite = supportsFavorite
    }

    var hasPlayableTrack: Bool {
        title != "未播放" && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct IslandLyricLine: Equatable {
    let time: TimeInterval
    let text: String
}

struct IslandLyricsResult: Equatable {
    var plainText: String
    var syncedLines: [IslandLyricLine]

    init(plainText: String = "", syncedLines: [IslandLyricLine] = []) {
        self.plainText = plainText
        self.syncedLines = syncedLines
    }

    var isEmpty: Bool {
        plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && syncedLines.isEmpty
    }
}

struct IslandAirPodsStatus: Codable, Equatable {
    var name: String
    var address: String
    var isConnected: Bool
    var isAudioRouteActive: Bool
    var leftBattery: Int?
    var rightBattery: Int?
    var caseBattery: Int?
    var batteryEvidenceSource: String?
    var probeEvidence: [String]
    var lastUpdated: Date

    init(
        name: String = "AirPods",
        address: String = "",
        isConnected: Bool = false,
        isAudioRouteActive: Bool = false,
        leftBattery: Int? = nil,
        rightBattery: Int? = nil,
        caseBattery: Int? = nil,
        batteryEvidenceSource: String? = nil,
        probeEvidence: [String] = [],
        lastUpdated: Date = Date()
    ) {
        self.name = name
        self.address = address
        self.isConnected = isConnected
        self.isAudioRouteActive = isAudioRouteActive
        self.leftBattery = leftBattery
        self.rightBattery = rightBattery
        self.caseBattery = caseBattery
        self.batteryEvidenceSource = batteryEvidenceSource
        self.probeEvidence = probeEvidence
        self.lastUpdated = lastUpdated
    }

    var hasCompleteBattery: Bool {
        leftBattery != nil && rightBattery != nil && caseBattery != nil
    }
}

struct IslandAirPodsBattery: Codable, Equatable {
    var left: Int?
    var right: Int?
    var `case`: Int?
    var source: String?

    init(left: Int? = nil, right: Int? = nil, `case`: Int? = nil, source: String? = nil) {
        self.left = left
        self.right = right
        self.case = `case`
        self.source = source
    }

    var isComplete: Bool {
        left != nil && right != nil && self.case != nil
    }

    var hasAnyValue: Bool {
        left != nil || right != nil || self.case != nil
    }

    func merged(with other: IslandAirPodsBattery) -> IslandAirPodsBattery {
        let mergedLeft = left ?? other.left
        let mergedRight = right ?? other.right
        let mergedCase = self.case ?? other.case
        let mergedSource: String?

        if hasAnyValue {
            mergedSource = source
        } else {
            mergedSource = other.source ?? source
        }

        return IslandAirPodsBattery(
            left: mergedLeft,
            right: mergedRight,
            case: mergedCase,
            source: mergedSource
        )
    }
}
