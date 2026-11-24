import Foundation

/// 底层 HTTP 客户端。对齐 Android 端 data/api/ApiClient.kt。
/// 鉴权头、错误归一化（纯文本 / {error|msg} JSON）、401 回调登出。
final class ApiClient {
    let endpoint: ServerEndpoint
    private let factory: HttpClientFactory
    private let tokenProvider: () -> String?
    private let onUnauthorized: () -> Void

    init(factory: HttpClientFactory,
         endpoint: ServerEndpoint,
         tokenProvider: @escaping () -> String?,
         onUnauthorized: @escaping () -> Void = {}) {
        self.factory = factory
        self.endpoint = endpoint
        self.tokenProvider = tokenProvider
        self.onUnauthorized = onUnauthorized
    }

    func get(_ path: String, auth: Bool = true) async throws -> Data {
        try await execute(path, method: "GET", body: nil, auth: auth)
    }

    func post(_ path: String, body: Any? = nil, auth: Bool = true) async throws -> Data {
        var payload: Data?
        if let body {
            if let d = body as? Data { payload = d }
            else { payload = try JSONSerialization.data(withJSONObject: body) }
        }
        return try await execute(path, method: "POST", body: payload, auth: auth)
    }

    func delete(_ path: String, auth: Bool = true) async throws -> Data {
        try await execute(path, method: "DELETE", body: nil, auth: auth)
    }

    func postRaw(_ path: String, body: Data, contentType: String = "application/octet-stream") async throws -> Data {
        try await execute(path, method: "POST", body: body, auth: true, contentType: contentType)
    }

    /// `{code,msg,data}` 信封：code != 0 抛 Business
    func envelope(_ data: Data) throws -> [String: Any] {
        let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let code = (o["code"] as? NSNumber)?.intValue ?? 0
        if code != 0 {
            let msg = (o["msg"] as? String) ?? "操作失败 (\(code))"
            throw ApiError.business(code: code, msg.isEmpty ? "操作失败 (\(code))" : msg)
        }
        return o
    }

    func postEnvelope(_ path: String, body: Any) async throws -> [String: Any] {
        try envelope(try await post(path, body: body))
    }

    func getEnvelope(_ path: String) async throws -> [String: Any] {
        try envelope(try await get(path))
    }

    private func execute(_ path: String, method: String, body: Data?, auth: Bool,
                         contentType: String = "application/json; charset=utf-8") async throws -> Data {
        guard let url = URL(string: endpoint.url(path)) else {
            throw ApiError.parse("服务器地址无效")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let body {
            req.httpBody = body
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if auth {
            guard let token = tokenProvider(), !token.isEmpty else { throw ApiError.unauthorized() }
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await factory.session(for: endpoint).data(for: req)
        } catch {
            throw ApiError.from(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ApiError.parse("无效响应")
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401:
            if auth { onUnauthorized() }
            throw ApiError.unauthorized(Self.errorText(data, "登录已失效，请重新登录"))
        case 403:
            throw ApiError.forbidden(Self.errorText(data, "无权限执行此操作"))
        case 404:
            throw ApiError.notFound(Self.errorText(data, "资源不存在"))
        default:
            throw ApiError.http(code: http.statusCode, Self.errorText(data, "请求失败 (HTTP \(http.statusCode))"))
        }
    }

    /// 服务端错误体可能是纯文本或 {error|msg} JSON
    static func errorText(_ data: Data, _ fallback: String) -> String {
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty { return fallback }
        var message = text
        if text.hasPrefix("{"), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let m = (o["error"] as? String)?.isEmpty == false ? (o["error"] as? String) : (o["msg"] as? String)
            if let m, !m.isEmpty { message = m }
        }
        return translate(String(message.prefix(200)))
    }

    /// 常见英文错误转中文（精确映射，对齐 Android 端 translate）
    static func translate(_ msg: String) -> String {
        switch msg.trimmingCharacters(in: .whitespaces) {
        case "Invalid username or password": return "用户名或密码错误"
        case "Username and password are required": return "请输入用户名和密码"
        case "Username already exists": return "用户名已存在"
        case "Unauthorized": return "登录已失效，请重新登录"
        case "Forbidden": return "无权限执行此操作"
        case "Share token not found": return "分享不存在或已失效"
        default: return msg.trimmingCharacters(in: .whitespaces)
        }
    }
}
