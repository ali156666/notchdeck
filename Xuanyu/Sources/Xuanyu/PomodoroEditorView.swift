import SwiftUI

struct PomodoroEditorView: View {
    @Bindable var service: PomodoroService
    @Environment(\.dismiss) private var dismiss
    @State private var selectedMode: PomodoroMode = .focus
    @State private var eventTitle = ""
    @State private var minutes = 25

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("番茄钟设置", systemImage: "timer")
                .font(.system(size: 15, weight: .bold))

            Picker("模式", selection: $selectedMode) {
                ForEach(PomodoroMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 6) {
                Text("事件")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                TextField("例如：写方案", text: $eventTitle)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("时间")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                Stepper(value: $minutes, in: 1...240) {
                    Text("\(minutes) 分钟")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                }
            }

            HStack {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                Button("保存") {
                    let canSwitchMode = service.status == .idle || service.status == .completed
                    service.saveConfiguration(mode: selectedMode, title: eventTitle, minutes: minutes)
                    if canSwitchMode {
                        service.selectMode(selectedMode)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 320)
        .onAppear {
            selectedMode = service.mode
            loadConfiguration()
        }
        .onChange(of: selectedMode) { _, _ in
            loadConfiguration()
        }
    }

    private func loadConfiguration() {
        let configuration = service.configuration(for: selectedMode)
        eventTitle = configuration.title
        minutes = configuration.minutes
    }
}
