import Foundation

struct IslandAirPodsProbe {
    func probe() async -> IslandAirPodsStatus {
        let bluetoothResult = await IslandProcess.run("/usr/sbin/system_profiler", arguments: ["SPBluetoothDataType", "-json"])
        let audioResult = await IslandProcess.run("/usr/sbin/system_profiler", arguments: ["SPAudioDataType", "-json"])
        let ioregResult = await IslandProcess.run("/usr/sbin/ioreg", arguments: ["-r", "-l", "-w0"], timeout: 8)

        var evidence: [String] = []
        evidence.append("SPBluetoothDataType exit=\(bluetoothResult.exitCode) bytes=\(bluetoothResult.stdout.utf8.count)")
        evidence.append("SPAudioDataType exit=\(audioResult.exitCode) bytes=\(audioResult.stdout.utf8.count)")
        evidence.append("ioreg exit=\(ioregResult.exitCode) bytes=\(ioregResult.stdout.utf8.count)")

        guard var status = Self.parseBluetoothJSON(Data(bluetoothResult.stdout.utf8)) else {
            evidence.append("No connected AirPods-like device found in SPBluetoothDataType")
            return IslandAirPodsStatus(isConnected: false, probeEvidence: evidence)
        }

        status.isAudioRouteActive = Self.parseAudioJSON(
            Data(audioResult.stdout.utf8),
            matchingDeviceName: status.name
        )

        var battery = IslandAirPodsBattery(
            left: status.leftBattery,
            right: status.rightBattery,
            case: status.caseBattery,
            source: status.batteryEvidenceSource
        )

        battery = battery.merged(with: Self.parseBatteryFromIORegistryText(
            ioregResult.stdout,
            deviceName: status.name,
            address: status.address
        ))

        if !battery.isComplete {
            let cachedBattery = Self.parseBatteryFromBluetoothCachedRecords(
                address: status.address,
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser
            )
            battery = battery.merged(with: cachedBattery)
        }

        status.leftBattery = battery.left
        status.rightBattery = battery.right
        status.caseBattery = battery.case
        status.batteryEvidenceSource = battery.source
        status.probeEvidence = evidence

        if !status.hasCompleteBattery {
            status.probeEvidence.append("AirPods battery triplet not exposed by probed sources")
        }

        return status
    }

    static func parseBluetoothJSON(_ data: Data) -> IslandAirPodsStatus? {
        guard let root = try? IslandJSON.dictionary(from: data),
              let sections = root["SPBluetoothDataType"] as? [[String: Any]]
        else {
            return nil
        }

        for section in sections {
            for (name, device) in connectedBluetoothDevices(in: section) {
                guard isAirPodsLike(name: name, device: device) else { continue }

                let bluetoothBattery = extractBattery(from: device)
                return IslandAirPodsStatus(
                    name: name,
                    address: device["device_address"] as? String ?? "",
                    isConnected: true,
                    leftBattery: bluetoothBattery.left,
                    rightBattery: bluetoothBattery.right,
                    caseBattery: bluetoothBattery.case,
                    batteryEvidenceSource: bluetoothBattery.hasAnyValue ? "SPBluetoothDataType" : nil,
                    lastUpdated: Date()
                )
            }
        }

        return nil
    }

    static func parseAudioJSON(_ data: Data, matchingDeviceName name: String) -> Bool {
        guard let root = try? IslandJSON.dictionary(from: data),
              let sections = root["SPAudioDataType"] as? [[String: Any]]
        else {
            return false
        }

        for section in sections {
            guard let items = section["_items"] as? [[String: Any]] else { continue }
            for item in items {
                guard (item["_name"] as? String) == name else { continue }
                if item["coreaudio_default_audio_input_device"] != nil ||
                    item["coreaudio_default_audio_output_device"] != nil ||
                    item["coreaudio_default_audio_system_device"] != nil {
                    return true
                }
            }
        }

        return false
    }

    static func parseBatteryFromIORegistryText(_ text: String, deviceName: String, address: String) -> IslandAirPodsBattery {
        let contextMatchesDevice = text.localizedCaseInsensitiveContains(deviceName)
            || (!address.isEmpty && text.localizedCaseInsensitiveContains(address))
            || text.localizedCaseInsensitiveContains("AirPods")

        guard contextMatchesDevice else {
            return IslandAirPodsBattery(source: "ioreg")
        }

        return IslandAirPodsBattery(
            left: firstBatteryValue(in: text, keys: BatteryKeys.left),
            right: firstBatteryValue(in: text, keys: BatteryKeys.right),
            case: firstBatteryValue(in: text, keys: BatteryKeys.case),
            source: "ioreg"
        )
    }

    static func parseBatteryFromBluetoothCachedRecords(address: String, homeDirectory: URL) -> IslandAirPodsBattery {
        guard !address.isEmpty else { return IslandAirPodsBattery(source: "bluetooth cached records") }

        var best = IslandAirPodsBattery(source: "bluetooth cached records")
        let candidates = bluetoothRecordCandidates(address: address, homeDirectory: homeDirectory)

        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            else {
                continue
            }

            let parsed = extractBattery(from: object)
            best = best.merged(with: IslandAirPodsBattery(
                left: parsed.left,
                right: parsed.right,
                case: parsed.case,
                source: url.path
            ))

            if best.isComplete {
                return best
            }
        }

        return best
    }

    static func extractBattery(from object: Any) -> IslandAirPodsBattery {
        var result = IslandAirPodsBattery()
        visitPropertyList(object) { key, value in
            if result.left == nil, BatteryKeys.left.contains(where: { key.caseInsensitiveCompare($0) == .orderedSame }) {
                result.left = IslandJSON.intFromLooseValue(value)
            }

            if result.right == nil, BatteryKeys.right.contains(where: { key.caseInsensitiveCompare($0) == .orderedSame }) {
                result.right = IslandJSON.intFromLooseValue(value)
            }

            if result.case == nil, BatteryKeys.case.contains(where: { key.caseInsensitiveCompare($0) == .orderedSame }) {
                result.case = IslandJSON.intFromLooseValue(value)
            }
        }
        return result
    }

    private static func isAirPodsLike(name: String, device: [String: Any]) -> Bool {
        let lowerName = name.lowercased()
        if lowerName.contains("airpods") || lowerName.contains("aipods") {
            return true
        }

        let vendor = (device["device_vendorID"] as? String) ?? ""
        let minorType = ((device["device_minorType"] as? String) ?? "").lowercased()
        let hasBudSerials = device["device_serialNumberLeft"] != nil && device["device_serialNumberRight"] != nil

        return vendor.contains("0x004C") && hasBudSerials && (minorType.contains("headset") || minorType.contains("headphones"))
    }

    private static func connectedBluetoothDevices(in section: [String: Any]) -> [(name: String, device: [String: Any])] {
        guard let rawConnected = section["device_connected"] else { return [] }

        if let connected = rawConnected as? [String: Any] {
            return connected.compactMap { name, rawDevice in
                guard let device = rawDevice as? [String: Any] else { return nil }
                return (name, device)
            }
        }

        if let connected = rawConnected as? [[String: Any]] {
            return connected.flatMap { item in
                item.compactMap { name, rawDevice in
                    guard let device = rawDevice as? [String: Any] else { return nil }
                    return (name, device)
                }
            }
        }

        return []
    }

    private static func firstBatteryValue(in text: String, keys: [String]) -> Int? {
        for key in keys {
            let escaped = NSRegularExpression.escapedPattern(for: key)
            let pattern = #""# + escaped + #""\s*=\s*"?([0-9]{1,3})"?"#
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = regex.firstMatch(in: text, range: range),
               let valueRange = Range(match.range(at: 1), in: text),
               let value = Int(text[valueRange]),
               let normalized = IslandJSON.normalizeBatteryPercent(value) {
                return normalized
            }
        }

        return nil
    }

    private static func bluetoothRecordCandidates(address: String, homeDirectory: URL) -> [URL] {
        var candidates: [URL] = []
        let fileManager = FileManager.default

        let cloudRecords = homeDirectory
            .appendingPathComponent("Library")
            .appendingPathComponent("com.apple.bluetooth.services.cloud")
            .appendingPathComponent("CachedRecords")

        if let enumerator = fileManager.enumerator(at: cloudRecords, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator {
                if url.lastPathComponent == address || url.path.localizedCaseInsensitiveContains(address) {
                    candidates.append(url)
                }
            }
        }

        candidates.append(homeDirectory.appendingPathComponent("Library/Preferences/com.apple.bluetooth.plist"))
        candidates.append(homeDirectory.appendingPathComponent("Library/Preferences/com.apple.Bluetooth.plist"))
        candidates.append(homeDirectory.appendingPathComponent("Library/Preferences/com.apple.bluetoothuserd.plist"))

        return candidates
    }

    private static func visitPropertyList(_ object: Any, visitor: (String, Any) -> Void) {
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary {
                visitor(key, value)
                visitPropertyList(value, visitor: visitor)
            }
        } else if let array = object as? [Any] {
            for value in array {
                visitPropertyList(value, visitor: visitor)
            }
        } else if let data = object as? Data,
                  let nested = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
            visitPropertyList(nested, visitor: visitor)
        }
    }
}

private enum BatteryKeys {
    static let left = [
        "device_batteryLevelLeft",
        "BatteryPercentLeft",
        "BatteryPercentLeftBud",
        "leftBattery",
        "leftBatteryPercent",
        "LeftBattery",
        "LeftBatteryPercent",
        "leftBudBattery",
        "leftBudBatteryPercent",
        "batteryPercentLeft"
    ]

    static let right = [
        "device_batteryLevelRight",
        "BatteryPercentRight",
        "BatteryPercentRightBud",
        "rightBattery",
        "rightBatteryPercent",
        "RightBattery",
        "RightBatteryPercent",
        "rightBudBattery",
        "rightBudBatteryPercent",
        "batteryPercentRight"
    ]

    static let `case` = [
        "device_batteryLevelCase",
        "BatteryPercentCase",
        "BatteryPercentCaseBud",
        "caseBattery",
        "caseBatteryPercent",
        "CaseBattery",
        "CaseBatteryPercent",
        "batteryPercentCase"
    ]
}
