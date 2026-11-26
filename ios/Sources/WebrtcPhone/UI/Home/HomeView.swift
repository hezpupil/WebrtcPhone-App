import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var scope: UserScope
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0
    /// 独立投屏页状态（对齐 Android StreamActivity）：置于 TabView 之上的全屏层，
    /// 彻底覆盖底部导航栏，只能通过投屏页内的返回/结束投屏退出
    @State private var streaming: Device?

    var body: some View {
        ZStack {
            TabView(selection: $tab) {
                NavigationStack { DevicesTab(onStream: { streaming = $0 }) }
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
                StreamView(device: device, scope: scope, container: container) {
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
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var scope: UserScope
    @State private var search = ""
    @State private var statusFilter = 0 // 0 全部 / 1 在线 / 2 使用中 / 3 离线
    @State private var selected: Device?

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
                                       compact: container.settings.app.gridColumns >= 3)
                                .onTapGesture { selected = device }
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
                DeviceActionsSheet(device: device, onStream: {
                    selected = nil
                    onStream(device)
                })
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
    let onStream: () -> Void
    @EnvironmentObject private var scope: UserScope
    @Environment(\.dismiss) private var dismiss
    @State private var alias = ""
    @State private var showDeleteConfirm = false
    @State private var showLease = false
    @State private var showTags = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(action: { dismiss(); onStream() }) {
                        Label("连接并投屏", systemImage: "play.rectangle.fill")
                    }.disabled(!device.online)
                }
                Section {
                    Button(action: { showLease = true }) {
                        Label("设备开租 / 租约管理", systemImage: "iphone")
                    }
                }
                Section("设备信息") {
                    LabeledContent("设备 ID", value: device.id)
                    LabeledContent("型号", value: device.info.title)
                    LabeledContent("Android", value: device.info.androidVersion)
                    LabeledContent("状态", value: device.online ? "在线" : "离线")
                }
                Section("备注") {
                    TextField("设备备注", text: $alias)
                    Button("保存备注") {
                        Task { try? await scope.devices.setDeviceAlias(device.id, alias: alias); dismiss() }
                    }
                }
                Section {
                    Button("删除设备", role: .destructive) { showDeleteConfirm = true }
                }
            }
            .navigationTitle(device.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("关闭") { dismiss() } } }
            .onAppear { alias = device.alias }
            .alert("确认删除", isPresented: $showDeleteConfirm) {
                Button("删除", role: .destructive) {
                    Task { try? await scope.devices.deleteDevice(device.id); dismiss() }
                }
                Button("取消", role: .cancel) {}
            }
            .sheet(isPresented: $showLease) {
                DeviceLeaseSheet(device: device).environmentObject(scope)
            }
        }
        .presentationDetents([.medium, .large])
    }
}
