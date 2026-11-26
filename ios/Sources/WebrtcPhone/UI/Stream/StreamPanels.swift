import SwiftUI
import UniformTypeIdentifiers

// MARK: - 面板枚举（对齐 Android Panel）

/// sheet 类面板（terminal 独立状态管理，不进 sheet）
enum StreamPanel: String, Identifiable {
    case tools, text, files, quality, info, apps
    var id: String { rawValue }
}

// MARK: - 设备切换抽屉（对齐 Android DeviceDrawer）

/// 投屏页侧边栏：设备列表，点击在线设备直接切换投屏目标。
/// 排序：当前设备置顶，其后在线（空闲优先），最后离线。
struct DeviceDrawerView: View {
    @ObservedObject var scope: UserScope
    let currentId: String
    let onSelect: (Device) -> Void
    let onClose: () -> Void
    let onRefresh: () -> Void

    @State private var query = ""

    private var shown: [Device] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return scope.devices.devices
            .filter { q.isEmpty || $0.id.lowercased().contains(q) || $0.info.title.lowercased().contains(q) }
            .sorted { a, b in
                if (a.id == currentId) != (b.id == currentId) { return a.id == currentId }
                if a.online != b.online { return a.online }
                if a.inUse != b.inUse { return !a.inUse }
                return a.id < b.id
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("切换设备").font(.headline)
                    Text("在线 \(scope.devices.devices.filter(\.online).count) / 共 \(scope.devices.devices.count)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { onRefresh() } label: { Image(systemName: "arrow.clockwise") }
                Button { onClose() } label: { Image(systemName: "xmark") }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                TextField("搜索设备 ID / 型号", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(10)
            .background(Color(.systemGray6), in: Capsule())
            .padding(.horizontal, 12).padding(.bottom, 8)

            if scope.devices.loading && scope.devices.devices.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if shown.isEmpty {
                Text(scope.devices.devices.isEmpty ? "暂无设备" : "没有匹配的设备")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(shown) { d in
                            DeviceDrawerItem(device: d,
                                             snapshot: scope.devices.snapshots[d.id]?.image,
                                             deviceTags: (scope.devices.tags.deviceTags[d.id] ?? [])
                                                 .compactMap { id in scope.devices.tags.tags.first { $0.id == id } },
                                             current: d.id == currentId) { onSelect(d) }
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(.systemBackground))
    }
}

private struct DeviceDrawerItem: View {
    let device: Device
    let snapshot: UIImage?
    let deviceTags: [Tag]
    let current: Bool
    let onClick: () -> Void

    private var statusText: String {
        if current { return "当前设备" }
        if !device.online { return "离线" }
        if device.inUse { return "使用中 \(device.clientCount)" }
        return "空闲"
    }
    private var statusColor: Color {
        if current { return AppColors.brand }
        if !device.online { return AppColors.offline }
        if device.inUse { return AppColors.busy }
        return AppColors.online
    }

    var body: some View {
        Button(action: onClick) {
            HStack(spacing: 12) {
                // 缩略图（竖屏比例）
                ZStack {
                    Rectangle().fill(AppColors.screenBackdrop)
                    if let snapshot {
                        Image(uiImage: snapshot).resizable().scaledToFill()
                    } else {
                        Image(systemName: device.online ? "iphone" : "cloud.slash")
                            .font(.system(size: 20))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                }
                .frame(width: 44, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle().fill(statusColor).frame(width: 7, height: 7)
                        Text(device.displayName).font(.subheadline.weight(.medium)).lineLimit(1)
                    }
                    if !device.info.title.isEmpty {
                        Text(device.info.title + (device.info.androidVersion.isEmpty ? "" : " · Android \(device.info.androidVersion)"))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    HStack(spacing: 6) {
                        Text(statusText)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(statusColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(statusColor)
                        ForEach(deviceTags.prefix(2)) { tag in
                            Text(tag.name)
                                .font(.system(size: 10))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color(hex: tag.color).opacity(0.18), in: Capsule())
                                .foregroundStyle(Color(hex: tag.color))
                        }
                    }
                }
                Spacer()
            }
            .padding(8)
            .background(current ? AppColors.brand.opacity(0.12) : AppColors.surfaceContainerHigh,
                        in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(current ? AppColors.brand : .clear, lineWidth: 1.5)
            )
            .opacity(device.online || current ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!device.online || current)
    }
}

// MARK: - 工具项模型（对齐 Android ToolItem）

struct ToolItem: Identifiable {
    let label: String
    let icon: String
    var enabled = true
    var active = false
    var onLongClick: (() -> Void)? = nil
    let onClick: () -> Void
    var id: String { label }
}

// MARK: - 工具面板（对齐 Android ToolGrid + toolSections）

struct ToolGridSheet: View {
    let sections: [(String, [ToolItem])]
    let deviceName: String
    let transportLabel: String

    private let columns = Array(repeating: GridItem(.flexible()), count: 5)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(deviceName).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Text(transportLabel)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(AppColors.online.opacity(0.15), in: Capsule())
                        .foregroundStyle(AppColors.online)
                }
                .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 4)

                ForEach(sections.indices, id: \.self) { i in
                    let (title, items) = sections[i]
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 20).padding(.top, 12).padding(.bottom, 4)
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(items) { item in ToolButton(item: item) }
                        // 末行补位，保持左对齐
                        ForEach(0..<(5 - items.count % 5) % 5, id: \.self) { _ in Color.clear }
                    }
                    .padding(.horizontal, 8)
                }
                Color.clear.frame(height: 16)
            }
        }
    }
}

private struct ToolButton: View {
    let item: ToolItem
    let alpha: Double

    init(item: ToolItem) {
        self.item = item
        self.alpha = item.enabled ? 1 : 0.35
    }

    var body: some View {
        Button {
            if item.enabled { item.onClick() }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: item.icon)
                    .font(.system(size: 19))
                    .foregroundStyle(item.active ? Color.white : Color.primary.opacity(alpha))
                    .frame(width: 46, height: 46)
                    .background(item.active ? AppColors.brand : AppColors.surfaceContainerHigh,
                                in: RoundedRectangle(cornerRadius: 14))
                Text(item.label)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .foregroundStyle(Color.primary.opacity(alpha))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(!item.enabled)
        .onLongPressGesture(minimumDuration: 0.5) {
            if item.enabled { item.onLongClick?() }
        }
    }
}

// MARK: - 文本下发面板（对齐 Android TextSendPanel）

struct TextSendSheet: View {
    let onSend: (String, Bool) -> Void
    let onSendClipboard: () -> Void
    let onSendQuickText: (QuickText) -> Void
    let onNewQuickText: () -> Void
    @ObservedObject var quickTexts: QuickTextRepository
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var enter = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("要发送的文本", text: $text, axis: .vertical)
                .lineLimit(2...6)
                .padding(10)
                .background(AppColors.surfaceContainerHigh, in: RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 16)
                .padding(.top, 12)

            HStack {
                Text("发送后回车").font(.subheadline)
                Toggle("", isOn: $enter).labelsHidden().scaleEffect(0.85)
                Spacer()
                Button("发送剪贴板") { onSendClipboard() }
                Button {
                    onSend(text, enter)
                    text = ""
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "paperplane.fill").font(.caption)
                        Text("发送")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.isEmpty)
            }
            .padding(.horizontal, 16)

            HStack {
                Text("快捷文本").font(.subheadline.weight(.medium))
                Spacer()
                Button("新建") { onNewQuickText() }
            }
            .padding(.horizontal, 16)

            if quickTexts.items.isEmpty {
                Text("暂无模板").font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(quickTexts.items) { q in
                        Button { onSendQuickText(q) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "text.alignleft").foregroundStyle(AppColors.brand)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(q.title).font(.subheadline).lineLimit(1)
                                    Text(q.content).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if q.autoEnter { Text("↵").foregroundStyle(AppColors.brand) }
                            }
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .frame(height: 220)
        }
        .padding(.bottom, 16)
    }
}

// MARK: - 画质面板（对齐 Android QualityPanel + StreamQualityEditor）

struct QualitySheet: View {
    @ObservedObject var settings: SettingsRepository
    let onApply: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft = StreamSettings()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("预设").font(.subheadline.weight(.medium))
                FlowChips(items: QualityPreset.allCases.map { ($0.label, $0 == draft.preset) }) { p in
                    if let preset = QualityPreset.allCases.first(where: { $0.label == p }) {
                        draft = draft.withPreset(preset)
                    }
                }

                if draft.preset == .custom {
                    Stepper("最大分辨率边长 \(draft.maxSize == 0 ? "原画" : "\(draft.maxSize)")") {
                        draft.maxSize = min(max(draft.maxSize + 120, 0), 4096)
                    }
                    Stepper("帧率 \(draft.maxFps) fps") {
                        draft.maxFps = min(max(draft.maxFps + 5, 0), 144)
                    }
                    Stepper("目标码率 \(draft.bitrateMbps) Mbps") {
                        draft.bitrateMbps = min(max(draft.bitrateMbps + 1, 1), 100)
                    }
                }

                Toggle("带宽自适应（BWE）", isOn: $draft.bwe)

                HStack {
                    Spacer()
                    Button("还原") { draft = settings.stream }
                    Button("应用并重连") {
                        settings.updateStream { $0 = draft }
                        onApply()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft == settings.stream)
                }
            }
            .padding(16)
        }
        .onAppear { draft = settings.stream }
    }
}

/// 简易流式标签选择行
private struct FlowChips: View {
    let items: [(String, Bool)]
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.0) { label, selected in
                    Button { onSelect(label) } label: {
                        Text(label)
                            .font(.system(size: 13))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(selected ? AppColors.brand : AppColors.surfaceContainerHigh,
                                        in: Capsule())
                            .foregroundStyle(selected ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - 连接信息面板（对齐 Android InfoPanel）

struct InfoSheet: View {
    let deviceName: String
    let deviceId: String
    let server: String
    let isGuest: Bool
    let videoSize: (Int, Int)?
    let stats: StreamStats

    private var bitrate: String {
        let bps = stats.bitrateBps
        if bps <= 0 { return "-" }
        if bps >= 1_000_000 { return String(format: "%.1f Mbps", Double(bps) / 1_000_000) }
        if bps >= 1_000 { return String(format: "%.0f Kbps", Double(bps) / 1_000) }
        return "\(bps) bps"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows, id: \.0) { row in
                HStack(alignment: .top) {
                    Text(row.0).font(.caption).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                    Text(row.1).font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 5)
            }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 20)
    }

    private var rows: [(String, String)] {
        let network = [stats.networkLabel, stats.protocolName.uppercased()]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        return [
            ("设备", "\(deviceName) (\(deviceId))"),
            ("服务器", server),
            ("身份", isGuest ? "卡密访客" : "登录用户"),
            ("画面", videoSize.map { "\($0.0) × \($0.1)" } ?? "-"),
            ("编码", "\(stats.codec.isEmpty ? "-" : stats.codec) \(stats.decoder)".trimmingCharacters(in: .whitespaces)),
            ("网络", network.isEmpty ? "-" : network),
            ("延迟", stats.latencyMs > 0 ? "\(stats.latencyMs) ms (RTT \(stats.rttMs) ms)" : "-"),
            ("帧率", "\(stats.fps) fps"),
            ("码率", bitrate),
            ("丢帧", "\(stats.framesDropped)"),
        ]
    }
}

// MARK: - 应用安装面板（对齐 Android AppsPanel）

struct AppsSheet: View {
    let client: FileTransferClient?
    let onOpenFiles: () -> Void
    let toast: (String) -> Void
    let allowFileTx: Bool
    @State private var showImporter = false

    var body: some View {
        VStack(spacing: 8) {
            AppActionRow(icon: "square.and.arrow.down", title: "从本机选择 APK 安装",
                         sub: "上传到云手机并自动安装", enabled: allowFileTx && client != nil) {
                showImporter = true
            }
            AppActionRow(icon: "folder", title: "从云手机文件安装",
                         sub: "浏览云手机存储，点选 APK 安装", enabled: true, onClick: onOpenFiles)
            AppActionRow(icon: "iphone", title: "从本机已安装应用选择",
                         sub: "即将支持：直接提取本机应用推送到云手机", enabled: false) {}
            AppActionRow(icon: "square.grid.2x2", title: "云手机应用管理",
                         sub: "即将支持：查看/卸载/清除数据", enabled: false) {}
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.apk, .data]) { result in
            guard let url = try? result.get(), let client else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let name = url.lastPathComponent.lowercased().hasSuffix(".apk")
                ? url.lastPathComponent : url.lastPathComponent + ".apk"
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0
            toast("正在上传 \(name)，完成后自动安装")
            let dest = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
            try? FileManager.default.copyItem(at: url, to: dest)
            Task {
                do {
                    try await client.upload(src: dest, name: name,
                                            remotePath: "/data/local/tmp/\(name)",
                                            size: size, installAfter: true)
                } catch {
                    toast("上传失败：\(error.localizedDescription)")
                }
                try? FileManager.default.removeItem(at: dest)
                onOpenFiles()
            }
        }
    }
}

private struct AppActionRow: View {
    let icon: String
    let title: String
    let sub: String
    let enabled: Bool
    let onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.title3)
                    .foregroundStyle(enabled ? AppColors.brand : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body).foregroundStyle(enabled ? .primary : .secondary)
                    Text(sub).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(14)
            .background(AppColors.surfaceContainerHigh, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

extension UTType {
    static var apk: UTType {
        UTType(filenameExtension: "apk") ?? .data
    }
}

// MARK: - 终端底部面板（对齐 Android TerminalPanel：底部 45% 高度）

struct TerminalBottomPanel: View {
    let channel: TerminalChannel
    let onClose: () -> Void
    @State private var lines: [String] = []
    @State private var input = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("终端").font(.subheadline.weight(.medium))
                Spacer()
                Button { channel.clear(); lines.removeAll() } label: { Image(systemName: "trash") }
                Button { focused = true } label: { Image(systemName: "keyboard") }
                Button { onClose() } label: { Image(systemName: "xmark") }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.bar)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(lines.indices, id: \.self) { i in
                            Text(lines[i])
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                    }
                    .padding(8)
                }
                .background(Color.black)
                .onChange(of: lines.count) { _ in
                    if let last = lines.indices.last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }

            Divider()

            HStack {
                TextField("输入命令", text: $input)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .focused($focused)
                    .onSubmit { send() }
                Button("发送") { send() }
            }
            .padding(10)
            .background(.thinMaterial)
        }
        .onAppear {
            _ = channel.start(rows: 18, cols: 80)
            channel.observe { data in
                let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                let result = channel.append(data)
                DispatchQueue.main.async {
                    if result.reset { lines.removeAll() }
                    // 多行：先并入末行再按换行拆分
                    let combined = (lines.last ?? "") + text
                    if !combined.contains("\n") {
                        if lines.isEmpty { lines.append("") }
                        lines[lines.count - 1] = combined
                    } else {
                        let parts = combined.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                        if !lines.isEmpty { lines.removeLast() }
                        lines.append(contentsOf: parts)
                    }
                    if lines.count > 800 { lines.removeFirst(lines.count - 800) }
                }
            }
            focused = true
        }
    }

    private func send() {
        guard !input.isEmpty else { return }
        _ = channel.write((input + "\n").data(using: .utf8) ?? Data())
        input = ""
    }
}

// MARK: - 连接覆盖层（对齐 Android ConnectingOverlay / FailedOverlay）

struct ConnectingOverlay: View {
    let phaseLabel: String
    let deviceName: String
    let onExit: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 8) {
                Image(systemName: "cloud.and.arrow.down")
                    .font(.system(size: 44))
                    .foregroundStyle(AppColors.brand)
                    .symbolRenderingMode(.hierarchical)
                ProgressView().tint(.white)
                Text(deviceName).font(.headline).foregroundStyle(.white)
                Text(phaseLabel).font(.caption).foregroundStyle(.white.opacity(0.7))
                Spacer().frame(height: 24)
                Button("取消") { onExit() }
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
            .padding(32)
        }
    }
}

struct FailedOverlay: View {
    let message: String
    let retryable: Bool
    let onRetry: () -> Void
    let onExit: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.8).ignoresSafeArea()
            VStack(spacing: 8) {
                Text("连接已断开").font(.title3.weight(.semibold)).foregroundStyle(.white)
                Text(message).font(.subheadline).foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                Spacer().frame(height: 24)
                HStack(spacing: 12) {
                    Button("退出") { onExit() }
                        .buttonStyle(.bordered)
                        .tint(.white)
                    if retryable {
                        Button("重新连接") { onRetry() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(32)
        }
    }
}

// MARK: - Toast

struct StreamToast: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.white)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Color.black.opacity(0.75), in: Capsule())
            .transition(.opacity)
    }
}
