import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var scope: UserScope

    var body: some View {
        List {
            Section("画质") {
                Picker("预设", selection: Binding(
                    get: { container.settings.stream.preset },
                    set: { p in container.settings.updateStream { $0 = $0.withPreset(p) } }
                )) {
                    ForEach(QualityPreset.allCases) { Text($0.label).tag($0) }
                }
                Stepper("最大分辨率 \(container.settings.stream.maxSize)",
                        value: Binding(get: { container.settings.stream.maxSize },
                                       set: { v in container.settings.updateStream { $0.maxSize = v } }),
                        in: 0...4096, step: 120)
                Stepper("最大帧率 \(container.settings.stream.maxFps) fps",
                        value: Binding(get: { container.settings.stream.maxFps },
                                       set: { v in container.settings.updateStream { $0.maxFps = v } }),
                        in: 0...144)
                Stepper("码率 \(container.settings.stream.bitrateMbps) Mbps",
                        value: Binding(get: { container.settings.stream.bitrateMbps },
                                       set: { v in container.settings.updateStream { $0.bitrateMbps = v } }),
                        in: 1...100)
                Toggle("自适应码率 (BWE)", isOn: Binding(
                    get: { container.settings.stream.bwe },
                    set: { v in container.settings.updateStream { $0.bwe = v } }))
                Toggle("音频", isOn: Binding(
                    get: { container.settings.stream.audio },
                    set: { v in container.settings.updateStream { $0.audio = v } }))
                Button("恢复默认画质") { container.settings.resetStream() }
            }
            Section("通用") {
                Picker("主题", selection: Binding(
                    get: { container.settings.app.themeMode },
                    set: { v in container.settings.updateApp { $0.themeMode = v } }
                )) {
                    Text("跟随系统").tag(ThemeMode.system)
                    Text("浅色").tag(ThemeMode.light)
                    Text("深色").tag(ThemeMode.dark)
                }
                Stepper("宫格列数 \(container.settings.app.gridColumns)",
                        value: Binding(get: { container.settings.app.gridColumns },
                                       set: { v in container.settings.updateApp { $0.gridColumns = v } }),
                        in: 1...4)
                Toggle("自动重连", isOn: Binding(
                    get: { container.settings.app.autoReconnect },
                    set: { v in container.settings.updateApp { $0.autoReconnect = v }
                           scope.sessionManager?.setAutoReconnect(v) }))
                Toggle("剪贴板同步", isOn: Binding(
                    get: { container.settings.app.clipboardSync },
                    set: { v in container.settings.updateApp { $0.clipboardSync = v } }))
                Toggle("显示网络统计", isOn: Binding(
                    get: { container.settings.app.showStats },
                    set: { v in container.settings.updateApp { $0.showStats = v } }))
                Toggle("保持亮屏", isOn: Binding(
                    get: { container.settings.app.keepScreenOn },
                    set: { v in container.settings.updateApp { $0.keepScreenOn = v } }))
            }
            Section("证书") {
                NavigationLink { CertificatesView() } label: { Label("已信任证书", systemImage: "lock.shield") }
            }
        }
        .navigationTitle("设置")
    }
}

struct CertificatesView: View {
    @State private var pins: [CertificatePinStore.PinnedCertificate] = []
    private let store = CertificatePinStore()

    var body: some View {
        List {
            if pins.isEmpty { Text("暂无已信任证书").foregroundStyle(.secondary) }
            ForEach(pins) { pin in
                VStack(alignment: .leading) {
                    Text(pin.endpointKey).font(.subheadline.weight(.medium))
                    Text(pin.subject).font(.caption)
                    Text(pin.sha256).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                .swipeActions {
                    Button("移除", role: .destructive) {
                        store.remove(endpointKey: pin.endpointKey)
                        pins = store.load()
                    }
                }
            }
        }
        .navigationTitle("已信任证书")
        .onAppear { pins = store.load() }
    }
}
