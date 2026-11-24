import SwiftUI

/// 可 Hashable 的标签选项（供 FlexibleChips 使用）
struct LabelOption: Hashable {
    let label: String
    let value: ThemeMode
}

/// 可 Hashable 的字符串标签选项
struct StrOption: Hashable {
    let label: String
    let value: String
}

/// 画质与编码（对齐 Android StreamSettingsScreen：档位 chips + 滑条）
struct StreamSettingsView: View {
    @EnvironmentObject private var container: AppContainer

    private var stream: StreamSettings { container.settings.stream }
    private var me: Me? { container.userScope?.devices.me }
    private func forbidden(_ keyPath: KeyPath<UserPolicy, Bool>) -> Bool {
        me?.policy[keyPath: keyPath] ?? false
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                SectionCard(title: "画质档位") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(presetHint).font(.system(size: 12)).foregroundStyle(.secondary)
                        FlexibleChips(items: QualityPreset.allCases.filter { $0 != .custom }) { p in
                            FilterChip(text: presetDesc(p), selected: stream.preset == p) {
                                container.settings.updateStream { $0 = $0.withPreset(p) }
                            }
                        }
                    }
                    .padding(14)
                }

                SectionCard(title: "高级参数") {
                    VStack(spacing: 14) {
                        sliderRow(label: "最大分辨率",
                                  valueText: stream.maxSize == 0 ? "原始" : "\(stream.maxSize)",
                                  value: Binding(get: { Double(stream.maxSize) },
                                                 set: { v in container.settings.updateStream { $0.maxSize = snap($0, v) } }),
                                  range: 0...2560, steps: [0, 480, 720, 1080, 1280, 1600, 1920, 2560],
                                  disabled: forbidden(\.forbidResolution))
                        sliderRow(label: "最大帧率",
                                  valueText: stream.maxFps == 0 ? "不限" : "\(stream.maxFps) fps",
                                  value: Binding(get: { Double(stream.maxFps) },
                                                 set: { v in container.settings.updateStream { $0.maxFps = Int(v) / 15 * 15 } }),
                                  range: 0...120, steps: nil,
                                  disabled: forbidden(\.forbidFps))
                        sliderRow(label: "码率",
                                  valueText: "\(stream.bitrateMbps) Mbps",
                                  value: Binding(get: { Double(stream.bitrateMbps) },
                                                 set: { v in container.settings.updateStream { $0.bitrateMbps = Int(v) } }),
                                  range: 1...40, steps: nil,
                                  disabled: forbidden(\.forbidBitrate))
                        Toggle(isOn: Binding(get: { stream.bwe },
                                             set: { v in container.settings.updateStream { $0.bwe = v } })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("动态码率 (BWE)").font(.system(size: 14))
                                Text("根据网络状况自动在最低/最高码率之间调节")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }.tint(AppColors.brand)
                        if stream.bwe {
                            sliderRow(label: "最低码率", valueText: "\(stream.minBitrateMbps) Mbps",
                                      value: Binding(get: { Double(stream.minBitrateMbps) },
                                                     set: { v in container.settings.updateStream { $0.minBitrateMbps = Int(v) } }),
                                      range: 1...40, steps: nil, disabled: false)
                            sliderRow(label: "最高码率", valueText: "\(stream.maxBitrateMbps) Mbps",
                                      value: Binding(get: { Double(stream.maxBitrateMbps) },
                                                     set: { v in container.settings.updateStream { $0.maxBitrateMbps = Int(v) } }),
                                      range: 1...40, steps: nil, disabled: false)
                        }
                        Toggle(isOn: Binding(get: { stream.audio },
                                             set: { v in container.settings.updateStream { $0.audio = v } })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("传输声音 (Opus)").font(.system(size: 14))
                                Text("关闭可节省约 128Kbps 带宽").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }.tint(AppColors.brand)
                        .disabled(forbidden(\.forbidAudio))
                        Toggle(isOn: Binding(get: { stream.powerOff },
                                             set: { v in container.settings.updateStream { $0.powerOff = v } })) {
                            Text("开启息屏连接").font(.system(size: 14))
                        }.tint(AppColors.brand)
                    }
                    .padding(14)
                }

                Text("设置在下次连接时生效；投屏中修改会自动快速重连。管理员禁止修改的项目以服务端配置为准。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            .padding(16)
        }
        .background(AppColors.background)
        .navigationTitle("画质与编码")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("恢复默认") { container.settings.resetStream() }
            }
        }
    }

    private func presetDesc(_ p: QualityPreset) -> String {
        switch p {
        case .original: return "原画 60fps/16M"
        default: return "\(p.label) \(p.maxSize)p/\(p.maxFps)/\(p.bitrateMbps)M"
        }
    }

    private var presetHint: String {
        "流畅 720p/30/2M · 标清 1080p/30/4M · 高清 1280p/60/6M · 超清 1920p/60/10M · 原画 60fps/16M"
    }

    private func snap(_ raw: Int, _ v: Double) -> Int {
        let target = Int(v)
        let options = [0, 480, 720, 1080, 1280, 1600, 1920, 2560]
        return options.min(by: { Swift.abs($0 - target) < Swift.abs($1 - target) }) ?? target
    }

    @ViewBuilder
    private func sliderRow(label: String, valueText: String, value: Binding<Double>,
                           range: ClosedRange<Double>, steps: [Int]?, disabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label + (disabled ? " 🔒" : "")).font(.system(size: 14))
                Spacer()
                Text(valueText).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            if disabled {
                ProgressView(value: value.wrappedValue, in: range).tint(.secondary)
            } else {
                Slider(value: value, in: range).tint(AppColors.brand)
            }
            if let steps, !steps.isEmpty {
                HStack {
                    ForEach(steps, id: \.self) { Text("\($0 == 0 ? "原始" : "\($0)")").font(.system(size: 9)).foregroundStyle(.tertiary) }
                }
            }
        }
    }
}

/// 偏好设置（对齐 Android AppSettingsScreen：外观 + 投屏开关 + 屏幕方向）
struct AppSettingsView: View {
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var scope: UserScope

    private var app: AppSettings { container.settings.app }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                SectionCard(title: "外观") {
                    VStack(alignment: .leading, spacing: 8) {
                        FlexibleChips(items: themeOptions) { item in
                            FilterChip(text: item.label, selected: app.themeMode == item.value) {
                                container.settings.updateApp { $0.themeMode = item.value }
                            }
                        }
                    }
                    .padding(14)
                }

                SectionCard(title: "投屏") {
                    VStack(spacing: 0) {
                        switchRow("显示虚拟导航键", "在投屏画面下方展示安卓三键导航", app.showNavBar) {
                            container.settings.updateApp { $0.showNavBar = $1 }
                        }
                        Divider().padding(.leading, 14)
                        switchRow("显示性能指标", "投屏时叠加显示帧率与延迟", app.showStats) {
                            container.settings.updateApp { $0.showStats = $1 }
                        }
                        Divider().padding(.leading, 14)
                        switchRow("投屏时保持亮屏", nil, app.keepScreenOn) {
                            container.settings.updateApp { $0.keepScreenOn = $1 }
                        }
                        Divider().padding(.leading, 14)
                        switchRow("触控振动反馈", nil, app.haptics) {
                            container.settings.updateApp { $0.haptics = $1 }
                        }
                        Divider().padding(.leading, 14)
                        switchRow("剪贴板双向同步", nil, app.clipboardSync) {
                            container.settings.updateApp { $0.clipboardSync = $1 }
                        }
                        Divider().padding(.leading, 14)
                        switchRow("断线自动重连", "最多自动重试 3 次", app.autoReconnect) { v in
                            container.settings.updateApp { $0.autoReconnect = v }
                            container.userScope?.sessionManager?.setAutoReconnect(v)
                        }
                    }
                }

                SectionCard(title: "屏幕方向") {
                    VStack(alignment: .leading, spacing: 8) {
                        FlexibleChips(items: orientationOptions) { item in
                            FilterChip(text: item.label, selected: app.orientationLock == item.value) {
                                container.settings.updateApp { $0.orientationLock = item.value }
                            }
                        }
                    }
                    .padding(14)
                }
            }
            .padding(16)
        }
        .background(AppColors.background)
        .navigationTitle("偏好设置")
    }

    private var themeOptions: [LabelOption] {
        [LabelOption(label: "跟随系统", value: .system),
         LabelOption(label: "浅色", value: .light),
         LabelOption(label: "深色", value: .dark)]
    }

    private var orientationOptions: [StrOption] {
        [StrOption(label: "跟随画面", value: "auto"),
         StrOption(label: "竖屏", value: "portrait"),
         StrOption(label: "横屏", value: "landscape"),
         StrOption(label: "跟随重力", value: "sensor")]
    }

    private func switchRow(_ title: String, _ subtitle: String?, _ value: Bool,
                           onChange: @escaping (Bool) -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14))
                if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            Spacer()
            Toggle("", isOn: Binding(get: { value }, set: onChange)).labelsHidden().tint(AppColors.brand)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

/// 安全与证书
struct CertificatesView: View {
    @State private var pins: [CertificatePinStore.PinnedCertificate] = []
    private let store = CertificatePinStore()
    @State private var removeTarget: CertificatePinStore.PinnedCertificate?

    var body: some View {
        Group {
            if pins.isEmpty {
                ScrollView {
                    EmptyStateView(icon: "lock.shield", title: "暂无已信任证书",
                                   message: "首次连接自签名服务器时确认信任，证书指纹会固定在这里")
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(pins) { pin in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(pin.endpointKey).font(.system(size: 14, weight: .semibold))
                                    Spacer()
                                    Button { removeTarget = pin } label: {
                                        Image(systemName: "trash").font(.system(size: 13)).foregroundStyle(AppColors.danger)
                                    }
                                }
                                if !pin.subject.isEmpty {
                                    Text(pin.subject).font(.system(size: 12)).foregroundStyle(.secondary)
                                }
                                Text(pin.sha256).font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary).lineLimit(2)
                                Text("信任于 \(Formatters.dateTime(pin.pinnedAt))")
                                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(AppColors.surface, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.black.opacity(0.06), lineWidth: 0.5))
                        }
                    }
                    .padding(16)
                }
            }
        }
        .background(AppColors.background)
        .navigationTitle("安全与证书")
        .onAppear { pins = store.load() }
        .confirmationDialog("移除证书", isPresented: Binding(get: { removeTarget != nil },
                                                           set: { if !$0 { removeTarget = nil } }),
                            titleVisibility: .visible) {
            Button("移除", role: .destructive) {
                guard let pin = removeTarget else { return }
                store.remove(endpointKey: pin.endpointKey)
                pins = store.load()
                removeTarget = nil
            }
        } message: {
            Text("移除 \(removeTarget?.endpointKey ?? "") 的固定指纹后，下次连接将重新弹出信任确认。")
        }
    }
}

/// 关于（对齐 Android AboutScreen）
struct AboutView: View {
    private let version = "0.4.5"

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                VStack(spacing: 8) {
                    if UIImage(named: "AppLogo") != nil {
                        Image("AppLogo").resizable().scaledToFit().frame(width: 72, height: 72)
                    } else {
                        Image(systemName: "cloud.play.fill")
                            .font(.system(size: 36)).foregroundStyle(AppColors.brand)
                            .frame(width: 72, height: 72)
                            .background(AppColors.brand.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))
                    }
                    Text("穿云投屏").font(.system(size: 20, weight: .bold))
                    Text("v\(version) (1) · ScrcpyOverWebRTC")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .padding(.vertical, 12)

                SectionCard(title: "版本信息") {
                    infoRow("版本", "v\(version) (1)")
                    Divider().padding(.leading, 14)
                    infoRow("技术架构", "WebRTC P2P · H.264 硬解 · Opus · DataChannel")
                }
                SectionCard(title: "链接与支持") {
                    infoRow("在线文档", "webrtc-phone.com/docs")
                    Divider().padding(.leading, 14)
                    infoRow("上游项目", "hqw700/ScrcpyOverWebRTC")
                }
                SectionCard(title: "安全说明") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("· 凭据使用 iOS Keychain 加密存储").font(.system(size: 12)).foregroundStyle(.secondary)
                        Text("· 仅信任系统 CA 或经确认固定的自签证书 SHA-256").font(.system(size: 12)).foregroundStyle(.secondary)
                        Text("· 媒体链路 DTLS-SRTP 端到端加密").font(.system(size: 12)).foregroundStyle(.secondary)
                        Text("· 卡密访客默认禁止终端与文件推送").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .padding(14)
                }
                SectionCard(title: "开源许可") {
                    infoRow("WebRTC", "BSD-3-Clause")
                    Divider().padding(.leading, 14)
                    infoRow("OkHttp（上游）", "Apache-2.0")
                }
            }
            .padding(16)
        }
        .background(AppColors.background)
        .navigationTitle("关于")
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 14))
            Spacer()
            Text(value).font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}
