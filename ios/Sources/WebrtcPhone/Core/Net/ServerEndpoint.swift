import Foundation

/// 服务器地址（纯值对象）。对齐 Android 端 core/net/ServerEndpoint.kt。
/// 用户输入宽松：`192.168.1.2`、`host:8443`、`https://host`、`http://[::1]:8443/` 均可。
/// 未写协议默认 https，未写端口默认 8443。拒绝 user:pass@host。
struct ServerEndpoint: Equatable, Hashable, Codable {
    let secure: Bool
    let host: String
    let port: Int

    static let defaultPort = 8443

    /// 证书固定等场景的唯一键
    var key: String { "\(hostForURL):\(port)" }

    var httpBase: String { "\(secure ? "https" : "http")://\(hostForURL):\(port)" }
    var wsBase: String { "\(secure ? "wss" : "ws")://\(hostForURL):\(port)" }

    var display: String {
        var s = "\(secure ? "https" : "http")://\(hostForURL)"
        if port != Self.defaultPort { s += ":\(port)" }
        return s
    }

    private var hostForURL: String {
        host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    }

    func url(_ path: String) -> String {
        httpBase + (path.hasPrefix("/") ? path : "/" + path)
    }

    func wsUrl(_ path: String) -> String {
        wsBase + (path.hasPrefix("/") ? path : "/" + path)
    }

    /// 持久化格式即规范化 URL（总带端口）
    func serialize() -> String { "\(secure ? "https" : "http")://\(hostForURL):\(port)" }

    static func parse(_ input: String?) -> ServerEndpoint? {
        var raw = input?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.isEmpty { return nil }
        if !raw.contains("://") { raw = "https://" + raw }
        guard let url = URLComponents(string: raw),
              let scheme = url.scheme?.lowercased() else { return nil }

        let secure: Bool
        switch scheme {
        case "https", "wss": secure = true
        case "http", "ws": secure = false
        default: return nil
        }

        // 拒绝 user:pass@host，避免凭据混入 URL
        if url.user != nil || url.password != nil { return nil }
        guard let rawHost = url.host, !rawHost.isEmpty else { return nil }
        let host = rawHost.replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .lowercased()

        let portValue = url.port ?? 0
        let port = (1...65535).contains(portValue) ? portValue : defaultPort
        return ServerEndpoint(secure: secure, host: host, port: port)
    }
}
