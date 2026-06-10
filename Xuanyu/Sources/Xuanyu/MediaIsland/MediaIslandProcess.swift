import Foundation

struct IslandProcessResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

enum IslandProcess {
    static func run(_ path: String, arguments: [String], timeout: TimeInterval = 12) async -> IslandProcessResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: IslandProcessResult(
                        stdout: "",
                        stderr: "\(error)",
                        exitCode: -1
                    ))
                    return
                }

                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }

                if process.isRunning {
                    process.terminate()
                    Thread.sleep(forTimeInterval: 0.2)
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                }

                let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: IslandProcessResult(
                    stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                    stderr: String(data: stderrData, encoding: .utf8) ?? "",
                    exitCode: process.terminationStatus
                ))
            }
        }
    }
}

enum IslandJSON {
    static func dictionary(from data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }

    static func intFromLooseValue(_ value: Any) -> Int? {
        if let int = value as? Int {
            return normalizeBatteryPercent(int)
        }
        if let number = value as? NSNumber {
            return normalizeBatteryPercent(number.intValue)
        }
        if let string = value as? String {
            let digits = string.filter(\.isNumber)
            guard let int = Int(digits) else { return nil }
            return normalizeBatteryPercent(int)
        }
        return nil
    }

    static func normalizeBatteryPercent(_ value: Int) -> Int? {
        if (0...100).contains(value) { return value }
        if (0...10).contains(value) { return value * 10 }
        return nil
    }
}
