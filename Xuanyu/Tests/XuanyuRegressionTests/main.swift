#if DEBUG
import Foundation
@testable import Xuanyu

private struct TestFailure: Error, CustomStringConvertible {
    let file: StaticString
    let line: UInt
    let message: String

    var description: String {
        "\(file):\(line): \(message)"
    }
}

@MainActor
private func fail(_ message: String, file: StaticString = #filePath, line: UInt = #line) throws -> Never {
    throw TestFailure(file: file, line: line, message: message)
}

@MainActor
private func expectEqual<T: Equatable>(
    _ actual: @autoclosure () throws -> T,
    _ expected: @autoclosure () throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let actualValue = try actual()
    let expectedValue = try expected()
    guard actualValue == expectedValue else {
        try fail("expected \(expectedValue), got \(actualValue)", file: file, line: line)
    }
}

@MainActor
private func expectEqual(
    _ actual: @autoclosure () throws -> Double,
    _ expected: @autoclosure () throws -> Double,
    accuracy: Double,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let actualValue = try actual()
    let expectedValue = try expected()
    guard abs(actualValue - expectedValue) <= accuracy else {
        try fail("expected \(expectedValue) ± \(accuracy), got \(actualValue)", file: file, line: line)
    }
}

@MainActor
private func expectTrue(
    _ expression: @autoclosure () throws -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    guard try expression() else {
        try fail("expected true", file: file, line: line)
    }
}

@MainActor
private func expectFalse(
    _ expression: @autoclosure () throws -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    guard try !expression() else {
        try fail("expected false", file: file, line: line)
    }
}

@MainActor
private func unwrap<T>(
    _ value: @autoclosure () throws -> T?,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> T {
    guard let value = try value() else {
        try fail("expected non-nil value", file: file, line: line)
    }
    return value
}

@MainActor
struct XuanyuRegressionTestRunner {
    @MainActor
    static func main() {
        let sandboxURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("xuanyu-regression-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: sandboxURL, withIntermediateDirectories: true)
        } catch {
            print("Unable to create regression sandbox: \(error)")
            Darwin.exit(1)
        }
        Darwin.setenv("XUANYU_APP_SUPPORT_ROOT", sandboxURL.path, 1)
        defer {
            Darwin.unsetenv("XUANYU_APP_SUPPORT_ROOT")
            try? FileManager.default.removeItem(at: sandboxURL)
        }

        let tests: [(String, @MainActor () throws -> Void)] = [
            ("Regression tests use an isolated app support directory", testRegressionAppSupportIsIsolated),
            ("Agent store removes leaked regression fixtures", testAgentStoreRemovesLeakedRegressionFixtures),
            ("Agent store preserves meaningful leaked-session content", testAgentStorePreservesMeaningfulLeakedSessionContent),
            ("AgentService routes streaming deltas by runtime message id", testRuntimeMessageIdsRouteDeltasAndFinishSegments),
            ("AgentService keeps old-session runtime events out of active conversation", testRuntimeEventsWithOldSessionIdDoNotAppendToActiveConversation),
            ("Command hold short press never triggers hold", testShortCommandPressNeverTriggersHold),
            ("Command hold long press triggers and finishes once", testLongCommandPressTriggersAndFinishesOnce),
            ("Command hold other key cancels candidate", testOtherKeyCancelsCommandCandidate),
            ("Command hold both keys finish when last key is released", testBothCommandKeysFinishWhenLastKeyIsReleased),
            ("Command hold orphaned release does not start candidate", testOrphanedCommandReleaseDoesNotStartCandidate),
            ("AirPods parser reads dictionary connected battery fields", testParseBluetoothJSONReadsDictionaryConnectedAirPodsBatteryFields),
            ("AirPods parser reads array connected battery fields", testParseBluetoothJSONStillReadsArrayConnectedAirPodsBatteryFields),
            ("LRCLIB search skips empty first result", testLRCLIBSearchSkipsEmptyFirstResult),
            ("LRCLIB search prefers duration matched version", testLRCLIBSearchPrefersDurationMatchedVersion),
            ("LRCLIB search accepts decimal durations", testLRCLIBSearchAcceptsDecimalDurations),
            ("Lyrics query variants strip common version noise", testQueryVariantsStripCommonVersionNoise),
            ("Voice arming progress is visible and cancelable", testArmingProgressIsVisibleAndCancelable),
            ("Voice missing input monitoring shows persistent permission state", testMissingInputMonitoringShowsPersistentPermissionState),
            ("CodeWatch encodes claude project dirs", testCodeWatchProjectDirEncoding),
            ("CodeWatch matches claude/codex executables", testCodeWatchExecutableMatching),
            ("CodeWatch extracts codex session ids", testCodeWatchCodexSessionIdExtraction),
            ("CodeWatch reads codex session metadata", testCodeWatchCodexSessionMetadata),
            ("CodeWatch accepts v1 and v2 Codex pets", testCodeWatchPetVersionCompatibility),
            ("CodeWatch installer preserves foreign hooks", testCodeWatchInstallerPreservesForeignHooks),
            ("CodeWatch installer refuses broken settings", testCodeWatchInstallerRefusesBrokenSettings),
            ("CodeWatch service reduces hook events", testCodeWatchServiceReducesHookEvents),
            ("CodeWatch labels ChatGPT completion", testCodeWatchChatGPTCompletion),
            ("CodeWatch detects mid-turn Codex activity", testCodeWatchCodexMidTurnAttach),
            ("CodeWatch SessionStart keeps transcript path", testCodeWatchSessionStartKeepsTranscriptPath),
            ("CodeWatch tailer delivers appended lines", testCodeWatchTailerDeliversAppendedLines),
            ("CodeWatch socket server round trip", testCodeWatchSocketServerRoundTrip),
        ]

        var failures: [(String, Error)] = []
        print("Running \(tests.count) Xuanyu regression tests")
        for (name, test) in tests {
            do {
                try test()
                print("✓ \(name)")
            } catch {
                failures.append((name, error))
                print("✗ \(name)")
                print("  \(error)")
            }
        }

        if failures.isEmpty {
            print("All Xuanyu regression tests passed")
        } else {
            print("\(failures.count) Xuanyu regression test(s) failed")
            Darwin.exit(1)
        }
    }

    private static func testRegressionAppSupportIsIsolated() throws {
        let overridePath = try unwrap(ProcessInfo.processInfo.environment["XUANYU_APP_SUPPORT_ROOT"])
        try expectEqual(AppSupportDirectory.root.standardizedFileURL.path, URL(fileURLWithPath: overridePath).standardizedFileURL.path)
        try expectFalse(AppSupportDirectory.root.path.contains("/Library/Application Support/Xuanyu"))
    }

    private static func testAgentStoreRemovesLeakedRegressionFixtures() throws {
        let realConversation = AgentConversation(id: "real-conversation", title: "真实对话")
        let leakedActiveConversation = AgentConversation(
            id: "conversation-b",
            title: "你好",
            messages: [
                AgentMessage(role: .user, text: "你好"),
                AgentMessage(role: .user, text: "你好"),
            ]
        )
        let leakedOldConversation = AgentConversation(
            id: "conversation-a",
            title: "A",
            messages: [AgentMessage(role: .assistant, text: "旧会话结果")]
        )
        let store = AgentConversationStore(
            activeConversationId: leakedActiveConversation.id,
            conversations: [leakedActiveConversation, leakedOldConversation, realConversation]
        )

        let repaired = try unwrap(AgentConfigStore.repairingLeakedRegressionFixtures(in: store))
        try expectEqual(repaired.conversations.map(\.id), [realConversation.id])
        try expectEqual(repaired.activeConversationId, realConversation.id)
    }

    private static func testAgentStorePreservesMeaningfulLeakedSessionContent() throws {
        let meaningfulMessage = AgentMessage(role: .assistant, text: "这是真实回答")
        let leakedActiveConversation = AgentConversation(
            id: "conversation-b",
            title: "真实问题",
            messages: [meaningfulMessage]
        )
        let leakedOldConversation = AgentConversation(
            id: "conversation-a",
            title: "A",
            messages: [AgentMessage(role: .assistant, text: "旧会话结果")]
        )
        let store = AgentConversationStore(
            activeConversationId: leakedActiveConversation.id,
            conversations: [leakedActiveConversation, leakedOldConversation]
        )

        let repaired = try unwrap(AgentConfigStore.repairingLeakedRegressionFixtures(in: store))
        try expectEqual(repaired.conversations.count, 1)
        try expectFalse(repaired.conversations[0].id == leakedActiveConversation.id)
        try expectEqual(repaired.conversations[0].messages, [meaningfulMessage])
        try expectEqual(repaired.activeConversationId, repaired.conversations[0].id)
    }

    private static func testRuntimeMessageIdsRouteDeltasAndFinishSegments() throws {
        let service = AgentService()
        let firstId = UUID().uuidString
        let secondId = UUID().uuidString

        service.debugHandleRuntimeLine(try eventLine([
            "type": "assistant_delta",
            "messageId": firstId,
            "delta": "工具前",
        ]))
        service.debugHandleRuntimeLine(try eventLine([
            "type": "assistant_delta",
            "messageId": secondId,
            "delta": "最终",
        ]))
        service.debugHandleRuntimeLine(try eventLine([
            "type": "assistant_delta",
            "messageId": firstId,
            "delta": "说明",
        ]))

        try expectEqual(service.messages.count, 2)
        try expectEqual(service.messages[0].id.uuidString.uppercased(), firstId.uppercased())
        try expectEqual(service.messages[0].text, "工具前说明")
        try expectEqual(service.messages[1].id.uuidString.uppercased(), secondId.uppercased())
        try expectEqual(service.messages[1].text, "最终")
        try expectTrue(service.messages[0].isStreaming)
        try expectTrue(service.messages[1].isStreaming)

        service.debugHandleRuntimeLine(try eventLine([
            "type": "assistant_segment_done",
            "messageId": firstId,
        ]))

        try expectFalse(service.messages[0].isStreaming)
        try expectTrue(service.messages[1].isStreaming)

        service.debugHandleRuntimeLine(try eventLine([
            "type": "assistant_done",
        ]))

        try expectFalse(service.messages.contains { $0.isStreaming })
        try expectEqual(service.status, .ready)
    }

    private static func testRuntimeEventsWithOldSessionIdDoNotAppendToActiveConversation() throws {
        let service = AgentService()
        let oldConversation = AgentConversation(id: "conversation-a", title: "A")
        let activeConversation = AgentConversation(id: "conversation-b", title: "B")
        let messageId = UUID().uuidString
        service.conversations = [activeConversation, oldConversation]
        service.activeConversationId = "conversation-b"
        service.messages = []

        service.debugHandleRuntimeLine(try eventLine([
            "type": "assistant_delta",
            "sessionId": "conversation-a",
            "messageId": messageId,
            "delta": "旧会话结果",
        ]))
        service.debugHandleRuntimeLine(try eventLine([
            "type": "assistant_done",
            "sessionId": "conversation-a",
            "messageId": messageId,
        ]))

        try expectTrue(service.messages.isEmpty)
        let updatedOldConversation = try unwrap(service.conversations.first { $0.id == "conversation-a" })
        try expectEqual(updatedOldConversation.messages.count, 1)
        try expectEqual(updatedOldConversation.messages[0].text, "旧会话结果")
        try expectFalse(updatedOldConversation.messages[0].isStreaming)
        try expectEqual(service.activeConversationId, "conversation-b")
    }

    private static func eventLine(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private static func testShortCommandPressNeverTriggersHold() throws {
        var state = CommandHoldStateMachine()
        try expectEqual(state.commandFlagsChanged(keyCode: 55), [.scheduleHold])
        try expectEqual(state.commandFlagsChanged(keyCode: 55), [.cancelHold])
        try expectFalse(state.didTrigger)
    }

    private static func testLongCommandPressTriggersAndFinishesOnce() throws {
        var state = CommandHoldStateMachine()
        try expectEqual(state.commandFlagsChanged(keyCode: 55), [.scheduleHold])
        try expectTrue(state.holdThresholdReached())
        try expectFalse(state.holdThresholdReached())
        try expectEqual(state.commandFlagsChanged(keyCode: 55), [.finishHold])
        try expectFalse(state.didTrigger)
    }

    private static func testOtherKeyCancelsCommandCandidate() throws {
        var state = CommandHoldStateMachine()
        try expectEqual(state.commandFlagsChanged(keyCode: 55), [.scheduleHold])
        try expectEqual(state.otherKeyDown(), [.cancelHold])
        try expectFalse(state.holdThresholdReached())
        try expectEqual(state.commandFlagsChanged(keyCode: 55), [])
    }

    private static func testBothCommandKeysFinishWhenLastKeyIsReleased() throws {
        var state = CommandHoldStateMachine()
        try expectEqual(state.commandFlagsChanged(keyCode: 55), [.scheduleHold])
        try expectEqual(state.commandFlagsChanged(keyCode: 54), [])
        try expectTrue(state.holdThresholdReached())
        try expectEqual(state.commandFlagsChanged(keyCode: 55), [])
        try expectEqual(state.commandFlagsChanged(keyCode: 54), [.finishHold])
    }

    private static func testOrphanedCommandReleaseDoesNotStartCandidate() throws {
        var state = CommandHoldStateMachine()
        try expectEqual(
            state.commandFlagsChanged(keyCode: 55, commandModifierActive: false),
            []
        )
        try expectFalse(state.isCandidate)
        try expectTrue(state.pressedCommandKeys.isEmpty)
    }

    private static func testParseBluetoothJSONReadsDictionaryConnectedAirPodsBatteryFields() throws {
        let json = """
        {
          "SPBluetoothDataType": [
            {
              "device_connected": {
                "星忆的AiPods": {
                  "device_address": "8B:64:8B:BA:7D:73",
                  "device_batteryLevelCase": "99%",
                  "device_batteryLevelLeft": "100%",
                  "device_batteryLevelRight": "100%",
                  "device_minorType": "Headset",
                  "device_vendorID": "0x004C"
                }
              }
            }
          ]
        }
        """

        let status = try unwrap(IslandAirPodsProbe.parseBluetoothJSON(Data(json.utf8)))
        try expectEqual(status.name, "星忆的AiPods")
        try expectEqual(status.address, "8B:64:8B:BA:7D:73")
        try expectTrue(status.isConnected)
        try expectEqual(status.leftBattery, 100)
        try expectEqual(status.rightBattery, 100)
        try expectEqual(status.caseBattery, 99)
        try expectEqual(status.batteryEvidenceSource, "SPBluetoothDataType")
    }

    private static func testParseBluetoothJSONStillReadsArrayConnectedAirPodsBatteryFields() throws {
        let json = """
        {
          "SPBluetoothDataType": [
            {
              "device_connected": [
                {
                  "AirPods Pro": {
                    "device_address": "AA:BB:CC:DD:EE:FF",
                    "device_batteryLevelCase": "80%",
                    "device_batteryLevelLeft": "90%",
                    "device_batteryLevelRight": "70%",
                    "device_minorType": "Headset",
                    "device_vendorID": "0x004C"
                  }
                }
              ]
            }
          ]
        }
        """

        let status = try unwrap(IslandAirPodsProbe.parseBluetoothJSON(Data(json.utf8)))
        try expectEqual(status.leftBattery, 90)
        try expectEqual(status.rightBattery, 70)
        try expectEqual(status.caseBattery, 80)
    }

    private static func testLRCLIBSearchSkipsEmptyFirstResult() throws {
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

        try expectEqual(result.syncedLines.first?.text, "real lyric")
    }

    private static func testLRCLIBSearchPrefersDurationMatchedVersion() throws {
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

        try expectEqual(result.syncedLines.first?.text, "right")
    }

    private static func testLRCLIBSearchAcceptsDecimalDurations() throws {
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

        try expectEqual(result.syncedLines.first?.text, "Look at the stars")
    }

    private static func testQueryVariantsStripCommonVersionNoise() throws {
        try expectTrue(
            IslandLyricsService.debugTitleQueryVariants("Song Title (feat. Someone) - Remastered 2011")
                .contains("Song Title")
        )
        try expectEqual(
            IslandLyricsService.debugArtistQueryVariants("Artist, Guest").first,
            "Artist, Guest"
        )
        try expectTrue(
            IslandLyricsService.debugArtistQueryVariants("Artist, Guest")
                .contains("Artist")
        )
    }

    private static func testArmingProgressIsVisibleAndCancelable() throws {
        let service = VoiceInputService()
        service.setInputMonitoringAuthorized(true)

        service.beginArming()
        service.updateArmingProgress(0.6)

        try expectEqual(service.state, .arming)
        try expectEqual(service.armingProgress, 0.6, accuracy: 0.001)
        try expectFalse(service.prefersLargeHUD)

        service.cancelArming()

        try expectEqual(service.state, .idle)
        try expectFalse(service.shouldDisplay)
    }

    private static func testMissingInputMonitoringShowsPersistentPermissionState() throws {
        let service = VoiceInputService()

        service.setInputMonitoringAuthorized(false)

        try expectEqual(service.state, .permission)
        try expectTrue(service.prefersLargeHUD)
        try expectTrue(service.displayText.contains("输入监控"))
    }
}

#else
struct XuanyuRegressionTestRunner {
    static func main() {
        print("XuanyuRegressionTests is debug-only. Run `swift run XuanyuRegressionTests` without `-c release`.")
    }
}
#endif

// main.swift 与多源文件并存时不允许 @main，改用 top-level 入口调用。
MainActor.assumeIsolated {
    XuanyuRegressionTestRunner.main()
}
