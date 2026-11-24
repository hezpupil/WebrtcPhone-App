import Foundation
import Security
import Combine

/// URLSession + TOFU 证书信任代理。对齐 Android 端 HttpClientFactory / PinningTrustManager。
/// 校验顺序：先系统 CA；失败时仅当叶子证书 SHA-256 与已固定值相等才放行（并校验有效期）。
/// 绝不 trust-all。凭据不进 URL / 日志。
final class PinningSessionDelegate: NSObject, URLSessionDelegate {
    private let pinStore: CertificatePinStore
    private let endpointKey: String

    init(pinStore: CertificatePinStore, endpointKey: String) {
        self.pinStore = pinStore
        self.endpointKey = endpointKey
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // 1) 先走系统 CA
        var trustResult: SecTrustResultType = .invalid
        if SecTrustEvaluate(trust, &trustResult) == errSecSuccess,
           trustResult == .unspecified || trustResult == .proceed {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }

        // 2) 系统 CA 失败：仅当叶子指纹匹配已固定值才放行
        let hadPin = pinStore.fingerprint(for: endpointKey) != nil
        let leaf = SecTrustGetCertificateAtIndex(trust, 0)
        let fp = leaf.flatMap(CertificatePinStore.sha256)
        if let pinned = pinStore.fingerprint(for: endpointKey),
           let fp, pinned.equalityIgnoringCase(fp) {
            // 指纹匹配：校验有效期后放行
            var result: SecTrustResultType = .invalid
            guard SecTrustEvaluate(trust, &result) == errSecSuccess else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }

        // 未固定或指纹不符：取消并通过通知把证书详情交给 UI（TOFU 确认 / 变更告警）
        let info = Self.untrustedInfo(endpointKey: endpointKey, trust: trust, leaf: leaf, fp: fp ?? "", changed: hadPin)
        completionHandler(.cancelAuthenticationChallenge, nil)
        CertificateTrustNotification.post(info)
        return
    }

    private static func untrustedInfo(endpointKey: String, trust: SecTrust, leaf: SecCertificate?, fp: String, changed: Bool) -> UntrustedCertificateInfo {
        let subject = leaf.map(CertificatePinStore.subject) ?? ""
        return UntrustedCertificateInfo(
            endpointKey: endpointKey, sha256: fp,
            subject: subject, issuer: "", notAfter: Date.distantFuture, changed: changed
        )
    }

}

/// 证书错误通知总线（供 UI 弹出 TOFU 确认框）
enum CertificateTrustNotification {
    static let name = Notification.Name("CertificateTrustRequired")
    static func post(_ info: UntrustedCertificateInfo) {
        NotificationCenter.default.post(name: name, object: info)
    }

    static var publisher: AnyPublisher<UntrustedCertificateInfo, Never> {
        NotificationCenter.default.publisher(for: name)
            .compactMap { $0.object as? UntrustedCertificateInfo }
            .eraseToAnyPublisher()
    }
}

/// WebSocket 会话委托：复用 TOFU 固定逻辑 + 连接生命周期回调。
final class WebSocketSessionDelegate: NSObject, URLSessionDelegate, URLSessionWebSocketDelegate {
    private let pinning: PinningSessionDelegate
    var onOpen: (() -> Void)?
    var onClose: ((Int?, String?) -> Void)?
    var onFailure: ((Error, Int?) -> Void)?

    init(pinStore: CertificatePinStore, endpointKey: String) {
        self.pinning = PinningSessionDelegate(pinStore: pinStore, endpointKey: endpointKey)
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        pinning.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        onOpen?()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith code: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        onClose?(code.rawValue, reason.flatMap { String(data: $0, encoding: .utf8) })
    }
}

/// 按端点缓存 URLSession（共享底层连接）。
final class HttpClientFactory {
    private let pinStore: CertificatePinStore
    private var sessions: [String: URLSession] = [:]
    private let lock = NSLock()

    init(pinStore: CertificatePinStore = CertificatePinStore()) {
        self.pinStore = pinStore
    }

    func session(for endpoint: ServerEndpoint) -> URLSession {
        let key = "\(endpoint.key)|\(endpoint.secure)"
        lock.lock(); defer { lock.unlock() }
        if let s = sessions[key] { return s }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 20
        config.httpMaximumConnectionsPerHost = 5
        // 仅 HTTP/1.1：禁用 HTTP/2（对齐 Android 端 protocols = HTTP_1_1）
        config.httpAdditionalHeaders = ["Accept": "*/*"]
        let delegate: URLSessionDelegate? = endpoint.secure
            ? PinningSessionDelegate(pinStore: pinStore, endpointKey: endpoint.key)
            : nil
        let s = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        sessions[key] = s
        return s
    }

    func webSocketSession(for endpoint: ServerEndpoint) -> URLSession {
        let key = "ws|\(endpoint.key)|\(endpoint.secure)"
        lock.lock(); defer { lock.unlock() }
        if let s = sessions[key] { return s }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 0 // 长连接无读超时
        let delegate: URLSessionDelegate? = endpoint.secure
            ? PinningSessionDelegate(pinStore: pinStore, endpointKey: endpoint.key)
            : nil
        let s = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        sessions[key] = s
        return s
    }

    /// 每次连接独立的 WS session（带生命周期回调委托），供 SignalingClient / WsStreamSession 使用。
    func newWebSocketSession(for endpoint: ServerEndpoint) -> (URLSession, WebSocketSessionDelegate) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 0
        config.timeoutIntervalForResource = 0
        let delegate = WebSocketSessionDelegate(pinStore: pinStore, endpointKey: endpoint.key)
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        return (session, delegate)
    }

    /// TOFU 确认后清掉旧 session，下一次请求使用已固定的证书策略。
    func invalidate(for endpoint: ServerEndpoint) {
        let httpKey = "\(endpoint.key)|\(endpoint.secure)"
        let wsKey = "ws|\(endpoint.key)|\(endpoint.secure)"
        lock.lock()
        sessions.removeValue(forKey: httpKey)
        sessions.removeValue(forKey: wsKey)
        lock.unlock()
    }

    /// 暴露 pinStore 供 UI 做 TOFU 确认后写入指纹。
    var certificatePins: CertificatePinStore { pinStore }
}

private extension String {
    func equalityIgnoringCase(_ other: String) -> Bool {
        caseInsensitiveCompare(other) == .orderedSame
    }
}
