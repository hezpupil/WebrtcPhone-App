import SwiftUI

// MARK: - 快捷文本
struct QuickTextView: View {
    @EnvironmentObject private var scope: UserScope
    @State private var showEditor = false
    @State private var editId: String?
    @State private var title = ""
    @State private var content = ""
    @State private var autoEnter = false

    var body: some View {
        List {
            ForEach(scope.quickTexts.items) { item in
                VStack(alignment: .leading) {
                    Text(item.title).font(.subheadline.weight(.medium))
                    Text(item.content).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                .swipeActions {
                    Button("删除", role: .destructive) {
                        Task { try? await scope.quickTexts.delete(item.id) }
                    }
                    Button("编辑") {
                        editId = item.id; title = item.title; content = item.content
                        autoEnter = item.autoEnter; showEditor = true
                    }.tint(.blue)
                }
            }
        }
        .navigationTitle("快捷文本")
        .toolbar {
            Button {
                editId = nil; title = ""; content = ""; autoEnter = false; showEditor = true
            } label: { Image(systemName: "plus") }
        }
        .onAppear { Task { await scope.quickTexts.load() } }
        .sheet(isPresented: $showEditor) {
            NavigationStack {
                Form {
                    TextField("标题", text: $title)
                    TextEditor(text: $content).frame(minHeight: 120)
                    Toggle("自动回车", isOn: $autoEnter)
                }
                .navigationTitle(editId == nil ? "新增" : "编辑")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("保存") {
                            Task {
                                try? await scope.quickTexts.upsert(title: title, content: content,
                                                                    autoEnter: autoEnter, id: editId)
                                showEditor = false
                            }
                        }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

// MARK: - 标签管理
struct TagsView: View {
    @EnvironmentObject private var scope: UserScope
    @State private var newName = ""
    @State private var showColor = false

    var body: some View {
        List {
            Section("新增标签") {
                HStack {
                    TextField("标签名", text: $newName)
                    Button("添加") {
                        let name = newName.trimmingCharacters(in: .whitespaces)
                        guard !name.isEmpty, !TagOps.isDuplicateName(scope.devices.tags.tags, name: name, selfId: nil) else { return }
                        let tag = Tag(id: TagOps.newTagId(), name: name, color: "#3b82f6")
                        Task { try? await scope.devices.upsertTag(tag) }
                        newName = ""
                    }
                }
            }
            Section("标签列表") {
                ForEach(scope.devices.tags.tags) { tag in
                    HStack {
                        Circle().fill(Color(hex: tag.color)).frame(width: 12, height: 12)
                        Text(tag.name)
                        Spacer()
                        Text("\(scope.devices.tags.deviceTags.filter { $0.value.contains(tag.id) }.count) 设备")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button("删除", role: .destructive) {
                            Task { try? await scope.devices.deleteTag(tag.id) }
                        }
                    }
                }
            }
        }
        .navigationTitle("标签管理")
        .onAppear { Task { await scope.devices.loadMeta() } }
    }
}

// MARK: - 分享管理
struct SharesView: View {
    @EnvironmentObject private var scope: UserScope
    @State private var shares: [Share] = []
    @State private var showCreate = false
    @State private var deviceId = ""
    @State private var hours: Int64 = 24
    @State private var created: ShareCreated?

    var body: some View {
        List {
            ForEach(shares) { share in
                VStack(alignment: .leading, spacing: 4) {
                    Text(share.token).font(.system(.caption, design: .monospaced))
                    Text("设备 \(share.deviceId) · \(share.expiresAt.map { $0 > Date() ? "有效" : "已过期" } ?? "长期")")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .swipeActions {
                    Button("撤销", role: .destructive) {
                        Task { try? await scope.api.revokeShare(token: share.token); await load() }
                    }
                }
            }
        }
        .navigationTitle("分享管理")
        .toolbar { Button { showCreate = true } label: { Image(systemName: "plus") } }
        .onAppear { Task { await load() } }
        .sheet(isPresented: $showCreate) {
            NavigationStack {
                Form {
                    TextField("设备 ID", text: $deviceId)
                    Stepper("有效时长 \(hours) 小时", value: $hours, in: 1...720)
                }
                .navigationTitle("创建分享")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("生成") {
                            Task {
                                let req = ShareCreateRequest(deviceId: deviceId, expireSeconds: hours * 3600,
                                                              accessMode: .full, password: "", description: "",
                                                              allowClipboard: true, allowFileTx: true, customCardCode: "")
                                created = try? await scope.api.createShare(req)
                                showCreate = false
                                await load()
                            }
                        }
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .alert("分享已创建", isPresented: Binding(get: { created != nil }, set: { if !$0 { created = nil } })) {
            Button("复制并在 Safari 打开") {
                if let created, let url = URL(string: created.shareUrl.isEmpty ? scope.api.shareLink(token: created.token) : created.shareUrl) {
                    UIApplication.shared.open(url)
                }
            }
            Button("完成", role: .cancel) {}
        } message: {
            Text(created?.token ?? "")
        }
    }

    private func load() async { shares = (try? await scope.api.shares()) ?? [] }
}

// MARK: - 用户管理
struct UsersView: View {
    @EnvironmentObject private var scope: UserScope
    @State private var users: [AdminUser] = []

    var body: some View {
        List {
            ForEach(users) { user in
                VStack(alignment: .leading) {
                    HStack {
                        Text(user.username).font(.subheadline.weight(.medium))
                        if user.role == "admin" { Text("管理员").font(.caption2).foregroundStyle(.blue) }
                        Spacer()
                        Text(user.online ? "在线" : "离线").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(user.note).font(.caption2).foregroundStyle(.secondary)
                }
                .swipeActions {
                    Button("踢下线") { Task { try? await scope.api.kickUser(user.username) } }.tint(.orange)
                    Button("删除", role: .destructive) {
                        Task { try? await scope.api.deleteUser(user.username); await load() }
                    }
                }
            }
        }
        .navigationTitle("用户管理")
        .onAppear { Task { await load() } }
    }

    private func load() async { users = (try? await scope.api.users()) ?? [] }
}

// MARK: - 服务器文件
struct ServerFilesView: View {
    @EnvironmentObject private var scope: UserScope
    @State private var showUpload = false

    var body: some View {
        List {
            ForEach(scope.serverFiles.files) { file in
                HStack {
                    Image(systemName: "doc").foregroundStyle(.blue)
                    VStack(alignment: .leading) {
                        Text(file.name).font(.subheadline)
                        Text("\(file.size / 1024) KB").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("下发") { /* 在批量分发页选择设备 */ }
                }
                .swipeActions {
                    Button("删除", role: .destructive) {
                        Task { try? await scope.serverFiles.delete(file.name) }
                    }
                }
            }
        }
        .navigationTitle("服务器文件")
        .toolbar {
            Button { showUpload = true } label: { Image(systemName: "square.and.arrow.up") }
        }
        .onAppear { Task { await scope.serverFiles.refresh() } }
        .fileImporter(isPresented: $showUpload, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result {
                Task {
                    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
                    try? await scope.serverFiles.upload(url: url, name: url.lastPathComponent,
                                                        size: (attrs?[.size] as? NSNumber)?.int64Value ?? 0)
                }
            }
        }
    }
}

// MARK: - 批量分发
struct BatchFilesView: View {
    @EnvironmentObject private var scope: UserScope
    @State private var selectedFile: ServerFile?
    @State private var selectedDevices: Set<String> = []
    @State private var busy = false

    var body: some View {
        Form {
            Section("选择文件") {
                Picker("服务器文件", selection: $selectedFile) {
                    Text("请选择").tag(nil as ServerFile?)
                    ForEach(scope.serverFiles.files) { Text($0.name).tag($0 as ServerFile?) }
                }
            }
            Section("目标设备") {
                ForEach(scope.devices.devices) { d in
                    Toggle(d.displayName, isOn: Binding(
                        get: { selectedDevices.contains(d.id) },
                        set: { if $0 { selectedDevices.insert(d.id) } else { selectedDevices.remove(d.id) } }
                    ))
                }
            }
            Section {
                Button(busy ? "分发中…" : "开始分发") {
                    guard let file = selectedFile, !selectedDevices.isEmpty else { return }
                    busy = true
                    Task {
                        try? await scope.serverFiles.dispatchBatch(file, deviceIds: Array(selectedDevices), destPath: nil)
                        busy = false
                    }
                }.disabled(busy || selectedFile == nil || selectedDevices.isEmpty)
            }
            if let task = scope.serverFiles.task {
                Section("任务进度") {
                    ForEach(Array(task.devices.values), id: \.deviceId) { sub in
                        HStack {
                            Text(sub.deviceId).font(.caption)
                            Spacer()
                            Text(sub.status).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("批量分发")
        .onAppear {
            Task { await scope.serverFiles.refresh() }
        }
    }
}

// MARK: - Color(hex:)
extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var rgb: UInt64 = 0
        Scanner(string: h).scanHexInt64(&rgb)
        self.init(red: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255)
    }
}
