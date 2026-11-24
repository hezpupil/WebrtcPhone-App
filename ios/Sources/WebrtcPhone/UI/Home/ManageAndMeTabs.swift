import SwiftUI

/// 管理中心（对齐 Android ManageAndMeTabs.kt 的 ManageTab）：
/// 顶部 3 张统计卡 + 分组入口行。
struct ManageTab: View {
    @EnvironmentObject private var scope: UserScope

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                // 统计卡（设备总数 / 在线 / 使用中）
                HStack(spacing: 10) {
                    StatCard(value: "\(scope.devices.devices.count)", label: "设备总数", color: AppColors.brand)
                    StatCard(value: "\(scope.devices.devices.filter { $0.online }.count)",
                             label: "在线", color: AppColors.online)
                    StatCard(value: "\(scope.devices.devices.filter { $0.online && $0.inUse }.count)",
                             label: "使用中", color: AppColors.busy)
                }
                .padding(.horizontal, 16)

                if scope.devices.isAdmin {
                    SectionCard(title: "访问控制") {
                        NavigationLink { SharesView() } label: {
                            EntryRow(icon: "square.and.arrow.up.on.square", iconColor: AppColors.brand,
                                     title: "分享与卡密", subtitle: "生成卡密/链接，管理访客访问")
                        }
                        divider
                        NavigationLink { UsersView() } label: {
                            EntryRow(icon: "person.3", iconColor: AppColors.brand,
                                     title: "用户管理", subtitle: "账号、有效期、权限、踢下线")
                        }
                    }
                    SectionCard(title: "设备组织") {
                        NavigationLink { TagsView() } label: {
                            EntryRow(icon: "tag", iconColor: AppColors.brand,
                                     title: "标签管理", subtitle: "\(scope.devices.tags.tags.count) 个标签")
                        }
                        divider
                        NavigationLink { QuickTextView() } label: {
                            EntryRow(icon: "text.alignleft", iconColor: AppColors.brand,
                                     title: "快捷文本", subtitle: "投屏时一键下发常用文本")
                        }
                    }
                    SectionCard(title: "批量操作") {
                        NavigationLink { BatchFilesView() } label: {
                            EntryRow(icon: "arrow.up.doc", iconColor: AppColors.brand,
                                     title: "批量文件分发", subtitle: "上传文件后一键安装/推送到多台设备")
                        }
                    }
                } else {
                    SectionCard(title: "设备组织") {
                        NavigationLink { QuickTextView() } label: {
                            EntryRow(icon: "text.alignleft", iconColor: AppColors.brand,
                                     title: "快捷文本", subtitle: "投屏时一键下发常用文本")
                        }
                    }
                }
            }
            .padding(.vertical, 12)
        }
        .background(AppColors.background)
        .navigationTitle("管理中心")
        .onAppear { Task { await scope.devices.loadMeta() } }
        .refreshable { await scope.devices.refresh(showLoading: false) }
    }

    private var divider: some View {
        Divider().padding(.leading, 60)
    }
}

/// 我的（对齐 Android MeTab）：个人信息大卡 + 分组入口。
struct MeTab: View {
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var scope: UserScope
    var onGoManage: (() -> Void)? = nil

    @State private var showLogoutConfirm = false
    @State private var showCrashLog = false

    private var me: Me? { scope.devices.me }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                profileCard.padding(.horizontal, 16)

                SectionCard(title: "投屏") {
                    NavigationLink { StreamSettingsView() } label: {
                        EntryRow(icon: "slider.horizontal.3", iconColor: AppColors.brand,
                                 title: "画质与编码", subtitle: "分辨率、帧率、码率、音频")
                    }
                    divider
                    NavigationLink { QuickTextView() } label: {
                        EntryRow(icon: "text.alignleft", iconColor: AppColors.brand,
                                 title: "快捷文本", subtitle: "管理文本下发模板")
                    }
                }

                SectionCard(title: "通用") {
                    NavigationLink { AppSettingsView() } label: {
                        EntryRow(icon: "moon", iconColor: AppColors.brand,
                                 title: "外观", subtitle: themeLabel)
                    }
                    divider
                    NavigationLink { AppSettingsView() } label: {
                        EntryRow(icon: "slider.horizontal.below.square", iconColor: AppColors.brand,
                                 title: "偏好设置", subtitle: "振动反馈、剪贴板同步、自动重连…")
                    }
                    divider
                    NavigationLink { CertificatesView() } label: {
                        EntryRow(icon: "lock", iconColor: AppColors.brand,
                                 title: "安全与证书", subtitle: "已信任的服务器证书")
                    }
                    divider
                    NavigationLink { AboutView() } label: {
                        EntryRow(icon: "info.circle", iconColor: AppColors.brand, title: "关于")
                    }
                }

                if scope.devices.isAdmin {
                    SectionCard(title: "管理") {
                        Button {
                            onGoManage?()
                        } label: {
                            EntryRow(icon: "shield.lefthalf.filled", iconColor: AppColors.brand,
                                     title: "进入管理中心")
                        }
                        .buttonStyle(.plain)
                    }
                }

                if CrashReporter.lastReport() != nil {
                    SectionCard(title: "诊断") {
                        Button {
                            showCrashLog = true
                        } label: {
                            EntryRow(icon: "exclamationmark.triangle.fill", iconColor: AppColors.danger,
                                     title: "最近一次崩溃日志", subtitle: "点击查看详情并发给开发者")
                        }
                        .buttonStyle(.plain)
                    }
                }

                SectionCard {
                    Button {
                        showLogoutConfirm = true
                    } label: {
                        EntryRow(icon: "arrow.right.square", iconColor: AppColors.danger,
                                 title: "退出登录", destructive: true)
                            .background(Color.clear)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 12)
        }
        .background(AppColors.background)
        .navigationTitle("我的")
        .onAppear { Task { await scope.devices.loadMeta() } }
        .sheet(isPresented: $showCrashLog) { CrashLogSheet() }
        .confirmationDialog("退出登录", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
            Button("退出", role: .destructive) { Task { await container.session.logout() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将断开当前投屏并清除本机保存的登录凭据。")
        }
    }

    private var divider: some View {
        Divider().padding(.leading, 60)
    }

    private var themeLabel: String {
        switch container.settings.app.themeMode {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    // 个人信息大卡（primaryContainer 底）
    private var profileCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(me?.username ?? container.session.session?.username ?? "-")
                    .font(.system(size: 20, weight: .bold))
                Spacer()
                StatusPill(text: (me?.role ?? container.session.session?.role) == "admin" ? "管理员" : "用户",
                           color: (me?.role ?? container.session.session?.role) == "admin" ? AppColors.brand : AppColors.online)
            }
            Text(scope.endpoint.serialize())
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            expiryLine
            leasesLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(AppColors.brand.opacity(0.14), in: RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder
    private var expiryLine: some View {
        if let exp = me?.expiresAt {
            let days = Int(exp.timeIntervalSinceNow)
            if days < 3 * 86_400 {
                Text("账号到期：\(Formatters.dateTime(exp))（\(Formatters.relative(exp))）")
                    .font(.system(size: 12)).foregroundStyle(AppColors.danger)
            } else {
                Text("账号到期：\(Formatters.dateTime(exp))（\(Formatters.relative(exp))）")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        } else {
            Text("账号长期有效").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var leasesLine: some View {
        let leases = me?.leases ?? []
        if !leases.isEmpty {
            let minRemain = leases.map { $0.remainingSeconds }.filter { $0 >= 0 }.min() ?? -1
            if minRemain >= 0 {
                Text("设备租约 \(leases.count) 个，最近到期：\(Formatters.duration(minRemain))")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Text("设备租约 \(leases.count) 个").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }
}

/// 崩溃日志查看
struct CrashLogSheet: View {
    @State private var report: String = CrashReporter.lastReport() ?? ""
    @State private var copied = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(report)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .textSelection(.enabled)
            }
            .navigationTitle("崩溃日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("清除") {
                        CrashReporter.clear()
                        report = ""
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(copied ? "已复制" : "复制") {
                        UIPasteboard.general.string = report
                        copied = true
                    }
                }
            }
        }
    }
}
