import Foundation

/// 单次会话的信令 WebSocket。对齐 Android 端 SignalingClient.kt。
/// 回调运行在 URLSession 委托队列，由上层 RtcSession 转投到会话线程处理。
final class SignalingClient: NSObject {
    protocol Listener: AnyObject {
        func onOpen()
        func onMessage(_ msg: SignalingMessage)
        /// 非主动关闭导致的断开；error 已归一化
        func onClosed(error: ApiError?, httpCode: Int?)
    }

    private let target: StreamTarget
    private weak var listener: Listener?
    private let httpFactory: HttpClientFactory
    private let queue = DispatchQueue(label: "signaling.receive")

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var delegate: WebSocketSessionDelegate?
    private var pingTimer: DispatchSourceTimer?
    private let stateLock = NSLock()
    private var closedByUs = false

    init(httpFactory: HttpClientFactory, target: StreamTarget, listener: Listener) {
        self.httpFactory = httpFactory
        self.target = target
        self.listener = listener
    }

    func connect() {
        let ep = target.endpoint
        guard var components = URLComponents(string: ep.wsUrl("/connect_client")) else {
            listener?.onClosed(error: .parse("信令地址无效"), httpCode: nil)
            return
        }
        var headers: [String: String] = [:]
        switch target.auth {
        case .user(let token):
            headers["Authorization"] = "Bearer \(token)"
        case .share(let shareToken, let password):
            // 服务端分享访客仅支持 query 参数鉴权（validateShareToken）
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: "share_token", value: shareToken))
            if !password.isEmpty { items.append(URLQueryItem(name: "share_pwd", value: password)) }
            components.queryItems = items
        }
        guard let url = components.url else {
            listener?.onClosed(error: .parse("信令地址无效"), httpCode: nil)
            return
        }
        var request = URLRequest(url: url)
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        let (session, delegate) = httpFactory.newWebSocketSession(for: ep)
        self.session = session
        self.delegate = delegate
        delegate.onOpen = { [weak self] in
            guard let self, !self.isClosedByUs else { return }
            _ = self.send(SignalingProtocol.connect(self.target.deviceId))
            self.startPing()
            self.listener?.onOpen()
        }
        delegate.onClose = { [weak self] _, _ in
            guard let self, !self.isClosedByUs else { return }
            self.listener?.onClosed(error: nil, httpCode: nil)
        }
        delegate.onFailure = { [weak self] error, code in
            guard let self, !self.isClosedByUs else { return }
            self.listener?.onClosed(error: ApiError.from(error), httpCode: code)
        }

        let wsTask = session.webSocketTask(with: request)
        self.task = wsTask
        wsTask.resume()
        receiveLoop()
    }

    private var isClosedByUs: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return closedByUs
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self, !self.isClosedByUs else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    if let m = SignalingProtocol.parse(text), case .pong = m {
                        // 心跳应答，忽略
                    } else if let m {
                        self.listener?.onMessage(m)
                    }
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8),
                       let m = SignalingProtocol.parse(text), !(m == .pong) {
                        self.listener?.onMessage(m)
                    }
                @unknown default:
                    break
                }
                self.receiveLoop()
            case .failure(let error):
                let httpCode = (self.task?.response as? HTTPURLResponse)?.statusCode
                self.listener?.onClosed(error: ApiError.from(error), httpCode: httpCode)
            }
        }
    }

    @discardableResult
    func send(_ text: String) -> Bool {
        guard !isClosedByUs else { return false }
        task?.send(.string(text)) { _ in }
        return task != nil
    }

    func close() {
        stateLock.lock(); closedByUs = true; stateLock.unlock()
        stopPing()
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        delegate = nil
    }

    private func startPing() {
        stopPing()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 20, repeating: 20)
        timer.setEventHandler { [weak self] in
            guard let self, !self.isClosedByUs else { return }
            self.task?.send(.string(SignalingProtocol.ping)) { _ in }
        }
        timer.resume()
        pingTimer = timer
    }

    private func stopPing() {
        pingTimer?.cancel()
        pingTimer = nil
    }

    deinit { stopPing() }
}
