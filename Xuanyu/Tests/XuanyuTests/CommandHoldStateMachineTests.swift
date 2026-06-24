import CoreGraphics
import XCTest
@testable import Xuanyu

final class CommandHoldStateMachineTests: XCTestCase {
    func testShortCommandPressNeverTriggersHold() {
        var state = CommandHoldStateMachine()

        XCTAssertEqual(state.commandFlagsChanged(keyCode: 55), [.scheduleHold])
        XCTAssertEqual(state.commandFlagsChanged(keyCode: 55), [.cancelHold])
        XCTAssertFalse(state.didTrigger)
    }

    func testLongCommandPressTriggersAndFinishesOnce() {
        var state = CommandHoldStateMachine()

        XCTAssertEqual(state.commandFlagsChanged(keyCode: 55), [.scheduleHold])
        XCTAssertTrue(state.holdThresholdReached())
        XCTAssertFalse(state.holdThresholdReached())
        XCTAssertEqual(state.commandFlagsChanged(keyCode: 55), [.finishHold])
        XCTAssertFalse(state.didTrigger)
    }

    func testOtherKeyCancelsCommandCandidate() {
        var state = CommandHoldStateMachine()

        XCTAssertEqual(state.commandFlagsChanged(keyCode: 55), [.scheduleHold])
        XCTAssertEqual(state.otherKeyDown(), [.cancelHold])
        XCTAssertFalse(state.holdThresholdReached())
        XCTAssertEqual(state.commandFlagsChanged(keyCode: 55), [])
    }

    func testBothCommandKeysFinishWhenLastKeyIsReleased() {
        var state = CommandHoldStateMachine()

        XCTAssertEqual(state.commandFlagsChanged(keyCode: 55), [.scheduleHold])
        XCTAssertEqual(state.commandFlagsChanged(keyCode: 54), [])
        XCTAssertTrue(state.holdThresholdReached())
        XCTAssertEqual(state.commandFlagsChanged(keyCode: 55), [])
        XCTAssertEqual(state.commandFlagsChanged(keyCode: 54), [.finishHold])
    }

    func testOrphanedCommandReleaseDoesNotStartCandidate() {
        var state = CommandHoldStateMachine()

        XCTAssertEqual(
            state.commandFlagsChanged(keyCode: 55, commandModifierActive: false),
            []
        )
        XCTAssertFalse(state.isCandidate)
        XCTAssertTrue(state.pressedCommandKeys.isEmpty)
    }
}
