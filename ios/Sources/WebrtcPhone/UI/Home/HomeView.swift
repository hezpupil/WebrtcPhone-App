import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var scope: UserScope
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0
    /// 独立投屏页状态（对齐 Android StreamActivity）：置于 TabView 之上的全屏层，
    /// 彻底覆盖底部导航栏，只能通过投屏页内的返回/结束投屏退出
    @State private var streaming: Device?
    @State private var streamTransport: StreamTransport = .webrtc
    @State private var streamCamera: CameraParams?

    var body: some View {
        ZStack {
            TabView(selection: $tab) {
                NavigationStack {
                    DevicesTab(
                        onStream: { d in
                            streamTransport = .webrtc
                            streamCamera = nil
                            streaming = d
                        },
                        onStreamWs: { d in
                            streamTransport = .websocket
                            streamCamera = nil
                            streaming = d
                        },
                        onStreamCamera: { d, p in
                            streamTransport = .webrtc
                            streamCamera = p
                            streaming = d
                        })
                }
                .tabItem { Label("设备", systemImage: "rectangle.grid.2x2") }.tag(0)
                NavigationStack { ManageTab() }
                    .tabItem { Label("管理", systemImage: "slider.horizontal.3") }.tag(1)
                NavigationStack { MeTab(onGoManage: { tab = 1 }) }
                    .tabItem { Label("我的", systemImage: "person.circle") }.tag(2)
            }
            .onChange(of: tab) { _ in
                scope.devices.setActive(tab == 0 && streaming == nil)
            }
            .onAppear { scope.devices.setActive(streaming == nil) }

            if let device = streaming {
                StreamView(device: device, scope: scope, container: container,
                           transport: streamTransport, cameraParams: streamCamera) {
                    streaming = nil
                }
                .transition(.opacity)
            }
        }
        .onChange(of: scenePhase) { phase in
            // App 层只负责进后台关轮询（WebrtcPhoneApp）；回前台必须在这里恢复，
            // 否则切后台回来后轮询与 WS 全停，设备列表永远不再自动刷新。
            // 投屏中不恢复（StreamView 已主动关掉轮询，避免与视频流抢带宽）
            if phase == .active && tab == 0 && streaming == nil { scope.devices.setActive(true) }
        }
    }
}

// MARK: - 设备大盘
struct DevicesTab: View {
    /// 连接并投屏回调（投屏页由 HomeView 顶层全屏承载，覆盖 TabBar）
    let onStream: (Device) -> Void
    /// WS 中转投屏（WebSocket H.264 裸流，VideoToolbox 解码）
    let onStreamWs: (Device) -> Void
    /// 摄像头监控投屏
    let onStreamCamera: (Device, CameraParams) -> Void
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var scope: UserScope
    @State private var search = ""
    @State private var statusFilter = 0 // 0 全部 / 1 在线 / 2 使用中 / 3 离线
    @State private var selected: Device?
    @State private var shareDevice: Device?

    private enum StatusFilter: String, CaseIterable {
        case all = "全部", online = "在线", inUse = "使用中", offline = "离线"
    }

    private var allDevices: [Device] { scope.devices.devices }

    private var filtered: [Device] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        var base = allDevices
        switch statusFilter {
        case 1: base = base.filter { $0.online }
        case 2: base = base.filter { $0.online && $0.inUse }
        case 3: base = base.filter { !$0.online }
        default: break
        }
        if !q.isEmpty {
            let tagIds = scope.devices.tags.tags.filter { $0.name.lowercased().contains(q) }.map { $0.id }
            base = base.filter {
                $0.displayName.lowercased().contains(q) || $0.id.lowercased().contains(q)
                    || $0.info.title.lowercased().contains(q)
                    || !Set(tagIds).isDisjoint(with: scope.devices.tags.deviceTags[$0.id] ?? [])
            }
        }
        return base.sorted { a, b in
            if a.online != b.online { return a.online }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
    }

    private func tags(for device: Device) -> [Tag] {
        (scope.devices.tags.deviceTags[device.id] ?? []).compactMap { id in
            scope.devices.tags.tags.first { $0.id == id }
        }
    }

    private var columns: [GridItem] {
        let n = container.settings.app.gridColumns
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: n)
    }

    var body: some View {
        mainTab
    }

    private var mainTab: some View {
        VStack(spacing: 0) {
            // 筛选条（对齐 Android FilterRow）
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(StatusFilter.allCases.enumerated()), id: \.offset) { idx, sf in
                        let count: Int = {
                            switch sf {
                            case .all: return allDevices.count
                            case .online: return allDevices.filter { $0.online }.count
                            case .inUse: return allDevices.filter { $0.online && $0.inUse }.count
                            case .offline: return allDevices.filter { !$0.online }.count
                            }
                        }()
                        Button {
                            withAnimation { statusFilter = idx }
                        } label: {
                            Text("\(sf.rawValue) \(count)")
                                .font(.system(size: 13))
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(statusFilter == idx ? AppColors.brand : AppColors.surfaceContainerHigh,
                                            in: Capsule())
                                .foregroundStyle(statusFilter == idx ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
            }

            Group {
            if scope.devices.loading && scope.devices.devices.isEmpty {
                ProgressView("加载设备…")
            } else if !filtered.isEmpty {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(filtered) { device in
                            DeviceCard(device: device,
                                       snapshot: scope.devices.snapshots[device.id]?.image,
                                       tags: tags(for: device),
                                       compact: container.settings.app.gridColumns >= 3,
                                       onTap: {
                                           // 对齐 Android open()：在线直接连接，离线进长按菜单
                                           if device.online {
                                               onStream(device)
                                           } else {
                                               selected = device
                                           }
                                       },
                                       onLongPress: { selected = device })
                        }
                    }
                    .padding(12)
                }
            } else if let error = scope.devices.error, scope.devices.devices.isEmpty {
                // 对齐 Android：加载失败且无数据时显示明确错误 + 重试
                VStack(spacing: 12) {
                    Image(systemName: "cloud.slash").font(.largeTitle).foregroundStyle(.secondary)
                    Text("无法加载设备").font(.headline)
                    Text(error.localizedDescription).font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).padding(.horizontal, 32)
                    Button("重试") { Task { await scope.devices.refresh() } }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "iphone.slash").font(.largeTitle).foregroundStyle(.secondary)
                    Text(search.isEmpty ? "暂无设备" : "无匹配设备").foregroundStyle(.secondary)
                    if search.isEmpty {
                        Text("请联系管理员分配设备，或在设备上部署 Agent")
                            .font(.caption2).foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center).padding(.horizontal, 32)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("设备")
        .searchable(text: $search, prompt: "搜索设备 ID / 型号 / 标签")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { Task { await scope.devices.refresh() } } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    NavigationLink { QuickTextView() } label: {
                        Label("快捷文本", systemImage: "text.badge.plus")
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        // 派生 isPresented（同 StreamView）：item 模式下 dismiss()/下滑不清空绑定，
        // 点"连接并投屏"后 sheet 仍挂在 StreamView 底下反复重弹
        .sheet(isPresented: Binding(
            get: { selected != nil },
            set: { if !$0 { selected = nil } }
        )) {
            if let device = selected {
                DeviceActionsSheet(device: device,
                                   onStream: {
                                       selected = nil
                                       onStream(device)
                                   },
                                   onStreamWs: { onStreamWs(device) },
                                   onStreamCamera: { p in
                                       selected = nil
                                       onStreamCamera(device, p)
                                   },
                                   onShare: { shareDevice = device })
            }
        }
        // 分享 / 生成卡密：预选该设备进入创建表单（对齐 Android Routes.shares(d.id, create=true)）
        .sheet(isPresented: Binding(
            get: { shareDevice != nil },
            set: { if !$0 { shareDevice = nil } }
        )) {
            if let device = shareDevice {
                NavigationStack {
                    SharesView(presetDeviceId: device.id)
                }
            }
        }
        .refreshable { await scope.devices.refresh() }
    }
}

struct DeviceCard: View {
    let device: Device
    let snapshot: UIImage?
    var tags: [Tag] = []
    var compact = false
    var onTap: () -> Void = {}
    var onLongPress: () -> Void = {}

    /// 画面比例：优先快照真实比例，回退设备屏幕比例，缺省 9:19.5（对齐 Android DeviceCard）
    private var ratio: CGFloat {
        var r: CGFloat
        if let image = snapshot, image.size.width > 0, image.size.height > 0 {
            r = image.size.width / image.size.height
        } else if let display = device.info.displays.first, display.width > 0, display.height > 0 {
            r = CGFloat(display.width) / CGFloat(display.height)
        } else {
            r = 9.0 / 19.5
        }
        return min(max(r, 0.4), 2.5)
    }

    private var statusText: String {
        if !device.online { return "离线" }
        if device.inUse { return compact ? "使用中" : "使用中 \(device.clientCount)" }
        return "在线"
    }
    private var statusColor: Color {
        if !device.online { return AppColors.offline }
        if device.inUse { return AppColors.busy }
        return AppColors.online
    }

    private var subText: String {
        if !device.alias.isEmpty {
            return device.id + (device.info.title.isEmpty ? "" : " · \(device.info.title)")
        } else if !device.info.title.isEmpty {
            return device.info.title + (device.info.androidVersion.isEmpty ? "" : " · Android \(device.info.androidVersion)")
        }
        return ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                // 深色画面区（对齐 Android Box background #111318 + aspectRatio）
                Rectangle().fill(AppColors.screenBackdrop)
                    .aspectRatio(ratio, contentMode: .fit)

                if device.info.projectionOnDemand {
                    Text("在线协助\n未开启无人值守时需在手机上确认")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let image = snapshot {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .saturation(device.online && !device.screenOff ? 1 : 0)
                        .opacity(device.online ? 1 : 0.45)
                } else {
                    Image(systemName: device.online ? "phone" : "cloud.slash")
                        .font(.system(size: compact ? 28 : 40))
                        .foregroundStyle(.white.opacity(0.25))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if device.online && device.screenOff {
                    Image(systemName: "moon").font(.system(size: 28))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // 顶部状态药丸
                HStack(spacing: 4) {
                    StatusPill(text: statusText, color: statusColor, filled: true)
                    if !compact, let rem = device.myLeaseRemainingSeconds {
                        StatusPill(text: leaseText(rem), color: rem < 86_400 ? AppColors.danger : .white,
                                   filled: rem < 86_400)
                    }
                }
                .padding(6)

                // 底部渐变信息区
                VStack(alignment: .leading, spacing: 3) {
                    if !tags.isEmpty {
                        if compact {
                            HStack(spacing: 3) {
                                ForEach(tags.prefix(4)) { tag in
                                    Circle().fill(Color(hex: tag.color)).frame(width: 7, height: 7)
                                }
                            }
                        } else {
                            HStack(spacing: 4) {
                                ForEach(tags.prefix(3)) { tag in
                                    StatusPill(text: tag.name, color: Color(hex: tag.color), filled: true)
                                }
                            }
                        }
                    }
                    Text(device.displayName)
                        .font(compact ? .system(size: 12, weight: .medium) : .system(size: 14, weight: .medium))
                        .foregroundStyle(.white).lineLimit(1)
                    if !compact && !subText.isEmpty {
                        HStack(spacing: 4) {
                            Text(subText).font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                            if let holder = device.leaseHolder {
                                Image(systemName: "timer").font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.7))
                                Text(holder).font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .clipped()
            .cornerRadius(14)
        }
        .background(AppColors.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.black.opacity(0.06), lineWidth: 0.5))
        // 对齐 Android combinedClickable：点击连接，长按弹操作菜单（带震动）
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture { onTap() }
        .onLongPressGesture(minimumDuration: 0.45) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onLongPress()
        }
    }

    private func leaseText(_ rem: Int64) -> String {
        let h = rem / 3600
        let m = (rem % 3600) / 60
        if h >= 24 { return "\(h / 24)天" }
        if h > 0 { return "\(h)小时" }
        return "\(m)分"
    }
}

struct DeviceActionsSheet: View {
    let device: Device
    var onStream: () -> Void
    var onStreamWs: () -> Void = {}
    var onStreamCamera: (CameraParams) -> Void = { _ in }
    var onShare: () -> Void = {}
    @EnvironmentObject private var scope: UserScope
    @Environment(\.dismiss) private var dismiss
    @State private var showInfo = false
    @State private var showDeleteConfirm = false
    @State private var showLease = false
    @State private var showTags = false
    @State private var showCamera = false
    @State private var showRename = false
    @State private var aliasInput = ""

    private var isAdmin: Bool { scope.devices.isAdmin }
    private var canShare: Bool {
        isAdmin && scope.devices.me?.policy.forbidShare != true
    }
    /// 设备开租副标题（对齐 Android DeviceActionSheet leaseSub）
    private var leaseSub: String {
        if let holder = device.leaseHolder {
            let rem = device.myLeaseRemainingSeconds.map { "，剩 \(Formatters.duration($0))" } ?? ""
            return "已租给 \(holder)\(rem)"
        }
        return "当前未出租，点击为用户开租"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 头部：状态点 + 名称 + 副标题（对齐 Android ModalBottomSheet 头）
            HStack(spacing: 8) {
                Circle()
                    .fill(device.online ? AppColors.online : AppColors.offline)
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.displayName).font(.system(size: 16, weight: .semibold))
                    let sub = device.alias.isEmpty
                        ? device.info.title
                        : "ID: \(device.id)" + (device.info.title.isEmpty ? "" : " · \(device.info.title)")
                    if !sub.isEmpty {
                        Text(sub).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 0) {
                ActionRow(icon: "rectangle.on.rectangle",
                          title: device.info.projectionOnDemand ? "请求投屏" : "进入投屏",
                          enabled: device.online) {
                    dismiss(); onStream()
                }
                if !device.info.projectionOnDemand {
                    ActionRow(icon: "bolt", title: "WS 模式投屏",
                              sub: "WebSocket 中转，免 P2P 穿透（视频+直控）",
                              enabled: device.online) {
                        dismiss(); onStreamWs()
                    }
                    ActionRow(icon: "video", title: "摄像头监控",
                              sub: "使用云手机摄像头作为画面，含环境音",
                              enabled: device.online) {
                        showCamera = true
                    }
                }
                if canShare {
                    ActionRow(icon: "square.and.arrow.up", title: "分享 / 生成卡密") {
                        dismiss(); onShare()
                    }
                }
                ActionRow(icon: "pencil",
                          title: "重命名",
                          sub: device.alias.isEmpty ? "点击为设备设置自定义名称" : "当前: \(device.alias)") {
                    aliasInput = device.alias
                    showRename = true
                }
                if isAdmin {
                    ActionRow(icon: "key", title: "设备开租 / 租约管理", sub: leaseSub) {
                        showLease = true
                    }
                    ActionRow(icon: "tag", title: "设置标签") {
                        showTags = true
                    }
                }
                ActionRow(icon: "info.circle", title: "设备信息") { showInfo.toggle() }
                if showInfo { DeviceInfoBlock(device: device) }
                if isAdmin && !device.online {
                    Divider().padding(.vertical, 4)
                    ActionRow(icon: "trash", title: "删除设备档案", tint: AppColors.danger) {
                        showDeleteConfirm = true
                    }
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.surface)
        .presentationDetents([.medium, .large])
        .onAppear { aliasInput = device.alias }
        // 设备开租与租约管理（复用 ManageViews 的 1:1 实现）
        .sheet(isPresented: $showLease) {
            DeviceLeaseSheet(device: device).environmentObject(scope)
        }
        // 设备标签多选（对齐 Android DeviceTagSheet）
        .sheet(isPresented: $showTags) {
            DeviceTagSheet(deviceId: device.id,
                           selected: (scope.devices.tags.deviceTags[device.id] ?? []).filter { tagId in
                               scope.devices.tags.tags.contains { $0.id == tagId }
                           },
                           onManageTags: { showTags = false },
                           onSave: { ids in
                               showTags = false
                               Task { try? await scope.devices.setDeviceTags(device.id, ids) }
                           })
                .environmentObject(scope)
        }
        // 摄像头监控参数选择（对齐 Android CameraPickerSheet）
        .sheet(isPresented: $showCamera) {
            CameraPickerSheet(device: device) { p in
                showCamera = false
                dismiss()
                onStreamCamera(p)
            }
        }
        // 重命名对话框（对齐 Android AlertDialog + OutlinedTextField）
        .alert("重命名设备", isPresented: $showRename) {
            TextField(device.id, text: $aliasInput)
            Button("确定") {
                Task { try? await scope.devices.setDeviceAlias(device.id, alias: aliasInput.trimmingCharacters(in: .whitespaces)) }
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请输入新的设备名称，留空则恢复默认显示 ID：")
        }
        // 删除确认（对齐 Android ConfirmDialog destructive）
        .alert("删除设备", isPresented: $showDeleteConfirm) {
            Button("删除", role: .destructive) {
                Task { try? await scope.devices.deleteDevice(device.id) }
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除离线设备 \(device.id) 的档案，设备重新上线后会自动重新注册。")
        }
    }
}

/// 弹层操作行（对齐 Android SettingRow：图标 + 标题 + 副标题 + 禁用态）
struct ActionRow: View {
    let icon: String
    let title: String
    var sub: String? = nil
    var enabled = true
    var tint: Color = .primary
    var onClick: () -> Void = {}

    var body: some View {
        Button {
            if enabled { onClick() }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 17))
                    .foregroundStyle(enabled ? tint : Color.secondary.opacity(0.5))
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15))
                        .foregroundStyle(enabled ? tint : Color.primary.opacity(0.4))
                    if let sub {
                        Text(sub)
                            .font(.system(size: 12))
                            .foregroundStyle(enabled ? Color.secondary : Color.secondary.opacity(0.5))
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// 设备信息块（对齐 Android DeviceInfoBlock，行一个不漏）
struct DeviceInfoBlock: View {
    let device: Device

    var body: some View {
        let i = device.info
        let rows: [(String, String)] = [
            ("品牌型号", i.title.isEmpty ? "-" : i.title),
            ("系统", i.androidVersion.isEmpty ? "-" : "Android \(i.androidVersion) (SDK \(i.sdkInt))"),
            ("分辨率", i.primaryDisplay.map { "\($0.width) × \($0.height)" } ?? "-"),
            ("架构", i.cpuAbi.isEmpty ? "-" : i.cpuAbi),
            ("内存", i.memTotalMb > 0 ? Formatters.bytes(i.memTotalMb * 1024 * 1024) : "-"),
            ("Agent", i.agentVersion.isEmpty ? "-" : i.agentVersion),
            ("摄像头", i.cameras.isEmpty ? "未检测到" : i.cameras.map { $0.name.isEmpty ? $0.id : $0.name }.joined(separator: "、")),
            ("最后在线", device.lastSeen.map { Formatters.dateTime($0) } ?? "-"),
            ("租约剩余", device.myLeaseRemainingSeconds.map { Formatters.duration($0) } ?? "-"),
            ("租约用户", device.leaseHolder ?? "-"),
            ("接入者", device.clients.isEmpty ? "-" : device.clients.map { c in
                c.name.isEmpty ? (c.count > 1 ? "\(c.count) 人" : "1 人") : c.name
            }.joined(separator: "、")),
        ]
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top) {
                    Text(row.0)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .leading)
                    Text(row.1)
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 3)
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 4)
    }
}

// MARK: - 摄像头监控参数（1:1 对齐 Android DeviceSheets.kt CameraPickerSheet）

struct LensOption: Equatable {
    let label: String
    let lens: CameraLens
}

func lensOptions(_ d: Device) -> [LensOption] {
    let detected = d.info.cameras
    if !detected.isEmpty {
        return detected.map { c in
            let label: String
            if c.facing == "front" { label = "前置" }
            else if c.facing == "external" { label = "外接" }
            else if c.zoom < 0.9 { label = String(format: "广角 %.1fx", c.zoom) }
            else if c.zoom > 1.5 { label = String(format: "长焦 %.1fx", c.zoom) }
            else { label = "主摄 1x" }
            return LensOption(label: label, lens: c)
        }
    }
    // 未上报镜头时的兜底：多摄统一走 Camera 0 + 硬件 zoom（不传不存在的镜头 id）
    return [
        LensOption(label: "主摄 1x", lens: CameraLens(id: "0", facing: "back", type: "main", name: "主摄", zoom: 1.0)),
        LensOption(label: "广角 0.5x", lens: CameraLens(id: "0", facing: "back", type: "ultra_wide", name: "广角", zoom: 0.5)),
        LensOption(label: "长焦 5x", lens: CameraLens(id: "0", facing: "back", type: "telephoto", name: "长焦", zoom: 5.0)),
        LensOption(label: "前置", lens: CameraLens(id: "1", facing: "front", type: "front", name: "前置", zoom: 1.0)),
    ]
}

let CameraResolutions: [(String, String)] = [("640x480", "480P"), ("1280x720", "720P"),
                                             ("1920x1080", "1080P"), ("3840x2160", "4K")]

/// 摄像头监控参数选择（镜头 / 分辨率 / 帧率 / 环境音）
struct CameraPickerSheet: View {
    let device: Device
    let onStart: (CameraParams) -> Void

    @State private var lenses: [LensOption] = []
    @State private var lensIdx = 0
    @State private var resIdx = 2
    @State private var fps = 30
    @State private var mic = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("摄像头监控 · \(device.displayName)")
                .font(.system(size: 16, weight: .semibold))
            Text("镜头").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            SelChips(options: lenses.map(\.label), selected: lensIdx) { lensIdx = $0 }
            Text("分辨率").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            SelChips(options: CameraResolutions.map(\.1), selected: resIdx) { resIdx = $0 }
            Text("帧率").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            SelChips(options: ["15 fps", "30 fps", "60 fps"],
                     selected: [15, 30, 60].firstIndex(of: fps) ?? 1) { idx in
                fps = [15, 30, 60][idx]
            }
            HStack {
                Text("采集环境音（设备麦克风）").font(.system(size: 14))
                Spacer()
                Toggle("", isOn: $mic).labelsHidden().tint(AppColors.brand)
            }
            Button {
                let c = lenses[lensIdx].lens
                onStart(CameraParams(facing: c.facing, cameraId: c.id,
                                     size: CameraResolutions[resIdx].0,
                                     fps: fps, zoom: c.zoom, micAudio: mic))
            } label: {
                Text("开始监控")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity).frame(height: 46)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppColors.brand)
        }
        .padding(.horizontal, 20).padding(.vertical, 20)
        .presentationDetents([.medium])
        .onAppear {
            lenses = lensOptions(device)
            lensIdx = 0
        }
    }
}

/// 横向 chip 组（带选中态）
struct SelChips: View {
    let options: [String]
    let selected: Int
    let onSelect: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(options.enumerated()), id: \.offset) { idx, label in
                    Button {
                        onSelect(idx)
                    } label: {
                        Text(label)
                            .font(.system(size: 13))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(selected == idx ? AppColors.brand : AppColors.surfaceContainerHigh,
                                        in: Capsule())
                            .foregroundStyle(selected == idx ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// 设备标签多选（对齐 Android DeviceTagSheet：chip 多选 + 管理标签 + 保存）
struct DeviceTagSheet: View {
    let deviceId: String
    let selected: [String]
    var onManageTags: () -> Void
    var onSave: ([String]) -> Void
    @EnvironmentObject private var scope: UserScope
    @Environment(\.dismiss) private var dismiss
    @State private var sel: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("设置标签 · \(deviceId)").font(.system(size: 16, weight: .semibold))
            if scope.devices.tags.tags.isEmpty {
                Text("还没有标签").font(.system(size: 13)).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 8)], spacing: 8) {
                        ForEach(scope.devices.tags.tags) { t in
                            Button {
                                if sel.contains(t.id) { sel.remove(t.id) } else { sel.insert(t.id) }
                            } label: {
                                HStack(spacing: 5) {
                                    Circle().fill(Color(hex: t.color)).frame(width: 7, height: 7)
                                    Text(t.name).font(.system(size: 13))
                                }
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(sel.contains(t.id) ? AppColors.brand : AppColors.surfaceContainerHigh,
                                            in: Capsule())
                                .foregroundStyle(sel.contains(t.id) ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            HStack {
                Button("管理标签") {
                    dismiss()
                    onManageTags()
                }
                .font(.system(size: 14))
                Spacer()
                Button {
                    onSave(scope.devices.tags.tags.map(\.id).filter { sel.contains($0) })
                } label: {
                    Text("保存").font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 20).padding(.vertical, 8)
                        .background(AppColors.brand, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 20)
        .presentationDetents([.medium, .large])
        .onAppear { sel = Set(selected) }
    }
}
