import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var container: AppContainer
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var remember = true
    @State private var showPassword = false
    @State private var busy = false
    @State private var status: String?
    @State private var error: String?
    @State private var untrusted: UntrustedCertificateInfo?
    @State private var showRecent = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Image("AppLogo")
                        .resizable().scaledToFit()
                        .frame(width: 80, height: 80)
                    Text("穿云投屏").font(.system(size: 22, weight: .semibold))
                    Text("低延迟 · 随时随地控制你的云端设备")
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                }
                .padding(.top, 40)

                VStack(spacing: 16) {

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
                                .submitLabel(.next)
                        }
                        .padding(12).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))

                        HStack {
                            Image(systemName: "lock").foregroundStyle(.secondary)
                            if showPassword {
                                TextField("密码", text: $password)
                                    .submitLabel(.go)
                                    .onSubmit { Task { await doLogin() } }
                            } else {
                                SecureField("密码", text: $password)
                                    .submitLabel(.go)
                                    .onSubmit { Task { await doLogin() } }
                            }
                            Button { showPassword.toggle() } label: {
                                Image(systemName: showPassword ? "eye.slash" : "eye").foregroundStyle(.secondary)
                            }
                        }
                        .padding(12).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))

                        Toggle("记住密码", isOn: $remember)

                        if busy {
                            HStack(spacing: 8) {
                                ProgressView().tint(.blue)
                                Text(status ?? "正在登录...").font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if let error {
                            Text(error)
                                .font(.callout)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        }

                        Button {
                            Task { await doLogin() }
                        } label: {
                            if busy {
                                HStack(spacing: 8) {
                                    ProgressView().tint(.white)
                                    Text("正在登录...").fontWeight(.semibold)
                                }
                            } else {
                                Text("登录").fontWeight(.semibold)
                            }
                        }
                        .frame(maxWidth: .infinity).padding(14)
                        .background(AppColors.brand, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        .disabled(busy)
                    }
                    Spacer(minLength: 40)
                }
                .padding(24)
            }
            .background(AppColors.background)
            .navigationTitle("登录")
            .onAppear { prefill() }
            .onReceive(CertificateTrustNotification.publisher) { info in
                untrusted = info
                status = nil
                error = "服务器证书未信任，请确认后重试"
            }
            .alert(
                "服务器证书不受信任",
                isPresented: Binding(
                    get: { untrusted != nil },
                    set: { if !$0 { untrusted = nil } }
                ),
                presenting: untrusted
            ) { info in
                Button("信任并继续登录") { trust(info) }
                Button("取消", role: .cancel) {
                    untrusted = nil
                    error = "已取消：服务器证书未被信任"
                }
            } message: { info in
                Text("服务器：\(info.endpointKey)\n证书：\(info.subject.isEmpty ? "未知" : info.subject)\nSHA-256：\(info.sha256)\n\n首次连接请核对指纹后信任；后续证书变更会再次提醒。")
            }
        }
    }

    private func prefill() {
        let recents = container.session.recentServers()
        if let first = recents.first, server.isEmpty {
            server = first.url; username = first.username
            password = container.session.savedPassword(url: first.url, username: first.username) ?? ""
        }
    }

    @MainActor
    private func doLogin() async {
        let serverText = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !serverText.isEmpty else {
            error = "请输入服务器地址，例如 192.168.1.2:8443"; return
        }
        guard !user.isEmpty else {
            error = "请输入用户名"; return
        }
        guard !password.isEmpty else {
            error = "请输入密码"; return
        }
        guard let endpoint = ServerEndpoint.parse(serverText) else {
            error = "服务器地址格式不正确，例如 192.168.1.2:8443"; return
        }

        busy = true
        status = "正在连接 \(endpoint.display) ..."
        error = nil
        defer { busy = false; status = nil }

        do {
            try await container.session.login(endpoint: endpoint, username: user, password: password)
            if remember {
                container.session.savePassword(url: endpoint.serialize(), username: user, password: password)
            } else {
                container.session.clearPassword(url: endpoint.serialize(), username: user)
            }
        } catch let apiError as ApiError {
            if case .untrustedCertificate(let info) = apiError {
                untrusted = info
                self.error = "服务器证书未信任，请确认后重试"
            } else {
                self.error = apiError.localizedDescription
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func trust(_ info: UntrustedCertificateInfo) {
        container.httpFactory.certificatePins.pin(
            endpointKey: info.endpointKey,
            sha256: info.sha256,
            subject: info.subject
        )
        if let endpoint = ServerEndpoint.parse(server) {
            container.httpFactory.invalidate(for: endpoint)
        }
        untrusted = nil
        error = nil
        Task { await doLogin() }
    }
}
