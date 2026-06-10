import SwiftUI

struct SystemDashboardPanel: View {
    @Bindable var service: SystemDashboardService

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                systemCard
                memoryCard
                weatherCard
            }
            .frame(height: 126)

            HStack(alignment: .top, spacing: 10) {
                scheduleCard
                    .frame(maxWidth: .infinity)
                calendarCard
                    .frame(width: 300)
            }
            .frame(height: 216)
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .onAppear {
            service.refreshAll()
        }
    }

    private var systemCard: some View {
        DashboardCard(title: "系统配置", icon: "desktopcomputer") {
            VStack(alignment: .leading, spacing: 7) {
                Text(service.system.hostName)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                DashboardKV("系统", service.system.osVersion)
                DashboardKV("型号", service.system.model)
                DashboardKV("处理器", service.system.processor)
                DashboardKV("运行", service.system.uptime)
            }
        }
    }

    private var memoryCard: some View {
        DashboardCard(title: "内存", icon: "memorychip") {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(Int(service.memory.percent * 100))%")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("已用")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.48))
                }
                ProgressView(value: service.memory.percent)
                    .tint(memoryTint)
                Text("\(service.formattedBytes(service.memory.usedBytes)) / \(service.formattedBytes(service.memory.totalBytes))")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
            }
        }
    }

    private var weatherCard: some View {
        DashboardCard(title: "天气", icon: "cloud.sun") {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(service.weather.temperature)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(service.weather.city)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.56))
                        .lineLimit(1)
                }
                Text(service.weather.description)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                Text(service.weather.detail.isEmpty ? "自动按网络位置获取" : service.weather.detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.46))
                    .lineLimit(1)
            }
        }
    }

    private var scheduleCard: some View {
        DashboardCard(title: "日程", icon: "calendar.badge.clock") {
            VStack(alignment: .leading, spacing: 7) {
                Text(service.calendarStatus)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.48))
                if service.events.isEmpty {
                    Text("没有即将开始的日程")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.62))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    ForEach(service.events) { event in
                        HStack(spacing: 8) {
                            Text(event.timeText)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.58))
                                .frame(width: 62, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.84))
                                    .lineLimit(1)
                                Text(event.calendarName)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.36))
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
    }

    private var calendarCard: some View {
        DashboardCard(title: Date().formatted(.dateTime.year().month(.wide)), icon: "calendar") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 5) {
                ForEach(["日", "一", "二", "三", "四", "五", "六"], id: \.self) { text in
                    Text(text)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.34))
                        .frame(height: 16)
                }
                ForEach(service.calendarDays) { day in
                    Text("\(day.day)")
                        .font(.system(size: 11, weight: day.isToday ? .bold : .semibold, design: .rounded))
                        .foregroundStyle(day.isToday ? .black : .white.opacity(day.isCurrentMonth ? 0.78 : 0.24))
                        .frame(width: 24, height: 22)
                        .background(day.isToday ? .white : .clear, in: Capsule())
                }
            }
        }
    }

    private var memoryTint: Color {
        if service.memory.percent > 0.82 { return Color(red: 1.0, green: 0.34, blue: 0.26) }
        if service.memory.percent > 0.62 { return Color(red: 1.0, green: 0.78, blue: 0.28) }
        return Color(red: 0.45, green: 1.0, blue: 0.58)
    }
}

private struct DashboardCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.74))
                .lineLimit(1)
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.07), lineWidth: 1)
        }
    }
}

private struct DashboardKV: View {
    let key: String
    let value: String

    init(_ key: String, _ value: String) {
        self.key = key
        self.value = value
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(key)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.36))
                .frame(width: 36, alignment: .leading)
            Text(value)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.68))
                .lineLimit(1)
        }
    }
}
