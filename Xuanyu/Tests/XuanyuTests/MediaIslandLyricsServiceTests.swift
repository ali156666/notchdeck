import XCTest
@testable import Xuanyu

final class MediaIslandLyricsServiceTests: XCTestCase {
    func testLRCLIBSearchSkipsEmptyFirstResult() throws {
        let json = """
        [
          {
            "trackName": "Needle",
            "artistName": "Artist",
            "albumName": "Album",
            "duration": 180,
            "plainLyrics": "",
            "syncedLyrics": ""
          },
          {
            "trackName": "Needle",
            "artistName": "Artist",
            "albumName": "Album",
            "duration": 180,
            "plainLyrics": "real lyric",
            "syncedLyrics": "[00:01.00]real lyric"
          }
        ]
        """

        let result = IslandLyricsService.parseLRCLIBSearch(
            data: Data(json.utf8),
            title: "Needle",
            artist: "Artist",
            album: "Album",
            duration: 180
        )

        XCTAssertEqual(result.syncedLines.first?.text, "real lyric")
    }

    func testLRCLIBSearchPrefersDurationMatchedVersion() throws {
        let json = """
        [
          {
            "trackName": "Same Song",
            "artistName": "Artist",
            "albumName": "Wrong Album",
            "duration": 260,
            "plainLyrics": "wrong",
            "syncedLyrics": "[00:01.00]wrong"
          },
          {
            "trackName": "Same Song",
            "artistName": "Artist",
            "albumName": "Right Album",
            "duration": 201,
            "plainLyrics": "right",
            "syncedLyrics": "[00:01.00]right"
          }
        ]
        """

        let result = IslandLyricsService.parseLRCLIBSearch(
            data: Data(json.utf8),
            title: "Same Song",
            artist: "Artist",
            album: "Right Album",
            duration: 200
        )

        XCTAssertEqual(result.syncedLines.first?.text, "right")
    }

    func testLRCLIBSearchAcceptsDecimalDurations() throws {
        let json = """
        [
          {
            "trackName": "Yellow",
            "artistName": "Coldplay",
            "albumName": "Parachutes",
            "duration": 267.0,
            "plainLyrics": "Look at the stars",
            "syncedLyrics": "[00:33.80]Look at the stars"
          }
        ]
        """

        let result = IslandLyricsService.parseLRCLIBSearch(
            data: Data(json.utf8),
            title: "Yellow",
            artist: "Coldplay",
            album: "Parachutes",
            duration: 267
        )

        XCTAssertEqual(result.syncedLines.first?.text, "Look at the stars")
    }

    func testQueryVariantsStripCommonVersionNoise() throws {
        XCTAssertTrue(
            IslandLyricsService.debugTitleQueryVariants("Song Title (feat. Someone) - Remastered 2011")
                .contains("Song Title")
        )
        XCTAssertEqual(
            IslandLyricsService.debugArtistQueryVariants("Artist, Guest").first,
            "Artist, Guest"
        )
        XCTAssertTrue(
            IslandLyricsService.debugArtistQueryVariants("Artist, Guest")
                .contains("Artist")
        )
    }
}
