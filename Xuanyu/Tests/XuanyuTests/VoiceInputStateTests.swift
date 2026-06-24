import XCTest
@testable import Xuanyu

@MainActor
final class VoiceInputStateTests: XCTestCase {
    func testArmingProgressIsVisibleAndCancelable() {
        let service = VoiceInputService()
        service.setInputMonitoringAuthorized(true)

        service.beginArming()
        service.updateArmingProgress(0.6)

        XCTAssertEqual(service.state, .arming)
        XCTAssertEqual(service.armingProgress, 0.6, accuracy: 0.001)
        XCTAssertFalse(service.prefersLargeHUD)

        service.cancelArming()

        XCTAssertEqual(service.state, .idle)
        XCTAssertFalse(service.shouldDisplay)
    }

    func testMissingInputMonitoringShowsPersistentPermissionState() {
        let service = VoiceInputService()

        service.setInputMonitoringAuthorized(false)

        XCTAssertEqual(service.state, .permission)
        XCTAssertTrue(service.prefersLargeHUD)
        XCTAssertTrue(service.displayText.contains("输入监控"))
    }
}
