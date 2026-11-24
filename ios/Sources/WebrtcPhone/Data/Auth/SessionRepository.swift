import Foundation
import Combine

/// 登录态与凭据。对齐 Android 端 SessionRepository.kt。
/// token 只进 Keychain；普通 prefs 只放最近服务器与「记住密码」勾选。
@MainActor
final class SessionRepository: ObservableObject {
    @Published private(set) var session: AuthSession?
    @Published private(set) var logoutReason: String?

    private let secure = SecureStore.shared
    private let factory: HttpClientFactory
    private let defaults: UserDefaults
    private let sessionKey = "auth_session"
    private let recentKey = "recent_servers"
    private let rememberKey = "remember_password"
    private let maxRecent = 6

    private var cachedApi: CloudPhoneApi?
    private var cachedSession: AuthSession?

    init(factory: HttpClientFactory, defaults: UserDefaults = UserDefaults.standard) {
        self.factory = factory
        self.defaults = defaults
        restore()
    }

    var rememberPassword: Bool {
        get { defaults.object(forKey: rememberKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: rememberKey) }
    }

    struct RecentServer: Codable, Equatable { let url: String; let username: String }

    func recentServers() -> [RecentServer] {
        guard let data = defaults.string(forKey: recentKey)?.data(using: .utf8),
              let arr = try? JSONDecoder().decode([RecentServer].self, from: data) else { return [] }
        return arr.filter { !$0.url.isEmpty }
    }

    func rememberServer(_ endpoint: ServerEndpoint, username: String) {
        var list = recentServers().filter { $0.url != endpoint.serialize() }
        list.insert(RecentServer(url: endpoint.serialize(), username: username), at: 0)
        let data = (try? JSONEncoder().encode(Array(list.prefix(maxRecent)))) ?? Data()
        defaults.set(String(data: data, encoding: .utf8) ?? "[]", forKey: recentKey)
    }

    func forgetServer(_ url: String) {
        for item in recentServers() where item.url == url {
            clearPassword(url: url, username: item.username)
        }
        let list = recentServers().filter { $0.url != url }
        let data = (try? JSONEncoder().encode(list)) ?? Data()
        defaults.set(String(data: data, encoding: .utf8) ?? "[]", forKey: recentKey)
    }

    func api() -> CloudPhoneApi? {
        guard let s = session else { return nil }
        if let cached = cachedApi, cachedSession == s { return cached }
        guard let endpoint = ServerEndpoint.parse(s.serverUrl) else { return nil }
        let client = ApiClient(factory: factory, endpoint: endpoint,
                               tokenProvider: { [weak self] in self?.session?.token },
                               onUnauthorized: { [weak self] in
            Task { @MainActor in self?.expire("登录已过期，请重新登录") }
        })
        let api = CloudPhoneApi(client: client)
        cachedApi = api
        cachedSession = s
        return api
    }

    func login(endpoint: ServerEndpoint, username: String, password: String) async throws {
        let anonClient = ApiClient(factory: factory, endpoint: endpoint, tokenProvider: { nil })
        let result = try await CloudPhoneApi(client: anonClient).login(username: username, password: password)
        let s = AuthSession(server: endpoint.serialize(), token: result.token,
                            username: result.username.isEmpty ? username : result.username,
                            role: result.role)
        persist(s)
        rememberServer(endpoint, username: result.username.isEmpty ? username : result.username)
        logoutReason = nil
        session = s
    }

    func logout() async {
        await api()?.logout()
        clear()
    }

    func expire(_ reason: String) {
        guard session != nil else { return }
        logoutReason = reason
        clear()
    }

    func consumeLogoutReason() { logoutReason = nil }

    private func clear() {
        secure.remove(sessionKey)
        cachedApi = nil
        cachedSession = nil
        session = nil
    }

    private func persist(_ s: AuthSession) {
        let obj: [String: Any] = ["server": s.server, "token": s.token,
                                  "username": s.username, "role": s.role]
        if let data = try? JSONSerialization.data(withJSONObject: obj),
           let text = String(data: data, encoding: .utf8) {
            secure.set(text, for: sessionKey)
        }
    }

    private func restore() {
        guard let text = secure.string(for: sessionKey),
              let data = text.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let server = o["server"] as? String,
              let token = o["token"] as? String,
              let username = o["username"] as? String else { return }
        session = AuthSession(server: server, token: token, username: username,
                              role: o["role"] as? String ?? "user")
    }

    // MARK: 记住密码（按 服务器 + 用户名 隔离）
    private func passwordKey(url: String, username: String) -> String { "pwd:\(url)|\(username)" }

    func savedPassword(url: String, username: String) -> String? {
        username.isEmpty ? nil : secure.string(for: passwordKey(url: url, username: username))
    }
    func savePassword(url: String, username: String, password: String) {
        guard !username.isEmpty, !password.isEmpty else { return }
        secure.set(password, for: passwordKey(url: url, username: username))
    }
    func clearPassword(url: String, username: String) {
        secure.remove(passwordKey(url: url, username: username))
    }
}

// MARK: - AuthSession.serverUrl 兼容属性
extension AuthSession {
    var serverUrl: String { server }
}
