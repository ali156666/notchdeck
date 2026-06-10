import AppKit
import CoreLocation
import Darwin
import EventKit
import Foundation

struct SystemDashboardInfo: Equatable {
    var hostName = Host.current().localizedName ?? "Mac"
    var osVersion = ProcessInfo.processInfo.operatingSystemVersionString
    var model = "Mac"
    var processor = "Apple Silicon"
    var coreText = "\(ProcessInfo.processInfo.processorCount) 核"
    var uptime = ""
}

struct SystemMemoryInfo: Equatable {
    var usedBytes: UInt64 = 0
    var totalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    var percent: Double = 0
}

struct DashboardWeather: Equatable {
    var city = "天气"
    var temperature = "--"
    var description = "加载中"
    var detail = ""
}

struct DashboardEvent: Identifiable, Equatable {
    var id: String
    var title: String
    var timeText: String
    var calendarName: String
}

struct DashboardCalendarDay: Identifiable, Equatable {
    var id: String
    var day: Int
    var isToday: Bool
    var isCurrentMonth: Bool
}

@MainActor
@Observable
final class SystemDashboardService: NSObject, CLLocationManagerDelegate {
    var system = SystemDashboardInfo()
    var memory = SystemMemoryInfo()
    var weather = DashboardWeather()
    var events: [DashboardEvent] = []
    var calendarDays: [DashboardCalendarDay] = []
    var calendarStatus = "日历未授权"

    @ObservationIgnored private let eventStore = EKEventStore()
    @ObservationIgnored private let locationManager = CLLocationManager()
    @ObservationIgnored private let geocoder = CLGeocoder()
    @ObservationIgnored private var refreshTimer: Timer?
    @ObservationIgnored private var latestLocation: CLLocation?
    @ObservationIgnored private let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useGB, .useMB]
        return formatter
    }()

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        refreshSystem()
        refreshCalendarGrid()
    }

    func start() {
        refreshAll()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAll() }
        }
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func refreshAll() {
        refreshSystem()
        refreshCalendarGrid()
        refreshEvents()
        refreshWeather()
    }

    func formattedBytes(_ value: UInt64) -> String {
        byteFormatter.string(fromByteCount: Int64(value))
    }

    private func refreshSystem() {
        let model = sysctlString("hw.model").nilIfEmpty ?? "Mac"
        let processor = sysctlString("machdep.cpu.brand_string").nilIfEmpty ?? "Apple Silicon"
        let uptimeSeconds = ProcessInfo.processInfo.systemUptime
        system = SystemDashboardInfo(
            hostName: Host.current().localizedName ?? "Mac",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString.replacingOccurrences(of: "Version ", with: ""),
            model: model,
            processor: processor,
            coreText: "\(ProcessInfo.processInfo.processorCount) 核 CPU",
            uptime: formatDuration(uptimeSeconds)
        )
        memory = readMemoryInfo()
    }

    private func refreshEvents() {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .notDetermined {
            calendarStatus = "点击刷新授权日历"
            requestCalendarAccess()
            return
        }
        guard status == .fullAccess else {
            calendarStatus = "日历未授权"
            events = []
            return
        }

        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: 14, to: now) ?? now
        let predicate = eventStore.predicateForEvents(withStart: now, end: end, calendars: nil)
        let dateFormatter = DateFormatter()
        dateFormatter.locale = .autoupdatingCurrent
        dateFormatter.dateFormat = "M/d HH:mm"

        events = eventStore.events(matching: predicate)
            .filter { !$0.isAllDay || $0.endDate >= now }
            .prefix(5)
            .map { event in
                DashboardEvent(
                    id: event.eventIdentifier ?? "\(event.title ?? "")-\(event.startDate.timeIntervalSince1970)",
                    title: event.title.nilIfEmpty ?? "未命名日程",
                    timeText: event.isAllDay ? "全天" : dateFormatter.string(from: event.startDate),
                    calendarName: event.calendar.title
                )
            }
        calendarStatus = events.isEmpty ? "未来 14 天没有日程" : "未来 14 天"
    }

    private func requestCalendarAccess() {
        eventStore.requestFullAccessToEvents { [weak self] granted, _ in
            Task { @MainActor in
                guard let self else { return }
                self.calendarStatus = granted ? "日历已授权" : "日历未授权"
                if granted {
                    self.refreshEvents()
                }
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.handleLocationAuthorization(manager.authorizationStatus)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            self.latestLocation = location
            await self.refreshWeather(for: location)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.weather = DashboardWeather(city: "天气", temperature: "--", description: "定位失败", detail: error.localizedDescription)
        }
    }

    private func refreshWeather() {
        let status = locationManager.authorizationStatus
        if status == .notDetermined {
            weather = DashboardWeather(city: "天气", temperature: "--", description: "需要位置权限", detail: "允许后按当前位置获取")
            locationManager.requestWhenInUseAuthorization()
            return
        }
        handleLocationAuthorization(status)
    }

    private func handleLocationAuthorization(_ status: CLAuthorizationStatus) {
        guard status == .authorizedAlways else {
            weather = DashboardWeather(city: "天气", temperature: "--", description: "位置未授权", detail: "系统设置中允许位置权限")
            return
        }
        if let latestLocation, abs(latestLocation.timestamp.timeIntervalSinceNow) < 1_800 {
            Task { await refreshWeather(for: latestLocation) }
        } else {
            weather = DashboardWeather(city: "天气", temperature: "--", description: "定位中", detail: "按当前位置获取")
            locationManager.requestLocation()
        }
    }

    private func refreshWeather(for location: CLLocation) async {
        guard var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast") else { return }
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", location.coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", location.coordinate.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,relative_humidity_2m,apparent_temperature,weather_code"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        guard let url = components.url else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(OpenMeteoResponse.self, from: data)
            let city = await locationName(for: location)
            let current = decoded.current
            let temp = "\(Int(round(current.temperature)))°"
            let feels = "体感 \(Int(round(current.apparentTemperature)))°"
            let humidity = "湿度 \(Int(round(current.humidity)))%"
            weather = DashboardWeather(
                city: city,
                temperature: temp,
                description: weatherDescription(for: current.weatherCode),
                detail: "\(feels) · \(humidity)"
            )
        } catch {
            weather = DashboardWeather(city: "天气", temperature: "--", description: "获取失败", detail: "检查网络后刷新")
        }
    }

    private func locationName(for location: CLLocation) async -> String {
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            let placemark = placemarks.first
            return placemark?.locality?.nilIfEmpty
                ?? placemark?.subLocality?.nilIfEmpty
                ?? placemark?.administrativeArea?.nilIfEmpty
                ?? "当前位置"
        } catch {
            return "当前位置"
        }
    }

    private func weatherDescription(for code: Int) -> String {
        switch code {
        case 0: "晴"
        case 1, 2: "少云"
        case 3: "多云"
        case 45, 48: "雾"
        case 51, 53, 55: "毛毛雨"
        case 56, 57: "冻雨"
        case 61, 63, 65: "雨"
        case 66, 67: "冻雨"
        case 71, 73, 75: "雪"
        case 77: "雪粒"
        case 80, 81, 82: "阵雨"
        case 85, 86: "阵雪"
        case 95: "雷暴"
        case 96, 99: "雷暴伴冰雹"
        default: "天气"
        }
    }

    private func refreshCalendarGrid() {
        let calendar = Calendar.current
        let today = Date()
        let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: today)) ?? today
        let firstWeekday = calendar.component(.weekday, from: startOfMonth)
        let leadingDays = (firstWeekday - calendar.firstWeekday + 7) % 7
        let gridStart = calendar.date(byAdding: .day, value: -leadingDays, to: startOfMonth) ?? startOfMonth

        calendarDays = (0..<35).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: gridStart) else { return nil }
            let comps = calendar.dateComponents([.year, .month, .day], from: date)
            let currentMonth = calendar.component(.month, from: date) == calendar.component(.month, from: today)
            return DashboardCalendarDay(
                id: "\(comps.year ?? 0)-\(comps.month ?? 0)-\(comps.day ?? 0)",
                day: comps.day ?? 0,
                isToday: calendar.isDateInToday(date),
                isCurrentMonth: currentMonth
            )
        }
    }

    private func readMemoryInfo() -> SystemMemoryInfo {
        let total = ProcessInfo.processInfo.physicalMemory
        if let freePercent = memoryPressureFreePercentage() {
            let usedPercent = min(max(1.0 - freePercent / 100.0, 0), 1)
            return SystemMemoryInfo(
                usedBytes: UInt64(Double(total) * usedPercent),
                totalBytes: total,
                percent: usedPercent
            )
        }

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return SystemMemoryInfo(usedBytes: 0, totalBytes: total, percent: 0)
        }

        let pageSize = UInt64(vm_kernel_page_size)
        let freePages = UInt64(stats.free_count) + UInt64(stats.speculative_count)
        let freeBytes = freePages * pageSize
        let used = total > freeBytes ? total - freeBytes : 0
        return SystemMemoryInfo(usedBytes: used, totalBytes: total, percent: total == 0 ? 0 : Double(used) / Double(total))
    }

    private func memoryPressureFreePercentage() -> Double? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/memory_pressure")
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8),
                  let line = text.split(separator: "\n").first(where: { $0.contains("System-wide memory free percentage") }),
                  let percentText = line.split(separator: ":").last?.trimmingCharacters(in: CharacterSet(charactersIn: " %"))
            else {
                return nil
            }
            return Double(percentText)
        } catch {
            return nil
        }
    }

    private func sysctlString(_ key: String) -> String {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let days = Int(seconds) / 86_400
        let hours = (Int(seconds) % 86_400) / 3_600
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        return "\(hours) 小时"
    }
}

private struct OpenMeteoResponse: Decodable {
    var current: OpenMeteoCurrent
}

private struct OpenMeteoCurrent: Decodable {
    var temperature: Double
    var apparentTemperature: Double
    var humidity: Double
    var weatherCode: Int
    
    enum CodingKeys: String, CodingKey {
        case temperature = "temperature_2m"
        case apparentTemperature = "apparent_temperature"
        case humidity = "relative_humidity_2m"
        case weatherCode = "weather_code"
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
