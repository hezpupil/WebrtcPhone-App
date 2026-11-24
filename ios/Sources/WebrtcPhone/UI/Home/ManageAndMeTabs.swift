import SwiftUI

struct ManageTab: View {
    @EnvironmentObject private var scope: UserScope

    var body: some View {
        List {
            if scope.devices.isAdmin {
                NavigationLink { TagsView() } label: {
                    Label("标签管理", systemImage: "tag")
                }
                NavigationLink { SharesView() } label: {
                    Label("分享管理", systemImage: "person.crop.circle.badge.plus")
                }
                NavigationLink { UsersView() } label: {
                    Label("用户管理", systemImage: "person.3")
                }
                NavigationLink { BatchFilesView() } label: {
                    Label("批量分发", systemImage: "square.and.arrow.down.on.square")
                }
            }
            NavigationLink { QuickTextView() } label: {
                Label("快捷文本", systemImage: "text.badge.plus")
            }
            NavigationLink { ServerFilesView() } label: {
                Label("服务器文件", systemImage: "folder")
            }
        }
        .navigationTitle("管理")
    }
}

struct MeTab: View {
    @EnvironmentObject private var container: AppContainer
    @EnvironmentObject private var scope: UserScope

    var body: some View {
        List {
            Section {
                HStack {
                    Image(systemName: "person.circle.fill").font(.largeTitle).foregroundStyle(.blue)
                    VStack(alignment: .leading) {
                        Text(scope.devices.me?.username ?? container.session.session?.username ?? "")
                            .font(.headline)
                        Text(scope.devices.me?.role == "admin" ? "管理员" : "普通用户")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                NavigationLink { SettingsView() } label: { Label("设置", systemImage: "gear") }
            }
            Section {
                Button("退出登录", role: .destructive) {
                    Task { await container.session.logout() }
                }
            }
        }
        .navigationTitle("我的")
    }
}
