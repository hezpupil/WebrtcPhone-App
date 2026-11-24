import Foundation

enum DashboardEvent {
    case devices([Device])
    /// WS 直推的 JPEG 快照
    case snapshotData(deviceId: String, jpeg: Data)
    /// HTTP 模式快照更新通知，需按 hash 拉取
    case snapshotUpdated(deviceId: String, hash: String)
    case tags(TagsPayload)
    case screenState(deviceId: String, state: String)
}

enum SocketState: String { case idle, connecting, connected, reconnecting }

/// 仪表盘实时通道（/connect_client 不发 connect 消息即为纯订阅模式）。
/// 对齐 Android 端 DashboardSocket.kt：断线指数退避重连（1s→30s），20s 应用层 ping。
@MainActor
final class DashboardSocket: ObservableObject {
    @Published private(set) var state: SocketState = .idle

    private let httpFactory: HttpClientFactory
    private let endpoint: ServerEndpoint
    private let tokenProvider: () -> String?
    private let onUnauthorized: () -> Void

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var delegate: WebSocketSessionDelegate?
    private var pingTimer: DispatchSourceTimer?
    private var loopTask: Task<Void, Never>?
    private var stopped = false

    private let eventsSubject = StateSubject<DashboardEvent?>(nil)
    var events: AnyStatePublisher<DashboardEvent?> { eventsSubject.publisher }

    init(httpFactory: HttpClientFactory, endpoint: ServerEndpoint,
         tokenProvider: @escaping () -> String?, onUnauthorized: @escaping () -> Void) {
        self.httpFactory = httpFactory
        self.endpoint = endpoint
        self.tokenProvider = tokenProvider
        self.onUnauthorized = onUnauthorized
    }

    func start() {
        guard loopTask == nil else { return }
        stopped = false
        loopTask = Task { [weak self] in
            guard let self else { return }
            var attempt = 0
            while !Task.isCancelled && !self.stopped {
                self.state = attempt == 0 ? .connecting : .reconnecting
                let result = await self.runOnce()
                if result == .unauthorized {
                    self.onUnauthorized()
                    break
                }
                if result == .openedThenClosed { attempt = 0 }
                attempt += 1
                let delayMs = min(30_000, 1_000 << min(attempt - 1, 5))
                try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            }
            self.state = .idle
        }
    }

    func stop() {
        stopped = true
        loopTask?.cancel(); loopTask = nil
        closeSocket()
        state = .idle
    }

    private enum CloseResult { case failed, openedThenClosed, unauthorized }

    private func closeSocket() {
        pingTimer?.cancel(); pingTimer = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel(); session = nil
        delegate = nil
    }

    private func runOnce() async -> CloseResult {
        guard let token = tokenProvider() else { return .unauthorized }
        var request = URLRequest(url: URL(string: endpoint.wsUrl("/connect_client"))!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        return await withCheckedContinuation { (cont: CheckedContinuation<CloseResult, Never>) in
            let (session, delegate) = httpFactory.newWebSocketSession(for: endpoint)
            self.session = session
            self.delegate = delegate
            var opened = false
            var finished = false
            let finish: (CloseResult) -> Void = { result in
                guard !finished else { return }
                finished = true
                cont.resume(returning: result)
            }
            delegate.onOpen = { [weak self] in
                guard let self else { return }
                opened = true
                Task { @MainActor in self.state = .connected }
                // 应用层心跳（服务端 pongWait 依赖客户端消息续期）
                self.pingTimer?.cancel()
                let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "dash.ping"))
                timer.schedule(deadline: .now() + 20, repeating: 20)
                timer.setEventHandler { self.task?.send(.string("{\"type\":\"ping\"}")) { _ in } }
                timer.resume()
                self.pingTimer = timer
            }
            delegate.onClose = { _, _ in
                finish(opened ? .openedThenClosed : .failed)
            }
            delegate.onFailure = { _, code in
                finish(code == 401 ? .unauthorized : (opened ? .openedThenClosed : .failed))
            }
            let wsTask = session.webSocketTask(with: request)
            self.task = wsTask
            wsTask.resume()
            self.receiveLoop { text in
                Task { @MainActor in self.handle(text) }
            }
        }
    }

    private func receiveLoop(onText: @escaping (String) -> Void) {
        task?.receive { [weak self] result in
            guard let self, self.task != nil else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message { onText(text) }
                self.receiveLoop(onText: onText)
            case .failure:
                break
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        var type = o["message_type"] as? String ?? ""
        if type.isEmpty { type = o["type"] as? String ?? "" }
        let event: DashboardEvent?
        switch type {
        case "device_list_update":
            let arr = (o["devices"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
            event = .devices(arr.map { Parsers.device($0) }.filter { !$0.id.isEmpty })
        case "snapshot_update":
            if let s = o["data"] as? String, let comma = s.range(of: "base64,") {
                let b64 = String(s[comma.upperBound...])
                if let bytes = Data(base64Encoded: b64), !bytes.isEmpty {
                    event = .snapshotData(deviceId: o["device_id"] as? String ?? "", jpeg: bytes)
                } else { event = nil }
            } else { event = nil }
        case "snapshot_updated":
            event = .snapshotUpdated(deviceId: o["device_id"] as? String ?? "",
                                     hash: o["hash"] as? String ?? "")
        case "tags_update":
            event = .tags(Parsers.tags(o))
        case "device_screen_state":
            event = .screenState(deviceId: o["device_id"] as? String ?? "",
                                 state: o["screen_state"] as? String ?? "")
        default:
            event = nil
        }
        if let event { eventsSubject.send(event) }
    }
}
