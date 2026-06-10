import XCTest
@testable import Xuanyu

final class MediaIslandAirPodsProbeTests: XCTestCase {
    func testParseBluetoothJSONReadsDictionaryConnectedAirPodsBatteryFields() throws {
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

        let status = try XCTUnwrap(IslandAirPodsProbe.parseBluetoothJSON(Data(json.utf8)))
        XCTAssertEqual(status.name, "星忆的AiPods")
        XCTAssertEqual(status.address, "8B:64:8B:BA:7D:73")
        XCTAssertTrue(status.isConnected)
        XCTAssertEqual(status.leftBattery, 100)
        XCTAssertEqual(status.rightBattery, 100)
        XCTAssertEqual(status.caseBattery, 99)
        XCTAssertEqual(status.batteryEvidenceSource, "SPBluetoothDataType")
    }

    func testParseBluetoothJSONStillReadsArrayConnectedAirPodsBatteryFields() throws {
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

        let status = try XCTUnwrap(IslandAirPodsProbe.parseBluetoothJSON(Data(json.utf8)))
        XCTAssertEqual(status.leftBattery, 90)
        XCTAssertEqual(status.rightBattery, 70)
        XCTAssertEqual(status.caseBattery, 80)
    }
}
