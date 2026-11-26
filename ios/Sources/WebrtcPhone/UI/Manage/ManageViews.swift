import SwiftUI

// MARK: - 时长选项（对齐 Android Durations）

enum Durations {
    static let account: [(String, Int64)] = [("永久", 0), ("1 天", 86_400), ("7 天", 604_800),
        ("30 天", 2_592_000), ("90 天", 7_776_000), ("365 天", 31_536_000)]
    static let lease: [(String, Int64)] = [("30 分钟", 1_800), ("1 小时", 3_600), ("2 小时", 7_200),
        ("6 小时", 21_600), ("1 天", 86_400), ("7 天", 604_800), ("30 天", 2_592_000), ("永久", 0)]
    static let leaseExtend: [(String, Int64)] = [("+30 分钟", 1_800), ("+1 小时", 3_600), ("+2 小时", 7_200),
        ("+1 天", 86_400), ("+7 天", 604_800), ("+30 天", 2_592_000)]
    static let shareExpiry: [(String, Int64)] = [("1 小时", 3_600), ("6 小时", 21_600), ("1 天", 86_400),
        ("7 天", 604_800), ("30 天", 2_592_000), ("永久", 0)]
    static let shareExtend: [(String, Int64)] = [("+1 小时", 3_600), ("+1 天", 86_400),
        ("+7 天", 604_800), ("+30 天", 2_592_000)]
}

// MARK: - 用户筛选

enum UserFilter: String, CaseIterable, Identifiable {
    case all = "全部", online = "在线", leased = "租约中", expiring = "即将到期", expired = "已到期", admin = "管理员"
    var id: String { rawValue }
}

// MARK: - 分享与卡密

struct SharesView: View {
    @EnvironmentObject private var scope: UserScope
    /// 预选设备（从设备长按菜单「分享 / 生成卡密」进入时携带，对齐 Android Routes.shares(id, create=true)）
    var presetDeviceId: String? = nil
    @State private var shares: [Share] = []
    @State private var loading = false
    @State private var showCreate = false
    @State private var created: ShareCreated?
    @State private var revokeTarget: Share?
    @State private var extendTarget: Share?

    var body: some View {
        Group {
            if shares.isEmpty && !loading {
                ScrollView { EmptyStateView(icon: "square.and.arrow.up.on.square", title: "暂无有效分享",
                                            message: "创建分享后，访客可凭卡密在 App 或网页免登录访问设备",
                                            actionTitle: "新建分享") { showCreate = true } }
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(shares) { share in
                            ShareCard(share: share,
                                      onCopy: { copy($0) },
                                      onRevoke: { revokeTarget = share },
                                      onExtend: { extendTarget = share })
                        }
                    }
                    .padding(16)
                }
                .refreshable { await load() }
            }
        }
        .background(AppColors.background)
        .navigationTitle("分享与卡密")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showCreate = true } label: { Image(systemName: "plus") }
            }
        }
        .overlay {
            if loading && shares.isEmpty { ProgressView() }
        }
        .onAppear { Task { await load() } }
        .sheet(isPresented: $showCreate) {
            ShareCreateDialog(presetDeviceId: presetDeviceId,
                              onCreated: { c in created = c; Task { await load() } })
                .environmentObject(scope)
        }
        .sheet(isPresented: Binding(get: { created != nil }, set: { if !$0 { created = nil } })) {
            if let c = created { ShareResultDialog(created: c, onDone: { created = nil }) }
        }
        .confirmationDialog("撤销分享", isPresented: Binding(get: { revokeTarget != nil },
                                                          set: { if !$0 { revokeTarget = nil } }),
                            titleVisibility: .visible) {
            Button("撤销", role: .destructive) {
                guard let s = revokeTarget else { return }
                Task { try? await scope.api.revokeShare(token: s.token); await load() }
            }
        } message: {
            Text("撤销卡密 \(revokeTarget?.cardCode ?? "")？正在使用的访客会被立即断开。")
        }
        .sheet(isPresented: Binding(get: { extendTarget != nil }, set: { if !$0 { extendTarget = nil } })) {
            if let s = extendTarget {
                DurationPickSheet(title: "延长有效期", message: "为卡密 \(s.cardCode) 延长有效期",
                                  options: Durations.shareExtend, confirmText: "确认延长") { seconds in
                    Task { try? await scope.api.extendShare(token: s.token, seconds: seconds); await load() }
                }
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        shares = (try? await scope.api.shares()) ?? []
    }

    private func copy(_ text: String) {
        UIPasteboard.general.string = text
    }
}

/// 分享卡片（对齐 Android ShareCard，字段一个不漏）
struct ShareCard: View {
    @EnvironmentObject private var scope: UserScope
    let share: Share
    var onCopy: (String) -> Void
    var onRevoke: () -> Void
    var onExtend: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(share.cardCode)
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                Spacer()
                if share.activeConnections > 0 {
                    StatusPill(text: "在线 \(share.activeConnections)", color: AppColors.online, filled: true)
                }
                Menu {
                    Button { onCopy(share.cardCode) } label: { Label("复制卡密", systemImage: "doc.on.doc") }
                    Button { onCopy(link) } label: { Label("复制链接", systemImage: "link") }
                    Button { onCopy("云手机访问卡密：\(share.cardCode)\n网页访问：\(link)") } label: {
                        Label("发送给…", systemImage: "square.and.arrow.up")
                    }
                    if share.expiresAt != nil {
                        Button { onExtend() } label: { Label("延长有效期", systemImage: "clock.badge.plus") }
                    }
                    Button(role: .destructive) { onRevoke() } label: { Label("撤销", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle").foregroundStyle(.secondary) }
            }

            FlowPills(pills: devicePills)

            Text(infoText)
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if !share.description.isEmpty {
                Text(share.description).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.black.opacity(0.06), lineWidth: 0.5))
    }

    private var link: String { scope.api.shareLink(token: share.token) }

    private var devicePills: [PillItem] {
        var pills: [PillItem] = [PillItem(text: share.deviceId, color: AppColors.brand, filled: true)]
        pills.append(PillItem(text: share.accessMode.label,
                              color: share.accessMode == .full ? AppColors.brand : AppColors.offline, filled: false))
        if share.requirePassword { pills.append(PillItem(text: "需密码", color: AppColors.warning, filled: false)) }
        if !share.allowClipboard { pills.append(PillItem(text: "禁剪贴板", color: AppColors.offline, filled: false)) }
        if !share.allowFileTx { pills.append(PillItem(text: "禁文件", color: AppColors.offline, filled: false)) }
        return pills
    }

    private var infoText: String {
        var parts: [String] = []
        if let exp = share.expiresAt {
            parts.append("到期 \(Formatters.shortDateTime(exp))（\(Formatters.relative(exp))）")
        } else {
            parts.append("永久有效")
        }
        parts.append("使用 \(share.useCount) 次")
        if share.lastUsedAt != nil { parts.append("最近 \(Formatters.relative(share.lastUsedAt))") }
        return parts.joined(separator: " · ")
    }
}

/// 简易 FlowRow
struct FlowPills: View {
    let pills: [PillItem]

    var body: some View {
        FlexibleChips(items: pills) { p in
            StatusPill(text: p.text, color: p.color, filled: p.filled)
        }
    }
}

/// 状态药丸数据（Hashable 供 ForEach 使用）
struct PillItem: Hashable {
    let text: String
    let color: Color
    let filled: Bool
}

/// 简化的换行 chips（每行最多 3 个）
struct FlexibleChips<Item: Hashable, Content: View>: View {
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        if items.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<max(1, (items.count + 2) / 3), id: \.self) { row in
                    HStack(spacing: 6) {
                        ForEach(Array(items.enumerated().filter { $0.offset / 3 == row }), id: \.element) { _, item in
                            content(item)
                        }
                    }
                }
            }
        }
    }
}

/// 新建分享弹窗（对齐 Android ShareCreateDialog）
struct ShareCreateDialog: View {
    @EnvironmentObject private var scope: UserScope
    @Environment(\.dismiss) private var dismiss
    /// 预选设备 ID（设备长按菜单进入时直接锁定目标）
    var presetDeviceId: String? = nil
    var onCreated: (ShareCreated) -> Void

    @State private var deviceId = ""
    @State private var expiryIdx = 2
    @State private var accessMode: AccessMode = .full
    @State private var allowClipboard = true
    @State private var allowFileTx = true
    @State private var password = ""
    @State private var customCard = ""
    @State private var note = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("设备") {
                    Picker("目标设备", selection: $deviceId) {
                        Text("请选择").tag("")
                        ForEach(scope.devices.devices) { d in
                            Text(d.displayName + (d.online ? "" : "（离线）")).tag(d.id)
                        }
                    }
                }
                Section("有效期") {
                    DurationChips(options: Durations.shareExpiry, selection: $expiryIdx)
                }
                Section("权限") {
                    Picker("访问权限", selection: $accessMode) {
                        Text("完全控制").tag(AccessMode.full)
                        Text("仅观看").tag(AccessMode.viewOnly)
                    }
                    .pickerStyle(.segmented)
                    Toggle("允许剪贴板同步", isOn: $allowClipboard)
                    Toggle("允许文件传输", isOn: $allowFileTx)
                }
                Section("可选") {
                    SecureField("访问密码（可选）", text: $password)
                    TextField("自定义卡密（可选）", text: $customCard)
                        .textInputAutocapitalization(.characters)
                        .onChange(of: customCard) { v in
                            customCard = String(v.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(16))
                        }
                    TextField("备注（可选）", text: $note)
                        .onChange(of: note) { v in
                            if v.count > 100 { note = String(v.prefix(100)) }
                        }
                }
                if let error {
                    Text(error).font(.caption).foregroundStyle(AppColors.danger)
                }
            }
            .navigationTitle("新建分享")
        .onAppear {
            // 从设备长按菜单进入：直接锁定目标设备（对齐 Android Routes.shares(id, create=true)）
            if deviceId.isEmpty, let preset = presetDeviceId { deviceId = preset }
        }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(busy ? "创建中…" : "创建") { Task { await create() } }
                        .disabled(busy || deviceId.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func create() async {
        busy = true; error = nil
        defer { busy = false }
        let req = ShareCreateRequest(deviceId: deviceId,
                                     expireSeconds: Durations.shareExpiry[expiryIdx].1,
                                     accessMode: accessMode,
                                     password: password, description: note,
                                     allowClipboard: allowClipboard, allowFileTx: allowFileTx,
                                     customCardCode: customCard)
        do {
            let c = try await scope.api.createShare(req)
            dismiss()
            onCreated(c)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// 分享创建结果（对齐 Android ShareResultDialog）
struct ShareResultDialog: View {
    let created: ShareCreated
    var onDone: () -> Void
    @EnvironmentObject private var scope: UserScope
    @Environment(\.dismiss) private var dismiss
    @State private var copiedCard = false
    @State private var copiedLink = false

    private var link: String {
        created.shareUrl.isEmpty ? scope.api.shareLink(token: created.token) : created.shareUrl
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("分享已创建").font(.headline)
                Text(created.cardCode)
                    .font(.system(size: 26, weight: .bold, design: .monospaced))
                    .padding(16)
                    .frame(maxWidth: .infinity)
                    .background(AppColors.brand.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
                Text(created.expiresAt.map { "有效期至 \(Formatters.dateTime($0))" } ?? "永久有效")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                Text(link).font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(2)
                    .textSelection(.enabled)
                HStack(spacing: 10) {
                    Button { UIPasteboard.general.string = created.cardCode; copiedCard = true } label: {
                        Label(copiedCard ? "已复制" : "卡密", systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button { UIPasteboard.general.string = link; copiedLink = true } label: {
                        Label(copiedLink ? "已复制" : "链接", systemImage: "link")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                ShareLink(item: "云手机访问卡密：\(created.cardCode)\n网页访问：\(link)\n" +
                                (created.expiresAt.map { "有效期至 \(Formatters.dateTime($0))" } ?? "长期有效")) {
                    Label("发送给…", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(AppColors.brand)
                Button("完成") { dismiss(); onDone() }
            }
            .padding(20)
        }
        .presentationDetents([.medium, .large])
    }
}

/// 通用时长选择 sheet
struct DurationPickSheet: View {
    let title: String
    var message: String = ""
    let options: [(String, Int64)]
    var confirmText: String
    var onConfirm: (Int64) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection = 0

    var body: some View {
        NavigationStack {
            Form {
                if !message.isEmpty {
                    Section { Text(message).font(.system(size: 13)).foregroundStyle(.secondary) }
                }
                Section("选择时长") {
                    ForEach(Array(options.enumerated()), id: \.offset) { idx, opt in
                        Button {
                            selection = idx
                        } label: {
                            HStack {
                                Text(opt.0).foregroundStyle(.primary)
                                Spacer()
                                if selection == idx { Image(systemName: "checkmark").foregroundStyle(AppColors.brand) }
                            }
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(confirmText) { dismiss(); onConfirm(options[selection].1) }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// 时长 chips 行（FlowRow）
struct DurationChips: View {
    let options: [(String, Int64)]
    @Binding var selection: Int

    var body: some View {
        FlexibleChips(items: Array(options.indices)) { idx in
            FilterChip(text: options[idx].0, selected: selection == idx) { selection = idx }
        }
    }
}

// MARK: - 用户管理

struct UsersView: View {
    @EnvironmentObject private var scope: UserScope
    @State private var users: [AdminUser] = []
    @State private var leases: [AdminLease] = []
    @State private var loading = false
    @State private var search = ""
    @State private var filter: UserFilter?
    @State private var showCreate = false
    @State private var detailUser: AdminUser?
    @State private var leaseDialogUser: AdminUser?

    var body: some View {
        VStack(spacing: 10) {
            // 统计卡（可点击筛选）
            HStack(spacing: 8) {
                StatMiniCard(value: "\(users.count)", label: "全部用户", color: AppColors.brand,
                             selected: filter == .all) { filter = filter == .all ? nil : .all }
                StatMiniCard(value: "\(users.filter { $0.online }.count)", label: "在线", color: AppColors.online,
                             selected: filter == .online) { filter = filter == .online ? nil : .online }
                StatMiniCard(value: "\(leases.filter { $0.active && !$0.isRevoked }.count)", label: "活跃租约",
                             color: AppColors.brand,
                             selected: filter == .leased) { filter = filter == .leased ? nil : .leased }
                StatMiniCard(value: "\(users.filter { $0.isAdmin }.count)", label: "管理员",
                             color: AppColors.warning,
                             selected: filter == .admin) { filter = filter == .admin ? nil : .admin }
            }
            .padding(.horizontal, 16)

            RoundedSearchField(text: $search, placeholder: "搜索用户名 / 备注").padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(UserFilter.allCases) { f in
                        FilterChip(text: f.rawValue, selected: filter == f) {
                            filter = filter == f ? nil : f
                        }
                    }
                }
                .padding(.horizontal, 16)
            }

            if loading && users.isEmpty {
                Spacer()
                ProgressView()
                Spacer()
            } else if filtered.isEmpty {
                Spacer()
                EmptyStateView(icon: "person.crop.circle.badge.question", title: "没有匹配的用户")
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(filtered) { user in
                            UserCard(user: user, leases: leases,
                                     isSelf: user.username == scope.session.username,
                                     onOpenDetail: { detailUser = user },
                                     onQuickLease: { leaseDialogUser = user })
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 16)
                }
                .refreshable { await load() }
            }
        }
        .background(AppColors.background)
        .navigationTitle("用户管理")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showCreate = true } label: { Image(systemName: "person.badge.plus") }
            }
        }
        .onAppear { Task { await load() } }
        .onReceive(NotificationCenter.default.publisher(for: .usersNeedRefresh)) { _ in
            Task { await load() }
        }
        .sheet(isPresented: $showCreate) {
            CreateUserDialog { Task { await load() } }.environmentObject(scope)
        }
        .sheet(isPresented: Binding(get: { detailUser != nil }, set: { if !$0 { detailUser = nil } })) {
            if let user = detailUser {
                UserDetailSheet(user: user) { Task { await load() } }.environmentObject(scope)
            }
        }
        .sheet(isPresented: Binding(get: { leaseDialogUser != nil }, set: { if !$0 { leaseDialogUser = nil } })) {
            if let user = leaseDialogUser {
                CreateLeaseSheet(username: user.username) { Task { await load() } }
                    .environmentObject(scope)
            }
        }
    }

    private var filtered: [AdminUser] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        var base = users
        if !q.isEmpty {
            base = base.filter { $0.username.lowercased().contains(q) || $0.note.lowercased().contains(q) }
        }
        let activeNames = Set(leases.filter { $0.active && !$0.isRevoked }.map { $0.username })
        switch filter {
        case .all: break
        case .online: base = base.filter { $0.online }
        case .leased: base = base.filter { activeNames.contains($0.username) }
        case .expiring:
            base = base.filter { u in
                guard let exp = u.expiresAt else { return false }
                let d = exp.timeIntervalSinceNow
                return d > 0 && d < 7 * 86_400
            }
        case .expired: base = base.filter { $0.isExpired() }
        case .admin: base = base.filter { $0.isAdmin }
        case nil: break
        }
        return base.sorted { a, b in
            if a.online != b.online { return a.online }
            return a.username.localizedCaseInsensitiveCompare(b.username) == .orderedAscending
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        async let us = scope.api.users()
        async let ls = scope.api.adminLeases(status: "all")
        users = (try? await us) ?? []
        leases = (try? await ls) ?? []
    }
}

// 让 UserFilter 三态切换：nil 表示无筛选（已直接用 Optional 处理）

/// 用户卡片（对齐 Android UserCard）
struct UserCard: View {
    let user: AdminUser
    let leases: [AdminLease]
    let isSelf: Bool
    var onOpenDetail: () -> Void
    var onQuickLease: () -> Void

    @EnvironmentObject private var scope: UserScope

    private var userLeases: [AdminLease] {
        leases.filter { $0.username == user.username }
    }
    private var activeLeases: [AdminLease] {
        userLeases.filter { $0.active && !$0.isRevoked }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 头部：头像 + 用户名 + 角色 + 备注 + 菜单
            HStack(spacing: 10) {
                InitialAvatar(username: user.username, isAdmin: user.isAdmin, showOnlineDot: true, online: user.online)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(user.username).font(.system(size: 16, weight: .semibold))
                        if user.isAdmin { StatusPill(text: "👑 管理员", color: AppColors.brand, filled: true) }
                        if isSelf { StatusPill(text: "我", color: AppColors.online, filled: true) }
                    }
                    if !user.note.isEmpty {
                        Text(user.note).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                UserMenu(user: user, isSelf: isSelf, onDetail: onOpenDetail)
            }

            // 状态胶囊组
            FlexibleChips(items: statusPills) { p in
                StatusPill(text: p.text, color: p.color, filled: p.filled)
            }

            // 底部操作行
            Divider()
            HStack {
                Text(activeLeases.isEmpty && userLeases.isEmpty
                     ? "尚未分配设备" : "已分配 \(activeLeases.count) 台设备")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    onQuickLease()
                } label: {
                    Text("+ 开租").font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppColors.brand.opacity(0.5), lineWidth: 1))
                }
                .buttonStyle(.plain)
                Button {
                    onOpenDetail()
                } label: {
                    Text(activeLeases.isEmpty ? "详情" : "管理租约").font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(AppColors.surfaceContainerHigh, in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(AppColors.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.black.opacity(0.06), lineWidth: 0.5))
    }

    private var statusPills: [PillItem] {
        var pills: [PillItem] = []
        // 账号有效期
        if user.expiresAt == nil {
            pills.append(PillItem(text: "长期有效", color: AppColors.online, filled: false))
        } else if user.isExpired() {
            pills.append(PillItem(text: "账号已到期", color: AppColors.danger, filled: true))
        } else {
            let rem = Int64(user.expiresAt!.timeIntervalSinceNow)
            let soon = rem < 7 * 86_400
            pills.append(PillItem(text: "账号剩 \(Formatters.duration(rem))",
                                  color: soon ? AppColors.warning : AppColors.brand, filled: false))
        }
        // 租约微标
        if activeLeases.count == 1 {
            let l = activeLeases[0]
            let remain = l.isPermanent ? "永久" : Formatters.duration(l.remainingSeconds)
            pills.append(PillItem(text: "📦 租用 \(l.deviceId) (\(remain))",
                                  color: l.isExpiringSoon(threshold: 7 * 86_400) ? AppColors.warning : AppColors.brand,
                                  filled: false))
        } else if activeLeases.count > 1 {
            pills.append(PillItem(text: "📦 \(activeLeases.count)台设备租约中",
                                  color: AppColors.brand, filled: false))
        } else if !userLeases.isEmpty {
            pills.append(PillItem(text: "📦 历史租约 \(userLeases.count)", color: AppColors.offline, filled: false))
        }
        // 在线会话
        for dev in user.activeDevices {
            pills.append(PillItem(text: "在线控制 \(dev)", color: AppColors.busy, filled: false))
        }
        // 权限限制
        let p = user.policy
        if p.forbidTerminal { pills.append(PillItem(text: "禁终端", color: AppColors.offline, filled: false)) }
        if p.forbidFilePush { pills.append(PillItem(text: "禁文件", color: AppColors.offline, filled: false)) }
        if p.forbidBitrate || p.forbidFps || p.forbidResolution {
            pills.append(PillItem(text: "锁画质", color: AppColors.offline, filled: false))
        }
        if p.forbidAudio { pills.append(PillItem(text: "禁音频", color: AppColors.offline, filled: false)) }
        if p.forbidShare { pills.append(PillItem(text: "禁分享", color: AppColors.offline, filled: false)) }
        return pills
    }
}

/// 用户卡片右上菜单
struct UserMenu: View {
    let user: AdminUser
    let isSelf: Bool
    var onDetail: () -> Void

    @EnvironmentObject private var scope: UserScope
    @State private var showNote = false
    @State private var showResetPwd = false
    @State private var showDelete = false
    @State private var pwd = ""

    var body: some View {
        Menu {
            Button { onDetail() } label: { Label("设备开租 / 租约", systemImage: "iphone") }
            Button { onDetail() } label: { Label("功能限制策略", systemImage: "shield") }
            Button { showNote = true } label: { Label("修改备注", systemImage: "pencil") }
            Button { showResetPwd = true } label: { Label("重置密码", systemImage: "key") }
            if user.online && !isSelf {
                Button {
                    Task { try? await scope.api.kickUser(user.username) }
                } label: { Label("踢下线", systemImage: "power") }
            }
            if !isSelf {
                Button(role: .destructive) { showDelete = true } label: { Label("删除用户", systemImage: "trash") }
            }
        } label: {
            Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showNote) {
            TextInputDialog(title: "修改用户备注", label: "备注（选填）", initial: user.note) { note in
                Task {
                    try? await scope.api.updateUserNote(user.username, note: note)
                    NotificationCenter.default.post(name: .usersNeedRefresh, object: nil)
                }
            }
        }
        .sheet(isPresented: $showResetPwd) {
            TextInputDialog(title: "重置 \(user.username) 的密码", label: "新密码（至少 6 位）") { newPwd in
                Task {
                    try? await scope.api.resetUserPassword(user.username, password: newPwd)
                    NotificationCenter.default.post(name: .usersNeedRefresh, object: nil)
                }
            }
        }
        .confirmationDialog("删除用户", isPresented: $showDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                Task {
                    try? await scope.api.deleteUser(user.username)
                    NotificationCenter.default.post(name: .usersNeedRefresh, object: nil)
                }
            }
        } message: {
            Text("确定删除用户 \(user.username)？其登录凭据与关联的全部设备租约将立即失效并收回。")
        }
    }
}

extension Notification.Name {
    static let usersNeedRefresh = Notification.Name("usersNeedRefresh")
}

/// 新建用户弹窗（对齐 Android CreateUserDialog）
struct CreateUserDialog: View {
    @EnvironmentObject private var scope: UserScope
    @Environment(\.dismiss) private var dismiss
    var onDone: () -> Void

    @State private var username = ""
    @State private var password = ""
    @State private var note = ""
    @State private var expiryIdx = 0
    @State private var isAdmin = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("用户名", text: $username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onChange(of: username) { v in
                            if v.count > 32 { username = String(v.prefix(32)) }
                        }
                    SecureField("初始密码（至少 6 位）", text: $password)
                    TextField("备注（选填）", text: $note)
                        .onChange(of: note) { v in
                            if v.count > 100 { note = String(v.prefix(100)) }
                        }
                }
                Section("账号有效期") {
                    DurationChips(options: Durations.account, selection: $expiryIdx)
                }
                Section {
                    Toggle("设为系统管理员", isOn: $isAdmin)
                }
                if let error {
                    Section { Text(error).font(.caption).foregroundStyle(AppColors.danger) }
                }
            }
            .navigationTitle("新建用户")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(busy ? "创建中…" : "创建") { Task { await create() } }
                        .disabled(busy || username.trimmingCharacters(in: .whitespaces).isEmpty || password.count < 6)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func create() async {
        busy = true; error = nil
        defer { busy = false }
        let req = AdminUserCreate(username: username.trimmingCharacters(in: .whitespaces),
                                  password: password,
                                  role: isAdmin ? "admin" : "user",
                                  note: note,
                                  expireSeconds: Durations.account[expiryIdx].1)
        do {
            try await scope.api.createUser(req)
            dismiss()
            onDone()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// 快捷开租 sheet
struct CreateLeaseSheet: View {
    @EnvironmentObject private var scope: UserScope
    @Environment(\.dismiss) private var dismiss
    let username: String
    var onDone: () -> Void

    @State private var deviceId = ""
    @State private var durationIdx = 4
    @State private var customMode = false
    @State private var customValue = "1"
    @State private var customUnit = 2 // 0 分钟 1 小时 2 天
    @State private var note = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("为「\(username)」开通设备租约") {
                    DevicePicker(selected: $deviceId)
                }
                Section("租用时长") {
                    DurationChips(options: Durations.lease, selection: $durationIdx)
                    Toggle("自定义时长", isOn: $customMode)
                    if customMode {
                        HStack {
                            TextField("数值", text: $customValue)
                                .keyboardType(.numberPad).frame(width: 80)
                            Picker("", selection: $customUnit) {
                                Text("分钟").tag(0); Text("小时").tag(1); Text("天").tag(2)
                            }.pickerStyle(.segmented)
                        }
                    }
                }
                Section {
                    TextField("备注（选填，如订单号 / 用途）", text: $note)
                        .onChange(of: note) { v in
                            if v.count > 80 { note = String(v.prefix(80)) }
                        }
                }
                if let error { Section { Text(error).font(.caption).foregroundStyle(AppColors.danger) } }
            }
            .navigationTitle("开通租约")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(busy ? "开租中…" : "确认开租") { Task { await submit() } }
                        .disabled(busy || deviceId.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var seconds: Int64 {
        if customMode {
            let v = Int64(customValue) ?? 0
            return v * [Int64(60), Int64(3600), Int64(86400)][customUnit]
        }
        return Durations.lease[durationIdx].1
    }

    private func submit() async {
        busy = true; error = nil
        defer { busy = false }
        let req = LeaseCreateRequest(username: username, deviceId: deviceId,
                                     durationSeconds: seconds, note: note, policyOverride: nil)
        do {
            _ = try await scope.api.createLease(req)
            dismiss()
            onDone()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// 设备选择器（下拉菜单：闲置可用设备 + 已有租约设备）
struct DevicePicker: View {
    @EnvironmentObject private var scope: UserScope
    @Binding var selected: String
    @State private var leases: [AdminLease] = []

    private var busyIds: Set<String> {
        Set(leases.filter { $0.active && !$0.isRevoked }.map { $0.deviceId })
    }

    var body: some View {
        Menu {
            Section("闲置可用设备") {
                ForEach(scope.devices.devices.filter { !busyIds.contains($0.id) }) { d in
                    Button {
                        selected = d.id
                    } label: {
                        Label("\(d.displayName) (\(d.info.title.isEmpty ? d.id : d.info.title))",
                              systemImage: d.online ? "circle.fill" : "circle")
                    }
                }
            }
            Section("已有租约设备（开租将产生冲突）") {
                ForEach(scope.devices.devices.filter { busyIds.contains($0.id) }) { d in
                    Button { selected = d.id } label: {
                        Text("\(d.displayName)（已有租约）")
                    }
                }
            }
        } label: {
            HStack {
                Text(selected.isEmpty ? "选择设备" : selected)
                    .foregroundStyle(selected.isEmpty ? .secondary : .primary)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(10)
            .background(AppColors.surfaceContainerHigh, in: RoundedRectangle(cornerRadius: 10))
        }
        .onAppear {
            Task { leases = (try? await scope.api.adminLeases(status: "all")) ?? [] }
        }
    }
}

/// 用户详情抽屉（3 Tab：设备租约 / 账号与安全 / 功能限制）
struct UserDetailSheet: View {
    @EnvironmentObject private var scope: UserScope
    let user: AdminUser
    var onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    @State private var leases: [AdminLease] = []
    @State private var showLeaseForm = false
    @State private var extendLease: AdminLease?
    @State private var noteLease: AdminLease?
    @State private var revokeLease: AdminLease?

    private let tabs = ["设备租约", "账号与安全", "功能限制"]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                // Tab 栏
                HStack(spacing: 0) {
                    ForEach(Array(tabs.enumerated()), id: \.offset) { idx, title in
                        Button {
                            withAnimation { tab = idx }
                        } label: {
                            VStack(spacing: 6) {
                                Text(title)
                                    .font(.system(size: 13, weight: tab == idx ? .semibold : .regular))
                                    .foregroundStyle(tab == idx ? AppColors.brand : .secondary)
                                Rectangle().fill(tab == idx ? AppColors.brand : .clear)
                                    .frame(height: 2)
                            }
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 12)

                switch tab {
                case 0: leaseTab
                case 1: accountTab
                default: policyTab
                }
            }
            .background(AppColors.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("关闭") { dismiss() } }
            }
            .sheet(isPresented: $showLeaseForm) {
                InlineCreateLeaseSheet(username: user.username, leases: leases) {
                    Task { await loadLeases(); onChanged() }
                }
                .environmentObject(scope)
            }
            .sheet(isPresented: Binding(get: { extendLease != nil }, set: { if !$0 { extendLease = nil } })) {
                if let lease = extendLease {
                DurationPickSheet(title: "租约展期",
                                  message: "为设备 \(lease.deviceId) 延长租期。当前租约剩余：\(lease.isPermanent ? "永久有效" : Formatters.duration(lease.remainingSeconds))",
                                  options: Durations.leaseExtend, confirmText: "确认展期") { seconds in
                    Task {
                        try? await scope.api.extendLease(lease.leaseId, seconds: seconds)
                        await loadLeases(); onChanged()
                    }
                }
                }
            }
            .sheet(isPresented: Binding(get: { noteLease != nil }, set: { if !$0 { noteLease = nil } })) {
                if let lease = noteLease {
                TextInputDialog(title: "修改租约备注", label: "租约备注（如订单号/渠道）", initial: lease.note) { note in
                    Task {
                        try? await scope.api.updateLeaseNote(lease.leaseId, note: note)
                        await loadLeases(); onChanged()
                    }
                }
                }
            }
            .confirmationDialog("收回设备租约", isPresented: Binding(get: { revokeLease != nil },
                                                                set: { if !$0 { revokeLease = nil } }),
                                titleVisibility: .visible) {
                Button("收回", role: .destructive) {
                    guard let l = revokeLease else { return }
                    Task {
                        try? await scope.api.revokeLease(l.leaseId)
                        await loadLeases(); onChanged()
                    }
                }
            } message: {
                Text("确定收回用户 \(user.username) 对设备 \(revokeLease?.deviceId ?? "") 的租约？收回后该用户在此设备上的连接将被立即切断。")
            }
        }
        .presentationDetents([.large])
        .onAppear { Task { await loadLeases() } }
    }

    private func loadLeases() async {
        leases = (try? await scope.api.adminLeases(user: user.username, status: "all")) ?? []
    }

    private var header: some View {
        HStack(spacing: 10) {
            InitialAvatar(username: user.username, isAdmin: user.isAdmin, size: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(user.username).font(.system(size: 17, weight: .bold))
                    StatusPill(text: user.isAdmin ? "👑 管理员" : "普通用户",
                               color: user.isAdmin ? AppColors.brand : AppColors.online, filled: true)
                    StatusPill(text: user.online ? "在线" : "离线",
                               color: user.online ? AppColors.online : AppColors.offline, filled: true)
                }
                Text(user.note.isEmpty ? "暂无备注" : user.note)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
    }

    // MARK: Tab 0 设备租约
    private var leaseTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !user.activeDevices.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("当前正在控制的设备", systemImage: "rectangle.connected.to.line.underline")
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(AppColors.busy)
                        ForEach(user.activeDevices, id: \.self) { dev in
                            HStack {
                                Circle().fill(AppColors.busy).frame(width: 8, height: 8)
                                Text(dev).font(.system(size: 13, design: .monospaced))
                                Spacer()
                                Button("切断") {
                                    Task { try? await scope.api.kickUser(user.username, deviceId: dev)
                                           await loadLeases(); onChanged() }
                                }
                                .font(.system(size: 12)).foregroundStyle(AppColors.danger)
                            }
                        }
                    }
                    .padding(12)
                    .background(AppColors.busy.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                }

                HStack {
                    Text("设备租约列表").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Button {
                        showLeaseForm.toggle()
                    } label: {
                        Label(showLeaseForm ? "取消开租" : "开通新租约",
                              systemImage: showLeaseForm ? "xmark" : "plus")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.borderedProminent).tint(AppColors.brand)
                }

                if showLeaseForm {
                    InlineLeaseForm(username: user.username, leases: leases) {
                        showLeaseForm = false
                        Task { await loadLeases(); onChanged() }
                    }
                }

                let active = leases.filter { $0.active && !$0.isRevoked }
                let history = leases.filter { !($0.active && !$0.isRevoked) }
                if leases.isEmpty {
                    VStack(spacing: 6) {
                        Text("该用户当前未持有任何设备租约").font(.system(size: 13)).foregroundStyle(.secondary)
                        Text("点击上方「开通新租约」分配云手机使用权")
                            .font(.system(size: 12)).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(20)
                    .background(AppColors.surface, in: RoundedRectangle(cornerRadius: 14))
                } else {
                    ForEach(active + history) { lease in
                        LeaseItemCard(lease: lease, username: user.username,
                                      onExtend: { extendLease = lease },
                                      onNote: { noteLease = lease },
                                      onRevoke: { revokeLease = lease })
                    }
                }
            }
            .padding(14)
        }
    }

    // MARK: Tab 1 账号与安全
    @State private var expireChoice = -1
    private var accountTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                SectionCard(title: "账号登录有效期") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(currentExpiryText).font(.system(size: 13))
                        FlexibleChips(items: Array((-1...5))) { idx in
                            FilterChip(text: idx == -1 ? "保持不变" : Durations.account[idx].0,
                                       selected: expireChoice == idx) { expireChoice = idx }
                        }
                        if expireChoice != -1 {
                            Button {
                                Task {
                                    let seconds = expireChoice == 0 ? 0 : Durations.account[expireChoice].1
                                    try? await scope.api.updateUser(user.username, expireSeconds: seconds)
                                    expireChoice = -1
                                    onChanged()
                                }
                            } label: {
                                Text("保存账号有效期").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent).tint(AppColors.brand)
                        }
                    }
                    .padding(14)
                }

                SectionCard(title: "快捷操作") {
                    HStack(spacing: 10) {
                        Button { Task { onChanged() } } label: { Text("修改备注") }
                            .buttonStyle(.bordered)
                        Button { Task { onChanged() } } label: { Text("重置密码") }
                            .buttonStyle(.bordered)
                    }
                    .padding(14)
                    if user.online && user.username != scope.session.username {
                        Button(role: .destructive) {
                            Task {
                                try? await scope.api.kickUser(user.username)
                                await loadLeases(); onChanged()
                            }
                        } label: {
                            Text("强制切断所有连接踢下线").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .padding(.horizontal, 14).padding(.bottom, 14)
                    }
                }

                if user.username != scope.session.username {
                    SectionCard(title: "危险区域") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("删除此用户将永久注销登录凭据，并立即收回其名下的所有设备租约。")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            Button(role: .destructive) {
                                Task {
                                    try? await scope.api.deleteUser(user.username)
                                    dismiss(); onChanged()
                                }
                            } label: {
                                Text("删除该用户").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent).tint(AppColors.danger)
                        }
                        .padding(14)
                        .background(AppColors.danger.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
            .padding(14)
        }
    }

    private var currentExpiryText: String {
        if let exp = user.expiresAt {
            return "\(Formatters.dateTime(exp))（\(Formatters.relative(exp))）"
        }
        return "长期有效"
    }

    // MARK: Tab 2 功能限制
    @State private var policy = UserPolicy()
    @State private var policyLoaded = false
    private var policyTab: some View {
        ScrollView {
            SectionCard(title: "功能限制策略") {
                VStack(spacing: 0) {
                    PolicyLine(title: "禁止调整码率", subtitle: "限制用户自行修改视频推流码率",
                               value: Binding(get: { policy.forbidBitrate },
                                              set: { policy.forbidBitrate = $0 }))
                    PolicyLine(title: "禁止调整帧率", subtitle: "限制用户自行修改推流帧率 (FPS)",
                               value: Binding(get: { policy.forbidFps }, set: { policy.forbidFps = $0 }))
                    PolicyLine(title: "禁止调整分辨率", subtitle: "限制用户切换清晰度与缩放规格",
                               value: Binding(get: { policy.forbidResolution },
                                              set: { policy.forbidResolution = $0 }))
                    PolicyLine(title: "禁止音频内录与监听", subtitle: "禁止开启手机音频输出与麦克风监听",
                               value: Binding(get: { policy.forbidAudio }, set: { policy.forbidAudio = $0 }))
                    PolicyLine(title: "禁止文件传输", subtitle: "禁止使用 WebRTC 文件中心向手机推送或读取文件",
                               value: Binding(get: { policy.forbidFilePush },
                                              set: { policy.forbidFilePush = $0 }))
                    PolicyLine(title: "禁止终端控制台", subtitle: "禁止在投屏控制中使用远程 Shell 终端",
                               value: Binding(get: { policy.forbidTerminal },
                                              set: { policy.forbidTerminal = $0 }))
                    PolicyLine(title: "禁止创建分享与卡密", subtitle: "禁止该用户对外生成设备分享卡密",
                               value: Binding(get: { policy.forbidShare }, set: { policy.forbidShare = $0 }))
                }
                Button {
                    Task {
                        try? await scope.api.updateUser(user.username, expireSeconds: -1, policy: policy)
                        onChanged()
                    }
                } label: {
                    Text("保存功能限制策略").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(AppColors.brand)
                .padding(14)
            }
            .padding(14)
        }
        .onAppear {
            if !policyLoaded { policy = user.policy; policyLoaded = true }
        }
    }
}

struct PolicyLine: View {
    let title: String
    let subtitle: String
    @Binding var value: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $value).labelsHidden().tint(AppColors.brand)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

/// 租约卡片（对齐 Android LeaseItemCard）
struct LeaseItemCard: View {
    let lease: AdminLease
    let username: String
    var onExtend: () -> Void
    var onNote: () -> Void
    var onRevoke: () -> Void

    private var isActive: Bool { lease.active && !lease.isRevoked }

    private var statusPill: (String, Color, Bool) {
        if lease.isRevoked { return ("已收回", AppColors.danger, true) }
        if !lease.active { return ("已到期", AppColors.offline, true) }
        if lease.isPermanent { return ("永久有效", AppColors.online, true) }
        let text = "剩余 \(Formatters.duration(lease.remainingSeconds))"
        return (text, lease.isExpiringSoon() ? AppColors.warning : AppColors.online, true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(lease.isRevoked ? AppColors.danger : (isActive ? AppColors.online : AppColors.offline))
                    .frame(width: 10, height: 10)
                Text(lease.deviceId).font(.system(size: 15, weight: .bold, design: .monospaced))
                Spacer()
                StatusPill(text: statusPill.0, color: statusPill.1, filled: statusPill.2)
            }
            if !lease.note.isEmpty {
                Text("备注：\(lease.note)").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Text("开通时间：\(Formatters.dateTime(lease.createdAt))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if let rev = lease.revokedAt {
                    Text("收回：\(Formatters.dateTime(rev))")
                        .font(.system(size: 11)).foregroundStyle(AppColors.danger.opacity(0.8))
                }
                Spacer()
            }
            if isActive {
                HStack(spacing: 8) {
                    Button("改备注", action: onNote).font(.system(size: 12))
                    Button { onExtend() } label: {
                        Label("展期", systemImage: "arrow.clockwise").font(.system(size: 12))
                    }
                    Spacer()
                    Button {
                        onRevoke()
                    } label: {
                        Text("收回").font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(AppColors.danger.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(AppColors.danger)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(AppColors.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.black.opacity(0.06), lineWidth: 0.5))
    }
}

/// 内联开租表单（用于详情抽屉）
struct InlineLeaseForm: View {
    @EnvironmentObject private var scope: UserScope
    let username: String
    let leases: [AdminLease]
    var onDone: () -> Void

    @State private var deviceId = ""
    @State private var durationIdx = 4
    @State private var customMode = false
    @State private var customValue = "1"
    @State private var customUnit = 2
    @State private var note = ""
    @State private var busy = false
    @State private var error: String?

    private var busyIds: Set<String> {
        Set(leases.filter { $0.active && !$0.isRevoked }.map { $0.deviceId })
    }

    private var seconds: Int64 {
        if customMode {
            let v = Int64(customValue) ?? 0
            return v * [Int64(60), Int64(3600), Int64(86400)][customUnit]
        }
        return Durations.lease[durationIdx].1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("选择设备").font(.system(size: 12)).foregroundStyle(.secondary)
            DevicePicker(selected: $deviceId)

            Text("租用时长").font(.system(size: 12)).foregroundStyle(.secondary)
            DurationChips(options: Durations.lease, selection: $durationIdx)
            FilterChip(text: "自定义时长", selected: customMode) { customMode.toggle() }
            if customMode {
                HStack {
                    TextField("数值", text: $customValue).keyboardType(.numberPad).frame(width: 80)
                    Picker("", selection: $customUnit) {
                        Text("分钟").tag(0); Text("小时").tag(1); Text("天").tag(2)
                    }.pickerStyle(.segmented)
                }
            }

            TextField("备注（选填，如订单号 / 用途）", text: $note)
                .padding(10)
                .background(AppColors.surfaceContainerHigh, in: RoundedRectangle(cornerRadius: 10))
                .onChange(of: note) { v in
                    if v.count > 80 { note = String(v.prefix(80)) }
                }

            if let error { Text(error).font(.caption).foregroundStyle(AppColors.danger) }

            HStack {
                Button("取消") { onDone() }.buttonStyle(.bordered)
                Button {
                    Task {
                        busy = true; error = nil
                        defer { busy = false }
                        do {
                            _ = try await scope.api.createLease(
                                LeaseCreateRequest(username: username, deviceId: deviceId,
                                                   durationSeconds: seconds, note: note, policyOverride: nil))
                            onDone()
                        } catch { self.error = error.localizedDescription }
                    }
                } label: {
                    Text(busy ? "开租中…" : "确认开租").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(AppColors.brand)
                .disabled(busy || deviceId.isEmpty)
            }
        }
        .padding(12)
        .background(AppColors.surface, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// 内联开租 sheet 包装
struct InlineCreateLeaseSheet: View {
    @EnvironmentObject private var scope: UserScope
    let username: String
    let leases: [AdminLease]
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView { InlineLeaseForm(username: username, leases: leases, onDone: { dismiss(); onDone() }) }
                .padding(14)
                .navigationTitle("开通新租约")
                .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - 设备维度开租（DeviceLeaseSheet）

struct DeviceLeaseSheet: View {
    @EnvironmentObject private var scope: UserScope
    let device: Device
    @Environment(\.dismiss) private var dismiss

    @State private var loading = true
    @State private var lease: AdminLease?
    @State private var users: [AdminUser] = []
    @State private var tenant = ""
    @State private var durationIdx = 4
    @State private var customMode = false
    @State private var customValue = "1"
    @State private var note = ""
    @State private var busy = false
    @State private var error: String?
    @State private var showExtend = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Circle().fill(device.online ? AppColors.online : AppColors.offline).frame(width: 10, height: 10)
                        Text("设备开租与租约管理").font(.system(size: 16, weight: .bold))
                    }
                    Text("设备 ID: \(device.id)\(device.info.title.isEmpty ? "" : " (\(device.info.title))")")
                        .font(.system(size: 12)).foregroundStyle(.secondary)

                    if loading {
                        ProgressView().frame(maxWidth: .infinity).padding(24)
                    } else if let lease, lease.active && !lease.isRevoked {
                        // 已有活跃租约
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("当前租户：").font(.system(size: 13)).foregroundStyle(.secondary)
                                Text(lease.username).font(.system(size: 15, weight: .bold))
                                Spacer()
                                StatusPill(text: lease.isPermanent ? "永久有效"
                                           : "剩余 \(Formatters.duration(lease.remainingSeconds))",
                                           color: lease.isExpiringSoon() ? AppColors.warning : AppColors.online,
                                           filled: true)
                            }
                            if !lease.note.isEmpty {
                                Text("备注：\(lease.note)").font(.system(size: 12)).foregroundStyle(.secondary)
                            }
                            Text("开通时间：\(Formatters.dateTime(lease.createdAt))")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            HStack {
                                Button(role: .destructive) {
                                    Task {
                                        try? await scope.api.revokeLease(lease.leaseId)
                                        await load(); onChangedRefresh()
                                    }
                                } label: { Text("提前收回") }
                                    .buttonStyle(.bordered).tint(AppColors.danger)
                                Button {
                                    showExtend = true
                                } label: {
                                    Label("租约展期", systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding(14)
                        .background(AppColors.surface, in: RoundedRectangle(cornerRadius: 14))
                    } else {
                        // 开租表单
                        VStack(alignment: .leading, spacing: 10) {
                            Text("选择租户账号").font(.system(size: 12)).foregroundStyle(.secondary)
                            Menu {
                                ForEach(users) { u in
                                    Button {
                                        tenant = u.username
                                    } label: {
                                        Label(u.username + (u.note.isEmpty ? "" : " (\(u.note))"),
                                              systemImage: u.online ? "circle.fill" : "circle")
                                    }
                                }
                            } label: {
                                HStack {
                                    Text(tenant.isEmpty ? "选择租户" : tenant)
                                        .foregroundStyle(tenant.isEmpty ? .secondary : .primary)
                                    Spacer()
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 12)).foregroundStyle(.secondary)
                                }
                                .padding(10)
                                .background(AppColors.surfaceContainerHigh, in: RoundedRectangle(cornerRadius: 10))
                            }

                            Text("租用时长").font(.system(size: 12)).foregroundStyle(.secondary)
                            DurationChips(options: Durations.lease, selection: $durationIdx)
                            FilterChip(text: "自定义天数", selected: customMode) { customMode.toggle() }
                            if customMode {
                                TextField("租用天数", text: $customValue)
                                    .keyboardType(.numberPad)
                                    .padding(10)
                                    .background(AppColors.surfaceContainerHigh, in: RoundedRectangle(cornerRadius: 10))
                            }

                            TextField("租约备注（如订单号 / 用途）", text: $note)
                                .padding(10)
                                .background(AppColors.surfaceContainerHigh, in: RoundedRectangle(cornerRadius: 10))
                                .onChange(of: note) { v in
                                    if v.count > 80 { note = String(v.prefix(80)) }
                                }

                            if let error { Text(error).font(.caption).foregroundStyle(AppColors.danger) }

                            Button {
                                Task { await createLease() }
                            } label: {
                                Text(busy ? "开租中…" : "立即开租").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent).tint(AppColors.brand)
                            .disabled(busy || tenant.isEmpty)
                        }
                        .padding(14)
                        .background(AppColors.surface, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
                .padding(14)
            }
            .background(AppColors.background)
            .navigationTitle("设备开租")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("关闭") { dismiss() } } }
            .sheet(isPresented: $showExtend) {
                DurationPickSheet(title: "租约展期", options: Durations.leaseExtend, confirmText: "确认") { seconds in
                    Task {
                        try? await scope.api.extendLease(lease?.leaseId ?? "", seconds: seconds)
                        await load()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            tenant = users.first?.username ?? ""
            Task { await load() }
        }
    }

    private func onChangedRefresh() {
        Task { await scope.devices.refresh(showLoading: false) }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        async let ls = scope.api.adminLeases(device: device.id, status: "active")
        async let us = scope.api.users()
        lease = ((try? await ls) ?? []).first
        users = (try? await us) ?? []
        if tenant.isEmpty { tenant = users.first?.username ?? "" }
    }

    private func createLease() async {
        busy = true; error = nil
        defer { busy = false }
        let seconds: Int64 = customMode ? (Int64(customValue) ?? 0) * 86_400 : Durations.lease[durationIdx].1
        do {
            _ = try await scope.api.createLease(
                LeaseCreateRequest(username: tenant, deviceId: device.id,
                                   durationSeconds: seconds, note: note, policyOverride: nil))
            await load()
            onChangedRefresh()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - 标签管理（对齐 Android TagsScreen）

enum TagPalette {
    static let colors = ["#3B82F6", "#22C55E", "#F59E0B", "#EF4444",
                         "#8B5CF6", "#EC4899", "#14B8A6", "#64748B"]
}

struct TagsView: View {
    @EnvironmentObject private var scope: UserScope
    @State private var editTag: Tag?
    @State private var isNewTag = false
    @State private var deleteTag: Tag?

    private func deviceCount(_ tag: Tag) -> Int {
        scope.devices.tags.deviceTags.values.filter { $0.contains(tag.id) }.count
    }

    var body: some View {
        Group {
            if scope.devices.tags.tags.isEmpty {
                ScrollView {
                    EmptyStateView(icon: "tag", title: "还没有标签",
                                   message: "用标签对设备分组，首页可按标签快速筛选",
                                   actionTitle: "新建标签") { newTag() }
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(scope.devices.tags.tags) { tag in
                            HStack(spacing: 12) {
                                Circle().fill(Color(hex: tag.color)).frame(width: 14, height: 14)
                                Text(tag.name).font(.system(size: 14, weight: .medium))
                                Spacer()
                                Text("\(deviceCount(tag)) 台设备")
                                    .font(.system(size: 12)).foregroundStyle(.secondary)
                                Button { editTag = tag; isNewTag = false } label: {
                                    Image(systemName: "pencil").font(.system(size: 14)).foregroundStyle(.secondary)
                                }
                                Button { deleteTag = tag } label: {
                                    Image(systemName: "trash").font(.system(size: 14)).foregroundStyle(AppColors.danger)
                                }
                            }
                            .padding(14)
                            .background(AppColors.surface, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.black.opacity(0.06), lineWidth: 0.5))
                        }
                    }
                    .padding(16)
                }
                .refreshable { await scope.devices.loadMeta() }
            }
        }
        .background(AppColors.background)
        .navigationTitle("标签管理")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { newTag() } label: { Image(systemName: "plus") }
            }
        }
        .onAppear { Task { await scope.devices.loadMeta() } }
        .sheet(isPresented: Binding(get: { editTag != nil }, set: { if !$0 { editTag = nil } })) {
            if let tag = editTag {
                TagEditDialog(tag: tag, isNew: isNewTag) { Task { await scope.devices.loadMeta() } }
                    .environmentObject(scope)
            }
        }
        .confirmationDialog("删除标签", isPresented: Binding(get: { deleteTag != nil },
                                                          set: { if !$0 { deleteTag = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                guard let t = deleteTag else { return }
                Task {
                    try? await scope.devices.deleteTag(t.id)
                    deleteTag = nil
                }
            }
        } message: {
            Text("删除「\(deleteTag?.name ?? "")」？设备不会被删除。")
        }
    }

    private func newTag() {
        let color = TagPalette.colors[scope.devices.tags.tags.count % TagPalette.colors.count]
        editTag = Tag(id: TagOps.newTagId(), name: "", color: color)
        isNewTag = true
    }
}

/// 标签编辑弹窗（名称 + 8 色板）
struct TagEditDialog: View {
    @EnvironmentObject private var scope: UserScope
    @Environment(\.dismiss) private var dismiss
    let tag: Tag
    let isNew: Bool
    var onDone: () -> Void

    @State private var name = ""
    @State private var color = ""
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("标签名（最多 20 字）", text: $name)
                        .onChange(of: name) { v in
                            if v.count > 20 { name = String(v.prefix(20)) }
                        }
                    if let error { Text(error).font(.caption).foregroundStyle(AppColors.danger) }
                }
                Section("颜色") {
                    HStack(spacing: 10) {
                        ForEach(TagPalette.colors, id: \.self) { c in
                            Circle()
                                .fill(Color(hex: c))
                                .frame(width: 32, height: 32)
                                .overlay(Circle().stroke(color == c ? Color.primary : .clear, lineWidth: 3))
                                .onTapGesture { color = c }
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "新建标签" : "编辑标签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        let n = name.trimmingCharacters(in: .whitespaces)
                        guard !n.isEmpty else { return }
                        if TagOps.isDuplicateName(scope.devices.tags.tags, name: n, selfId: tag.id) {
                            error = "已存在同名标签"
                            return
                        }
                        Task {
                            try? await scope.devices.upsertTag(Tag(id: tag.id, name: n, color: color))
                            dismiss()
                            onDone()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                if !loaded {
                    name = tag.name
                    color = tag.color
                    loaded = true
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - 快捷文本（对齐 Android QuickTextsScreen）

struct QuickTextView: View {
    @EnvironmentObject private var scope: UserScope
    @State private var editId: String?
    @State private var showEditor = false
    @State private var deleteItem: QuickText?

    var body: some View {
        Group {
            if scope.quickTexts.items.isEmpty {
                ScrollView {
                    EmptyStateView(icon: "text.alignleft", title: "暂无快捷文本",
                                   message: "投屏时在「文本下发」中一键发送到云手机",
                                   actionTitle: "新建") { newOne() }
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(scope.quickTexts.items) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(item.title.isEmpty ? "未命名" : item.title)
                                        .font(.system(size: 14, weight: .medium))
                                    Spacer()
                                    Button {
                                        editId = item.id; showEditor = true
                                    } label: {
                                        Image(systemName: "pencil").font(.system(size: 14)).foregroundStyle(.secondary)
                                    }
                                    Button { deleteItem = item } label: {
                                        Image(systemName: "trash").font(.system(size: 14)).foregroundStyle(AppColors.danger)
                                    }
                                }
                                Text(item.content).font(.system(size: 12)).foregroundStyle(.secondary)
                                    .lineLimit(2)
                                if item.autoEnter {
                                    Text("发送后自动回车").font(.system(size: 11)).foregroundStyle(AppColors.brand)
                                }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(AppColors.surface, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.black.opacity(0.06), lineWidth: 0.5))
                        }
                    }
                    .padding(16)
                }
                .refreshable { await scope.quickTexts.load() }
            }
        }
        .background(AppColors.background)
        .navigationTitle("快捷文本")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { newOne() } label: { Image(systemName: "plus") }
            }
        }
        .onAppear { Task { await scope.quickTexts.load() } }
        .sheet(isPresented: $showEditor) {
            QuickTextDialog(editId: editId) { Task { await scope.quickTexts.load() } }
                .environmentObject(scope)
        }
        .confirmationDialog("删除快捷文本", isPresented: Binding(get: { deleteItem != nil },
                                                             set: { if !$0 { deleteItem = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                guard let item = deleteItem else { return }
                Task {
                    try? await scope.quickTexts.delete(item.id)
                    deleteItem = nil
                }
            }
        }
    }

    private func newOne() {
        editId = nil
        showEditor = true
    }
}

struct QuickTextDialog: View {
    @EnvironmentObject private var scope: UserScope
    @Environment(\.dismiss) private var dismiss
    let editId: String?
    var onDone: () -> Void

    @State private var title = ""
    @State private var content = ""
    @State private var autoEnter = false
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("标题（最多 40 字，可留空）", text: $title)
                        .onChange(of: title) { v in
                            if v.count > 40 { title = String(v.prefix(40)) }
                        }
                    TextField("内容（最多 4000 字）", text: $content, axis: .vertical)
                        .lineLimit(3...8)
                        .onChange(of: content) { v in
                            if v.count > 4000 { content = String(v.prefix(4000)) }
                        }
                }
                Section {
                    Toggle("发送后自动回车", isOn: $autoEnter)
                }
                if let error { Section { Text(error).font(.caption).foregroundStyle(AppColors.danger) } }
            }
            .navigationTitle(editId == nil ? "新建快捷文本" : "编辑快捷文本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        let c = content
                        let t = title.isEmpty ? String(c.prefix(12)) : title
                        Task {
                            do {
                                try await scope.quickTexts.upsert(title: t, content: c, autoEnter: autoEnter, id: editId)
                                dismiss()
                                onDone()
                            } catch {
                                self.error = error.localizedDescription
                            }
                        }
                    }
                    .disabled(content.isEmpty)
                }
            }
            .onAppear {
                if !loaded, let id = editId,
                   let item = scope.quickTexts.items.first(where: { $0.id == id }) {
                    title = item.title
                    content = item.content
                    autoEnter = item.autoEnter
                    loaded = true
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - 批量文件分发（对齐 Android BatchFilesScreen 两步向导）

struct BatchFilesView: View {
    @EnvironmentObject private var scope: UserScope
    @State private var step = 0
    @State private var selectedFile: ServerFile?
    @State private var fileSearch = ""
    @State private var deviceSearch = ""
    @State private var onlineOnly = true
    @State private var selectedTagIds: Set<String> = []
    @State private var selectedDevices: Set<String> = []
    @State private var destPath = ""
    @State private var showUpload = false
    @State private var uploading = false
    @State private var showTaskBoard = false
    @State private var deleteFile: ServerFile?

    var body: some View {
        VStack(spacing: 0) {
            stepHeader.padding(16)

            if step == 0 {
                fileStep
            } else {
                deviceStep
            }

            Spacer(minLength: 0)
            actionBar
        }
        .background(AppColors.background)
        .navigationTitle("批量文件分发")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if scope.serverFiles.task != nil {
                    Button { showTaskBoard = true } label: { Text("任务看板") }
                }
                Button { Task { await scope.serverFiles.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
        }
        .onAppear {
            Task { await scope.serverFiles.refresh() }
            if destPath.isEmpty { destPath = ServerFileOps.defaultDestPath(selectedFile?.name ?? "file") }
        }
        .onChange(of: selectedFile) { f in
            if let f { destPath = ServerFileOps.defaultDestPath(f.name) }
        }
        .fileImporter(isPresented: $showUpload, allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Task { await upload(urls) }
            }
        }
        .sheet(isPresented: $showTaskBoard) { TaskBoard() }
        .confirmationDialog("删除服务器文件", isPresented: Binding(get: { deleteFile != nil },
                                                              set: { if !$0 { deleteFile = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                guard let f = deleteFile else { return }
                Task {
                    try? await scope.serverFiles.delete(f.name)
                    if selectedFile?.name == f.name { selectedFile = nil }
                    deleteFile = nil
                }
            }
        } message: {
            Text("从服务器盘删除 \(deleteFile?.name ?? "")？不影响已下发到设备的文件。")
        }
    }

    // MARK: 步骤头
    private var stepHeader: some View {
        HStack(spacing: 0) {
            stepPill(index: 0, text: "① 选择文件")
            Rectangle().fill(step >= 1 ? AppColors.online : AppColors.surfaceContainerHigh).frame(height: 2)
            stepPill(index: 1, text: "② 选择设备")
        }
    }

    private func stepPill(index: Int, text: String) -> some View {
        Button {
            if index == 0 || selectedFile != nil { withAnimation { step = index } }
        } label: {
            Text(text)
                .font(.system(size: 12, weight: step == index ? .bold : .medium))
                .foregroundStyle(step == index ? .white : .secondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(step == index ? AppColors.brand
                            : (step > index ? AppColors.online : AppColors.surfaceContainerHigh),
                            in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(index == 1 && selectedFile == nil)
    }

    // MARK: 步骤一：文件
    private var filteredFiles: [ServerFile] {
        let q = fileSearch.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? scope.serverFiles.files
            : scope.serverFiles.files.filter { $0.name.lowercased().contains(q) }
    }

    private var fileStep: some View {
        ScrollView {
            VStack(spacing: 12) {
                RoundedSearchField(text: $fileSearch, placeholder: "搜索文件名")

                Button { showUpload = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 16))
                            .foregroundStyle(AppColors.brand)
                            .frame(width: 38, height: 38)
                            .background(AppColors.brand.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(uploading ? "上传中…" : "上传本地文件到服务器")
                                .font(.system(size: 14, weight: .medium)).foregroundStyle(AppColors.brand)
                            Text("支持 APK 与任意文件，上传后可下发到多台设备")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppColors.brand.opacity(0.08), in: RoundedRectangle(cornerRadius: 20))
                }
                .buttonStyle(.plain)
                .disabled(uploading)

                ForEach(Array(scope.serverFiles.ops.filter { $0.kind == .upload && $0.state == .active })) { op in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("上传 \(op.name) · \(Formatters.bytes(op.loaded)) / \(Formatters.bytes(op.total))")
                            .font(.system(size: 12))
                        ProgressView(value: Double(op.progress))
                    }
                    .padding(10)
                    .background(AppColors.surface, in: RoundedRectangle(cornerRadius: 12))
                }

                if filteredFiles.isEmpty {
                    VStack(spacing: 6) {
                        Text(fileSearch.isEmpty ? "服务器盘暂无文件" : "没有匹配的文件")
                            .font(.system(size: 14)).foregroundStyle(.secondary)
                        Text(fileSearch.isEmpty ? "点击上方按钮上传第一个文件" : "换个关键字试试")
                            .font(.system(size: 12)).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity).padding(24)
                } else {
                    ForEach(filteredFiles) { file in
                        fileCard(file)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func fileCard(_ file: ServerFile) -> some View {
        let isApk = file.name.lowercased().hasSuffix(".apk")
        let selected = selectedFile?.name == file.name
        return Button {
            selectedFile = selected ? nil : file
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isApk ? "android.logo" : "doc.text")
                    .font(.system(size: 16))
                    .foregroundStyle(isApk ? AppColors.online : AppColors.brand)
                    .frame(width: 40, height: 40)
                    .background((isApk ? AppColors.online : AppColors.brand).opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(file.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                        if isApk { StatusPill(text: "APK", color: AppColors.online, filled: true) }
                    }
                    Text("\(Formatters.bytes(file.size)) · \(Formatters.dateTime(file.updatedAt))" +
                         (file.owner.isEmpty ? "" : " · \(file.owner)"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 20)).foregroundStyle(AppColors.brand)
                } else {
                    Button { deleteFile = file } label: {
                        Image(systemName: "trash").font(.system(size: 14)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? AppColors.brand.opacity(0.08) : AppColors.surface,
                        in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .stroke(selected ? AppColors.brand : Color.black.opacity(0.06),
                        lineWidth: selected ? 1.5 : 0.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: 步骤二：设备
    private var tagMap: [String: Tag] {
        Dictionary(uniqueKeysWithValues: scope.devices.tags.tags.map { ($0.id, $0) })
    }

    private var filteredDevices: [Device] {
        let q = deviceSearch.trimmingCharacters(in: .whitespaces).lowercased()
        var base = scope.devices.devices
        if onlineOnly { base = base.filter { $0.online } }
        if !selectedTagIds.isEmpty {
            base = base.filter { d in
                let ids = Set(scope.devices.tags.deviceTags[d.id] ?? [])
                return !selectedTagIds.isDisjoint(with: ids)
            }
        }
        if !q.isEmpty {
            base = base.filter {
                $0.displayName.lowercased().contains(q) || $0.info.title.lowercased().contains(q)
            }
        }
        return base.sorted { a, b in
            if a.online != b.online { return a.online }
            return a.id < b.id
        }
    }

    private var deviceStep: some View {
        ScrollView {
            VStack(spacing: 12) {
                RoundedSearchField(text: $deviceSearch, placeholder: "搜索设备 ID / 型号")

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        FilterChip(text: "在线", color: AppColors.online, selected: onlineOnly) {
                            onlineOnly.toggle()
                        }
                        FilterChip(text: "全部", color: AppColors.brand, selected: !onlineOnly) {
                            onlineOnly = false
                        }
                        ForEach(scope.devices.tags.tags) { tag in
                            FilterChip(text: tag.name, color: Color(hex: tag.color),
                                       selected: selectedTagIds.contains(tag.id)) {
                                if selectedTagIds.contains(tag.id) { selectedTagIds.remove(tag.id) }
                                else { selectedTagIds.insert(tag.id) }
                            }
                        }
                    }
                }

                HStack {
                    Text("共 \(filteredDevices.count) 台 · 已选 \(selectedDevices.count)")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("全选当前") { selectedDevices = Set(filteredDevices.map { $0.id }) }
                        .font(.system(size: 12))
                    Button("取消全选") { selectedDevices.removeAll() }
                        .font(.system(size: 12))
                }

                if !isApkFile {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("设备目标路径").font(.system(size: 12)).foregroundStyle(.secondary)
                        TextField("/sdcard/Download/\(selectedFile?.name ?? "")", text: $destPath)
                            .font(.system(size: 13))
                            .textFieldStyle(.roundedBorder)
                    }
                }

                ForEach(filteredDevices) { d in
                    deviceRow(d)
                }

                if filteredDevices.isEmpty {
                    VStack(spacing: 6) {
                        Text("没有符合条件的设备").font(.system(size: 14)).foregroundStyle(.secondary)
                        Text("调整状态或标签筛选").font(.system(size: 12)).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity).padding(24)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var isApkFile: Bool {
        (selectedFile?.name ?? "").lowercased().hasSuffix(".apk")
    }

    private func deviceRow(_ d: Device) -> some View {
        let selected = selectedDevices.contains(d.id)
        return Button {
            if selected { selectedDevices.remove(d.id) } else { selectedDevices.insert(d.id) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 20))
                    .foregroundStyle(selected ? AppColors.brand : AppColors.offline)
                Circle()
                    .fill(!d.online ? AppColors.offline : (d.inUse ? AppColors.busy : AppColors.online))
                    .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.displayName).font(.system(size: 14, weight: .medium))
                    Text(d.info.title + (d.online ? (d.inUse ? " · 使用中" : "") : " · 离线"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 4) {
                    ForEach((scope.devices.tags.deviceTags[d.id] ?? []).prefix(2).compactMap { tagMap[$0] }) { tag in
                        StatusPill(text: tag.name, color: Color(hex: tag.color), filled: true)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.black.opacity(0.06), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: 底部操作栏
    private var canDispatch: Bool {
        selectedFile != nil && !selectedDevices.isEmpty && !scope.serverFiles.dispatching
            && (isApkFile || !destPath.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private var actionBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(selectedFile?.name ?? "未选择文件")
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(hintText).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if step == 0 {
                Button {
                    withAnimation { step = 1 }
                } label: { Text("下一步") }
                .buttonStyle(.borderedProminent).tint(AppColors.brand)
                .disabled(selectedFile == nil)
            } else {
                Button {
                    withAnimation { step = 0 }
                } label: { Text("上一步") }
                .buttonStyle(.bordered)
                Button {
                    Task { await dispatch() }
                } label: {
                    if scope.serverFiles.dispatching {
                        HStack(spacing: 6) { ProgressView().tint(.white); Text("下发中") }
                    } else {
                        Text("\(isApkFile ? "安装" : "下发") · \(selectedDevices.count) 台")
                    }
                }
                .buttonStyle(.borderedProminent).tint(AppColors.brand)
                .disabled(!canDispatch)
            }
        }
        .padding(16)
        .background(.regularMaterial)
    }

    private var hintText: String {
        if step == 0 { return selectedFile == nil ? "先选择要下发的文件" : "已选文件 · 下一步选设备" }
        return "已选 \(selectedDevices.count) 台设备"
    }

    // MARK: 动作
    private func upload(_ urls: [URL]) async {
        uploading = true
        defer { uploading = false }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let name = url.lastPathComponent
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let realSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            try? await scope.serverFiles.upload(url: url, name: name, size: realSize)
        }
    }

    private func dispatch() async {
        guard let file = selectedFile else { return }
        let dest = isApkFile ? "" : destPath
        try? await scope.serverFiles.dispatchBatch(file, deviceIds: Array(selectedDevices), destPath: dest)
        showTaskBoard = true
    }
}

/// 任务看板（对齐 Android TaskBoard）
struct TaskBoard: View {
    @EnvironmentObject private var scope: UserScope
    @Environment(\.dismiss) private var dismiss

    private var subs: [SubTaskStatus] {
        Array((scope.serverFiles.task?.devices ?? [:]).values)
    }
    private var total: Int { subs.count }
    private var success: Int { subs.filter { $0.ok }.count }
    private var failed: Int { subs.filter { $0.finished && !$0.ok }.count }
    private var done: Int { subs.filter { $0.finished }.count }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if total == 0 {
                    Spacer()
                    Text("暂无任务").foregroundStyle(.secondary)
                    Spacer()
                } else {
                    HStack(spacing: 8) {
                        StatusPill(text: "完成 \(done)/\(total)", color: AppColors.brand, filled: false)
                        if success > 0 { StatusPill(text: "成功 \(success)", color: AppColors.online, filled: true) }
                        if failed > 0 { StatusPill(text: "失败 \(failed)", color: AppColors.danger, filled: true) }
                        Spacer()
                    }
                    GeometryReader { geo in
                        HStack(spacing: 0) {
                            if success > 0 {
                                Rectangle().fill(AppColors.online)
                                    .frame(width: geo.size.width * CGFloat(success) / CGFloat(max(total, 1)))
                            }
                            if failed > 0 {
                                Rectangle().fill(AppColors.danger)
                                    .frame(width: geo.size.width * CGFloat(failed) / CGFloat(max(total, 1)))
                            }
                            Rectangle().fill(AppColors.surfaceContainerHigh)
                        }
                        .clipShape(Capsule())
                    }
                    .frame(height: 6)

                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(subs, id: \.deviceId) { sub in
                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(sub.ok ? AppColors.online
                                              : (sub.finished ? AppColors.danger : AppColors.busy))
                                        .frame(width: 9, height: 9)
                                    Text(sub.deviceId).font(.system(size: 13, design: .monospaced))
                                    Spacer()
                                    Text(statusText(sub)).font(.system(size: 12)).foregroundStyle(.secondary)
                                }
                                .padding(10)
                                .background(AppColors.surface, in: RoundedRectangle(cornerRadius: 12))
                            }
                        }
                    }
                }
            }
            .padding(16)
            .background(AppColors.background)
            .navigationTitle("任务进度")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    if done == total {
                        Button("清除") {
                            scope.serverFiles.clearTask()
                            dismiss()
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func statusText(_ sub: SubTaskStatus) -> String {
        if sub.ok { return "成功" }
        if sub.finished { return sub.result.isEmpty ? "失败" : sub.result }
        if sub.status == "running" { return "处理中 \(sub.progress)%" }
        return "排队中"
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
