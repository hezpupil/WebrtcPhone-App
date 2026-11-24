import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var remember = true
    @State private var showPassword = false
    @State private var busy = false
    @State private var error: String?
    @State private var showRecent = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: "iphone.and.arrow.forward")
                        .font(.system(size: 64))
                        .foregroundStyle(.blue)
                    Text("穿云投屏").font(.title.bold())
                    Text("低延迟 · 随时随地控制你的云端设备")
                        .font(.subheadline).foregroundStyle(.secondary)

                    VStack(spacing: 12) {
                        HStack {
                            Image(systemName: "server.rack").foregroundStyle(.secondary)
                            TextField("服务器地址（如 192.168.1.2:8443）", text: $server)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .keyboardType(.URL)
                            if !container.session.recentServers().isEmpty {
                                Button { showRecent.toggle() } label: {
                                    Image(systemName: "clock.arrow.circlepath")
                                }
                            }
                        }
                        .padding(12).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        if showRecent {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(container.session.recentServers(), id: \.url) { item in
                                    Button {
                                        server = item.url; username = item.username
                                        password = container.session.savedPassword(url: item.url, username: item.username) ?? ""
                                        showRecent = false
                                    } label: {
                                        VStack(alignment: .leading) {
                                            Text(item.url).font(.caption)
                                            Text(item.username).font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                    Divider()
                                }
                            }
                            .padding(8).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                        }

                        HStack {
                            Image(systemName: "person").foregroundStyle(.secondary)
                            TextField("用户名", text: $username)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                        .padding(12).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))

                        HStack {
                            Image(systemName: "lock").foregroundStyle(.secondary)
                            if showPassword {
                                TextField("密码", text: $password)
                            } else {
                                SecureField("密码", text: $password)
                            }
                            Button { showPassword.toggle() } label: {
                                Image(systemName: showPassword ? "eye.slash" : "eye").foregroundStyle(.secondary)
                            }
                        }
                        .padding(12).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))

                        Toggle("记住密码", isOn: $remember)

                        if let error {
                            Text(error).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Button {
                            Task { await doLogin() }
                        } label: {
                            if busy { ProgressView().tint(.white) }
                            else { Text("登录").fontWeight(.semibold) }
                        }
                        .frame(maxWidth: .infinity).padding(14)
                        .background(Color.blue, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.white)
                        .disabled(busy || server.isEmpty || username.isEmpty || password.isEmpty)
                    }
                    Spacer(minLength: 40)
                }
                .padding(24)
            }
            .navigationTitle("登录")
            .onAppear { prefill() }
        }
    }

    private func prefill() {
        let recents = container.session.recentServers()
        if let first = recents.first, server.isEmpty {
            server = first.url; username = first.username
            password = container.session.savedPassword(url: first.url, username: first.username) ?? ""
        }
    }

    private func doLogin() async {
        guard let endpoint = ServerEndpoint.parse(server) else {
            error = "服务器地址格式不正确"; return
        }
        busy = true; error = nil
        defer { busy = false }
        do {
            try await container.session.login(endpoint: endpoint, username: username, password: password)
            if remember { container.session.savePassword(url: endpoint.serialize(), username: username, password: password) }
            else { container.session.clearPassword(url: endpoint.serialize(), username: username) }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
