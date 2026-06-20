import XCTest
@testable import Xuanyu

@MainActor
final class AgentServiceStreamingTests: XCTestCase {
    func testRuntimeMessageIdsRouteDeltasAndFinishSegments() throws {
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

        XCTAssertEqual(service.messages.count, 2)
        XCTAssertEqual(service.messages[0].id.uuidString.uppercased(), firstId.uppercased())
        XCTAssertEqual(service.messages[0].text, "工具前说明")
        XCTAssertEqual(service.messages[1].id.uuidString.uppercased(), secondId.uppercased())
        XCTAssertEqual(service.messages[1].text, "最终")
        XCTAssertTrue(service.messages[0].isStreaming)
        XCTAssertTrue(service.messages[1].isStreaming)

        service.debugHandleRuntimeLine(try eventLine([
            "type": "assistant_segment_done",
            "messageId": firstId,
        ]))

        XCTAssertFalse(service.messages[0].isStreaming)
        XCTAssertTrue(service.messages[1].isStreaming)

        service.debugHandleRuntimeLine(try eventLine([
            "type": "assistant_done",
        ]))

        XCTAssertFalse(service.messages.contains { $0.isStreaming })
        XCTAssertEqual(service.status, .ready)
    }

    func testRuntimeEventsWithOldSessionIdDoNotAppendToActiveConversation() throws {
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

        XCTAssertTrue(service.messages.isEmpty)
        let updatedOldConversation = try XCTUnwrap(service.conversations.first { $0.id == "conversation-a" })
        XCTAssertEqual(updatedOldConversation.messages.count, 1)
        XCTAssertEqual(updatedOldConversation.messages[0].text, "旧会话结果")
        XCTAssertFalse(updatedOldConversation.messages[0].isStreaming)
        XCTAssertEqual(service.activeConversationId, "conversation-b")
    }

    private func eventLine(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
