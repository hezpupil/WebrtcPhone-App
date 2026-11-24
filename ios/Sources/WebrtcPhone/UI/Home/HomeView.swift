import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var scope: UserScope
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { DevicesTab() }
                .tabItem { Label("设备", systemImage: "rectangle.grid.2x2") }.tag(0)
            NavigationStack { ManageTab() }
                .tabItem { Label("管理", systemImage: "slider.horizontal.3") }.tag(1)
            NavigationStack { MeTab() }
                .tabItem { Label("我的", systemImage: "person.circle") }.tag(2)
        }
        .onChange(of: tab) { _ in
            scope.devices.setActive(tab == 0)
        }
        .onAppear { scope.devices.setActive(true) }
    }
}

// MARK: - 设备大盘
struct DevicesTab: View {
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var scope: UserScope
    @State private var search = ""
    @State private var selected: Device?
    @State private var linkDevice: Device?

    private var filtered: [Device] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let base = q.isEmpty ? scope.devices.devices : scope.devices.devices.filter {
            $0.displayName.lowercased().contains(q) || $0.id.lowercased().contains(q)
        }
        return base.sorted { a, b in
            if a.online != b.online { return a.online }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
    }

    private var columns: [GridItem] {
        let n = container.settings.app.gridColumns
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: n)
    }

    var body: some View {
        Group {
            if scope.devices.loading && scope.devices.devices.isEmpty {
                ProgressView("加载设备…")
            } else if filtered.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "iphone.slash").font(.largeTitle).foregroundStyle(.secondary)
                    Text(search.isEmpty ? "暂无设备" : "无匹配设备").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(filtered) { device in
                            DeviceCard(device: device, snapshot: scope.devices.snapshots[device.id]?.image)
                                .onTapGesture { selected = device }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .navigationTitle("设备")
        .searchable(text: $search, prompt: "搜索设备名称或 ID")
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
        .sheet(item: $selected) { device in
            DeviceActionsSheet(device: device, onStream: { linkDevice = device })
        }
        .fullScreenCover(item: $linkDevice) { device in
            StreamView(device: device, scope: scope, container: container)
        }
        .refreshable { await scope.devices.refresh() }
    }
}

struct DeviceCard: View {
    let device: Device
    let snapshot: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                if let image = snapshot {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(maxWidth: .infinity).aspectRatio(16/9, contentMode: .fill)
                        .clipped()
                } else {
                    Rectangle().fill(Color.secondary.opacity(0.12))
                        .aspectRatio(16/9, contentMode: .fill)
                        .overlay(Image(systemName: "iphone").font(.largeTitle).foregroundStyle(.secondary))
                }
                Circle().fill(device.online ? .green : .gray).frame(width: 10, height: 10)
                    .padding(6)
            }
            .cornerRadius(8)

            Text(device.displayName).font(.subheadline.weight(.medium)).lineLimit(1)
            Text(device.info.title.isEmpty ? device.id : device.info.title)
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            if device.inUse {
                Label("使用中 · \(device.clientCount)", systemImage: "person.fill")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(8).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct DeviceActionsSheet: View {
    let device: Device
    let onStream: () -> Void
    @EnvironmentObject private var scope: UserScope
    @Environment(\.dismiss) private var dismiss
    @State private var alias = ""
    @State private var showDeleteConfirm = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(action: { dismiss(); onStream() }) {
                        Label("连接并投屏", systemImage: "play.rectangle.fill")
                    }.disabled(!device.online)
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
                        Task { try? await scope.devices.setDeviceAlias(device.id, alias: alias) }
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
        }
        .presentationDetents([.medium, .large])
    }
}
